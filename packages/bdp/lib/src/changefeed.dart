import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'events.dart';
import 'json.dart';
import 'records.dart';
import 'tokens.dart';

/// One normalized entry of a change group's `changes`: a postimage, or the
/// tombstone of a Resource that left the projection.
@immutable
sealed class StateChange {
  const StateChange._();

  /// Decodes a state change.
  factory StateChange.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    final kind = r.decode('resourceKind', ResourceKind.fromJson);
    return switch (r.string('operation')) {
      'upsert' => Upsert(
        r.decode(
          'resource',
          kind == ResourceKind.bead ? BeadRecord.fromJson : LinkRecord.fromJson,
        ),
      ),
      'tombstone' => Tombstone(
        kind,
        r.decode('resource', ResourceIdentity.fromJson),
      ),
      final other => throw FormatException(
        '${r.at('operation')}: "$other" is not upsert or tombstone',
      ),
    };
  }

  /// Which kind of Resource changed.
  ResourceKind get resourceKind;

  /// The Resource's canonical URL.
  String get id;

  /// The wire form.
  JsonObject toJson();
}

/// The complete canonical postimage of a Resource at its final projected
/// revision.
final class Upsert extends StateChange {
  /// An upsert of [resource].
  Upsert(this.resource) : super._() {
    if (resource case BeadRecord(:final links?)) {
      throw ArgumentError.value(links, 'resource.links', 'is not replicated');
    }
  }

  /// The postimage.
  final ResourceRecord resource;

  @override
  ResourceKind get resourceKind => resource.kind;

  @override
  String get id => resource.id;

  @override
  JsonObject toJson() => {
    'operation': 'upsert',
    'resourceKind': resourceKind.toJson(),
    'resource': resource.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Upsert && other.resource == resource;

  @override
  int get hashCode => resource.hashCode;
}

/// The identity of a Resource that left the projection; it does not by
/// itself assert underlying deletion.
final class Tombstone extends StateChange {
  /// A tombstone of [identity].
  const Tombstone(this.resourceKind, this.identity) : super._();

  @override
  final ResourceKind resourceKind;

  /// The last visible identity.
  final ResourceIdentity identity;

  @override
  String get id => identity.id;

  @override
  JsonObject toJson() => {
    'operation': 'tombstone',
    'resourceKind': resourceKind.toJson(),
    'resource': identity.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Tombstone &&
      other.resourceKind == resourceKind &&
      other.identity == identity;

  @override
  int get hashCode => Object.hash(resourceKind, identity);
}

/// The digest of an erased version, taken before erasure.
@immutable
final class ErasureDigest {
  /// A digest under [scheme].
  const ErasureDigest({required this.scheme, required this.value});

  /// Decodes a digest.
  factory ErasureDigest.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return ErasureDigest(scheme: r.string('scheme'), value: r.string('value'));
  }

  /// The digest discipline, e.g. `sha-256-jcs`.
  final String scheme;

  /// The lowercase hexadecimal digest.
  final String value;

  /// The wire form.
  JsonObject toJson() => {'scheme': scheme, 'value': value};

  @override
  bool operator ==(Object other) =>
      other is ErasureDigest && other.scheme == scheme && other.value == value;

  @override
  int get hashCode => Object.hash(scheme, value);
}

/// A record that one version of a Resource was erased.
@immutable
final class ErasureRecord {
  /// An erasure of [subject] at [revision].
  const ErasureRecord({
    required this.subject,
    required this.revision,
    required this.digest,
  });

  /// Decodes an erasure record.
  factory ErasureRecord.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return ErasureRecord(
      subject: r.string('subject'),
      revision: r.decode('revision', Revision.fromJson),
      digest: r.decode('digest', ErasureDigest.fromJson),
    );
  }

  /// The canonical Resource URL.
  final String subject;

  /// The erased version's revision.
  final Revision revision;

  /// The digest of the erased record.
  final ErasureDigest digest;

  /// The wire form.
  JsonObject toJson() => {
    'subject': subject,
    'revision': revision.toJson(),
    'digest': digest.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ErasureRecord &&
      other.subject == subject &&
      other.revision == revision &&
      other.digest == digest;

  @override
  int get hashCode => Object.hash(subject, revision, digest);
}

/// One immutable change group: everything one committed transaction changed
/// in one Authorization View, applied atomically.
@immutable
final class ChangeGroup {
  /// A change group.
  ///
  /// A projection advance carries no transaction and nothing else; an
  /// ordinary group carries a transaction and at least one change, erasure
  /// or Event; [eventCount] always equals the Events served.
  ChangeGroup({
    required this.scopeEpoch,
    required this.authorizationView,
    required this.checkpoint,
    required this.position,
    required this.previousPosition,
    required this.projectionAdvance,
    required this.transaction,
    required this.eventCount,
    required List<StateChange> changes,
    required List<ErasureRecord> erasures,
    required List<Event> events,
  }) : changes = List.unmodifiable(changes),
       erasures = List.unmodifiable(erasures),
       events = List.unmodifiable(events) {
    final problem = _invalid();
    if (problem != null) throw ArgumentError(problem);
  }

  /// Decodes a change group.
  factory ChangeGroup.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    try {
      return ChangeGroup(
        scopeEpoch: r.decode('scopeEpoch', ScopeEpoch.fromJson),
        authorizationView: r.decode(
          'authorizationView',
          AuthorizationView.fromJson,
        ),
        checkpoint: r.decode('checkpoint', Checkpoint.fromJson),
        position: r.decode('position', ScopePosition.fromJson),
        previousPosition: r.decode('previousPosition', ScopePosition.fromJson),
        projectionAdvance: r.boolean('projectionAdvance'),
        transaction: r.optionalDecode('transaction', TransactionId.fromJson),
        eventCount: r.integer('eventCount'),
        changes: r.list('changes', StateChange.fromJson),
        erasures: r.list('erasures', ErasureRecord.fromJson),
        events: r.list('events', Event.fromJson),
      );
    } on ArgumentError catch (error) {
      throw FormatException('$path: ${error.message}');
    }
  }

  /// The epoch the group belongs to.
  final ScopeEpoch scopeEpoch;

  /// The view the group is projected for.
  final AuthorizationView authorizationView;

  /// The durable cursor a replica advances to after applying this group.
  final Checkpoint checkpoint;

  /// The group's Scope position.
  final ScopePosition position;

  /// The position immediately before this group.
  final ScopePosition previousPosition;

  /// Whether this is an identifier-free projection advance.
  final bool projectionAdvance;

  /// The transaction, absent for a projection advance.
  final TransactionId? transaction;

  /// The number of Events served.
  final int eventCount;

  /// Normalized postimages and tombstones; order carries no meaning.
  final List<StateChange> changes;

  /// Erasure records published at this position.
  final List<ErasureRecord> erasures;

  /// The application-facing facts, in operation order.
  final List<Event> events;

  String? _invalid() {
    if (eventCount != events.length) {
      return 'eventCount $eventCount does not match ${events.length} Events';
    }
    if (projectionAdvance) {
      if (transaction != null ||
          changes.isNotEmpty ||
          erasures.isNotEmpty ||
          events.isNotEmpty) {
        return 'a projection advance carries no transaction and no content';
      }
      return null;
    }
    if (transaction == null) return 'a visible group carries a transaction';
    if (changes.isEmpty && erasures.isEmpty && events.isEmpty) {
      return 'a visible group carries a change, an erasure or an Event';
    }
    return null;
  }

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{
      'scopeEpoch': scopeEpoch.toJson(),
      'authorizationView': authorizationView.toJson(),
      'checkpoint': checkpoint.toJson(),
      'position': position.toJson(),
      'previousPosition': previousPosition.toJson(),
      'projectionAdvance': projectionAdvance,
    };
    putIfPresent(json, 'transaction', transaction?.toJson());
    json['eventCount'] = eventCount;
    json['changes'] = [for (final change in changes) change.toJson()];
    json['erasures'] = [for (final erasure in erasures) erasure.toJson()];
    json['events'] = [for (final event in events) event.toJson()];
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is ChangeGroup &&
      other.scopeEpoch == scopeEpoch &&
      other.authorizationView == authorizationView &&
      other.checkpoint == checkpoint &&
      other.position == position &&
      other.previousPosition == previousPosition &&
      other.projectionAdvance == projectionAdvance &&
      other.transaction == transaction &&
      other.eventCount == eventCount &&
      const ListEquality<StateChange>().equals(other.changes, changes) &&
      const ListEquality<ErasureRecord>().equals(other.erasures, erasures) &&
      const ListEquality<Event>().equals(other.events, events);

  @override
  int get hashCode => Object.hash(
    scopeEpoch,
    authorizationView,
    checkpoint,
    position,
    previousPosition,
    projectionAdvance,
    transaction,
    eventCount,
    const ListEquality<StateChange>().hash(changes),
    const ListEquality<ErasureRecord>().hash(erasures),
    const ListEquality<Event>().hash(events),
  );

  @override
  String toString() =>
      'ChangeGroup($checkpoint ${projectionAdvance ? 'advance' : transaction})';
}

/// A finite changefeed read: only complete change groups.
@immutable
final class ChangefeedPage {
  /// A page.
  ChangefeedPage({
    required this.scope,
    required this.scopeEpoch,
    required this.authorizationView,
    required this.after,
    required this.observedHeadPosition,
    required List<ChangeGroup> groups,
    required this.next,
  }) : groups = List.unmodifiable(groups);

  /// Decodes a changefeed page.
  factory ChangefeedPage.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    if (!r.has('next')) {
      throw FormatException('${r.at('next')}: required member is missing');
    }
    return ChangefeedPage(
      scope: r.string('scope'),
      scopeEpoch: r.decode('scopeEpoch', ScopeEpoch.fromJson),
      authorizationView: r.decode(
        'authorizationView',
        AuthorizationView.fromJson,
      ),
      after: r.decode('after', Checkpoint.fromJson),
      observedHeadPosition: r.decode(
        'observedHeadPosition',
        ScopePosition.fromJson,
      ),
      groups: r.list('groups', ChangeGroup.fromJson),
      next: r.optionalString('next'),
    );
  }

  /// The canonical Scope URL.
  final String scope;

  /// The epoch the page belongs to.
  final ScopeEpoch scopeEpoch;

  /// The view the page is projected for.
  final AuthorizationView authorizationView;

  /// The exclusive checkpoint this page continues from.
  final Checkpoint after;

  /// The projected head the authority observed for this read.
  final ScopePosition observedHeadPosition;

  /// Complete change groups, in Scope order.
  final List<ChangeGroup> groups;

  /// The continuation, or `null`.
  final String? next;

  /// The checkpoint a consumer holds after applying every group here.
  Checkpoint get lastCheckpoint =>
      groups.isEmpty ? after : groups.last.checkpoint;

  /// The wire form.
  JsonObject toJson() => {
    'scope': scope,
    'scopeEpoch': scopeEpoch.toJson(),
    'authorizationView': authorizationView.toJson(),
    'after': after.toJson(),
    'observedHeadPosition': observedHeadPosition.toJson(),
    'groups': [for (final group in groups) group.toJson()],
    'next': next,
  };

  @override
  bool operator ==(Object other) =>
      other is ChangefeedPage &&
      other.scope == scope &&
      other.scopeEpoch == scopeEpoch &&
      other.authorizationView == authorizationView &&
      other.after == after &&
      other.observedHeadPosition == observedHeadPosition &&
      other.next == next &&
      const ListEquality<ChangeGroup>().equals(other.groups, groups);

  @override
  int get hashCode => Object.hash(
    scope,
    scopeEpoch,
    authorizationView,
    after,
    observedHeadPosition,
    next,
    const ListEquality<ChangeGroup>().hash(groups),
  );
}

/// The one explicit starting intent a changefeed read requires.
@immutable
sealed class ChangefeedStart {
  const ChangefeedStart._();

  /// Continue exclusively after [checkpoint].
  const factory ChangefeedStart.after(Checkpoint checkpoint) = AfterCheckpoint;

  /// Replay complete retained history.
  factory ChangefeedStart.genesis() => AfterCheckpoint(Checkpoint.genesis);

  /// Observe only groups committed from now on.
  const factory ChangefeedStart.now() = StartNow;

  /// The query parameters that express this intent.
  Map<String, String> get queryParameters;
}

/// Continue exclusively after a checkpoint.
final class AfterCheckpoint extends ChangefeedStart {
  /// Continue after [checkpoint].
  const AfterCheckpoint(this.checkpoint) : super._();

  /// The exclusive cursor.
  final Checkpoint checkpoint;

  @override
  Map<String, String> get queryParameters => {'after': checkpoint.value};

  @override
  bool operator ==(Object other) =>
      other is AfterCheckpoint && other.checkpoint == checkpoint;

  @override
  int get hashCode => checkpoint.hashCode;
}

/// Observe only future groups.
final class StartNow extends ChangefeedStart {
  /// Start at the head.
  const StartNow() : super._();

  @override
  Map<String, String> get queryParameters => const {'start': 'now'};

  @override
  bool operator ==(Object other) => other is StartNow;

  @override
  int get hashCode => (StartNow).hashCode;
}
