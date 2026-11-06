import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'json.dart';
import 'patch.dart';
import 'records.dart';
import 'tokens.dart';

/// The five domain-independent Event types.
enum EventType {
  /// A Bead or Link began to exist.
  created,

  /// A Resource's properties, or a Bead's owned Link, changed.
  updated,

  /// A Bead or Link ceased to exist.
  deleted,

  /// A Link became incident upon a Bead.
  linked,

  /// A Link ceased to be incident upon a Bead.
  unlinked;

  /// Decodes an Event type.
  static EventType fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (type) => type.name);

  /// The wire spelling.
  String toJson() => name;
}

/// An Event's type-specific delta.
@immutable
sealed class EventData {
  const EventData._();

  /// The wire form.
  JsonObject toJson();
}

/// The delta of a creation: the complete initial state.
final class CreatedData extends EventData {
  /// A creation delta.
  CreatedData({
    required this.revision,
    required JsonObject properties,
    this.attribution,
    this.source,
    this.target,
    JsonObject? changeContext,
  }) : properties = freezeObject(properties),
       changeContext = changeContext == null
           ? null
           : freezeObject(changeContext),
       super._() {
    if ((source == null) != (target == null)) {
      throw ArgumentError('a Link creation carries both endpoints');
    }
  }

  /// Decodes a creation delta.
  factory CreatedData.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return CreatedData(
      revision: r.decode('revision', Revision.fromJson),
      properties: r.object('properties'),
      attribution: r.optionalDecode('attribution', Attribution.fromJson),
      source: r.optionalDecode('source', Reference.fromJson),
      target: r.optionalDecode('target', Reference.fromJson),
      changeContext: r.optionalObject('changeContext'),
    );
  }

  /// The created revision.
  final Revision revision;

  /// The complete initial properties.
  final JsonObject properties;

  /// The created version's carried attribution.
  final Attribution? attribution;

  /// A created Link's source.
  final Reference? source;

  /// A created Link's target.
  final Reference? target;

  /// The History capability's change context, verbatim.
  final JsonObject? changeContext;

  @override
  JsonObject toJson() {
    final json = <String, Object?>{
      'revision': revision.toJson(),
      'properties': properties,
    };
    putIfPresent(json, 'attribution', attribution?.toJson());
    putIfPresent(json, 'source', source?.toJson());
    putIfPresent(json, 'target', target?.toJson());
    putIfPresent(json, 'changeContext', changeContext);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is CreatedData && jsonEquality.equals(other.toJson(), toJson());

  @override
  int get hashCode => jsonEquality.hash(toJson());
}

/// The delta of an update: exactly one of a Property Change or an owned-Link
/// transition.
final class UpdatedData extends EventData {
  /// A Property Change delta.
  UpdatedData.change({
    required this.previousRevision,
    required this.revision,
    required PropertyChange this.change,
    this.attribution,
    JsonObject? changeContext,
  }) : ownedLink = null,
       changeContext = changeContext == null
           ? null
           : freezeObject(changeContext),
       super._();

  /// An owned-Link transition delta.
  UpdatedData.ownedLink({
    required this.previousRevision,
    required this.revision,
    required OwnedLinkChange this.ownedLink,
    this.attribution,
    JsonObject? changeContext,
  }) : change = null,
       changeContext = changeContext == null
           ? null
           : freezeObject(changeContext),
       super._();

  /// Decodes an update delta.
  factory UpdatedData.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    final previous = r.decode('previousRevision', Revision.fromJson);
    final revision = r.decode('revision', Revision.fromJson);
    final attribution = r.optionalDecode('attribution', Attribution.fromJson);
    final changeContext = r.optionalObject('changeContext');
    final change = r.optionalDecode('change', PropertyChange.fromJson);
    final ownedLink = r.optionalDecode('ownedLink', OwnedLinkChange.fromJson);
    return switch ((change, ownedLink)) {
      (final change?, null) => UpdatedData.change(
        previousRevision: previous,
        revision: revision,
        change: change,
        attribution: attribution,
        changeContext: changeContext,
      ),
      (null, final ownedLink?) => UpdatedData.ownedLink(
        previousRevision: previous,
        revision: revision,
        ownedLink: ownedLink,
        attribution: attribution,
        changeContext: changeContext,
      ),
      _ => throw FormatException(
        '$path: exactly one of change and ownedLink is present',
      ),
    };
  }

  /// The revision the delta advances from.
  final Revision previousRevision;

  /// The revision the delta advances to.
  final Revision revision;

  /// The committed Property Change, for a properties update.
  final PropertyChange? change;

  /// The owned-Link transition, for an owned-Link update of a Bead.
  final OwnedLinkChange? ownedLink;

  /// The new version's carried attribution.
  final Attribution? attribution;

  /// The History capability's change context, verbatim.
  final JsonObject? changeContext;

  @override
  JsonObject toJson() {
    final json = <String, Object?>{
      'previousRevision': previousRevision.toJson(),
      'revision': revision.toJson(),
    };
    putIfPresent(json, 'change', change?.toJson());
    putIfPresent(json, 'ownedLink', ownedLink?.toJson());
    putIfPresent(json, 'attribution', attribution?.toJson());
    putIfPresent(json, 'changeContext', changeContext);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is UpdatedData && jsonEquality.equals(other.toJson(), toJson());

  @override
  int get hashCode => jsonEquality.hash(toJson());
}

/// The delta of a deletion: the final live revision.
final class DeletedData extends EventData {
  /// A deletion delta.
  const DeletedData({required this.revision}) : super._();

  /// Decodes a deletion delta.
  factory DeletedData.fromJson(Object? json, [String path = '']) => DeletedData(
    revision: JsonReader.of(json, path).decode('revision', Revision.fromJson),
  );

  /// The final live revision.
  final Revision revision;

  @override
  JsonObject toJson() => {'revision': revision.toJson()};

  @override
  bool operator ==(Object other) =>
      other is DeletedData && other.revision == revision;

  @override
  int get hashCode => revision.hashCode;
}

/// The delta of a `linked` or `unlinked` fact at one endpoint Bead.
final class LinkDeltaData extends EventData {
  /// A graph delta.
  const LinkDeltaData({
    required this.endpoint,
    required this.link,
    required this.source,
    required this.target,
  }) : super._();

  /// Decodes a graph delta.
  factory LinkDeltaData.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return LinkDeltaData(
      endpoint: r.decode('endpoint', LinkEndpoint.fromJson),
      link: r.decode('link', TypedLinkReference.fromJson),
      source: r.decode('source', Reference.fromJson),
      target: r.decode('target', Reference.fromJson),
    );
  }

  /// How the Link is incident upon the Event Source's Bead.
  final LinkEndpoint endpoint;

  /// The Link's identity and Type.
  final TypedLinkReference link;

  /// The Link's source.
  final Reference source;

  /// The Link's target.
  final Reference target;

  @override
  JsonObject toJson() => {
    'endpoint': endpoint.toJson(),
    'link': link.toJson(),
    'source': source.toJson(),
    'target': target.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is LinkDeltaData &&
      other.endpoint == endpoint &&
      other.link == link &&
      other.source == source &&
      other.target == target;

  @override
  int get hashCode => Object.hash(endpoint, link, source, target);
}

/// An owned Link's own update delta, carried inside its source's `updated`
/// Event.
@immutable
final class OwnedLinkDelta {
  /// An owned-Link delta.
  OwnedLinkDelta({
    required this.id,
    required this.type,
    required this.previousRevision,
    required this.revision,
    required this.change,
    this.attribution,
    JsonObject? changeContext,
  }) : changeContext = changeContext == null
           ? null
           : freezeObject(changeContext);

  /// Decodes an owned-Link delta.
  factory OwnedLinkDelta.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return OwnedLinkDelta(
      id: r.string('id'),
      type: r.string('type'),
      previousRevision: r.decode('previousRevision', Revision.fromJson),
      revision: r.decode('revision', Revision.fromJson),
      change: r.decode('change', PropertyChange.fromJson),
      attribution: r.optionalDecode('attribution', Attribution.fromJson),
      changeContext: r.optionalObject('changeContext'),
    );
  }

  /// The owned Link's canonical URL.
  final String id;

  /// The owned Link's Type.
  final String type;

  /// The Link's revision before the change.
  final Revision previousRevision;

  /// The Link's revision after the change.
  final Revision revision;

  /// The committed Property Change.
  final PropertyChange change;

  /// The Link's new version's carried attribution.
  final Attribution? attribution;

  /// The History capability's change context, verbatim.
  final JsonObject? changeContext;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{
      'id': id,
      'type': type,
      'previousRevision': previousRevision.toJson(),
      'revision': revision.toJson(),
      'change': change.toJson(),
    };
    putIfPresent(json, 'attribution', attribution?.toJson());
    putIfPresent(json, 'changeContext', changeContext);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is OwnedLinkDelta && jsonEquality.equals(other.toJson(), toJson());

  @override
  int get hashCode => jsonEquality.hash(toJson());
}

/// One owned-Link transition of a source Bead.
@immutable
sealed class OwnedLinkChange {
  const OwnedLinkChange._();

  /// Decodes an owned-Link transition.
  factory OwnedLinkChange.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return switch (r.string('operation')) {
      'created' => OwnedLinkCreated(r.decode('link', LinkRecord.fromJson)),
      'updated' => OwnedLinkUpdated(r.decode('link', OwnedLinkDelta.fromJson)),
      'deleted' => OwnedLinkDeleted(
        r.decode('link', ResourceIdentity.fromJson),
      ),
      final other => throw FormatException(
        '${r.at('operation')}: "$other" is not an owned-Link transition',
      ),
    };
  }

  /// The wire form.
  JsonObject toJson();
}

/// An owned Link was created; [link] is its complete record.
final class OwnedLinkCreated extends OwnedLinkChange {
  /// A creation transition.
  const OwnedLinkCreated(this.link) : super._();

  /// The owned Link's record after creation.
  final LinkRecord link;

  @override
  JsonObject toJson() => {'operation': 'created', 'link': link.toJson()};

  @override
  bool operator ==(Object other) =>
      other is OwnedLinkCreated && other.link == link;

  @override
  int get hashCode => link.hashCode;
}

/// An owned Link's properties changed; [delta] is the Link's own delta.
final class OwnedLinkUpdated extends OwnedLinkChange {
  /// An update transition.
  const OwnedLinkUpdated(this.delta) : super._();

  /// The Link's own delta.
  final OwnedLinkDelta delta;

  @override
  JsonObject toJson() => {'operation': 'updated', 'link': delta.toJson()};

  @override
  bool operator ==(Object other) =>
      other is OwnedLinkUpdated && other.delta == delta;

  @override
  int get hashCode => delta.hashCode;
}

/// An owned Link was deleted; [link] is its final live identity.
final class OwnedLinkDeleted extends OwnedLinkChange {
  /// A deletion transition.
  const OwnedLinkDeleted(this.link) : super._();

  /// The deleted Link's identity.
  final ResourceIdentity link;

  @override
  JsonObject toJson() => {'operation': 'deleted', 'link': link.toJson()};

  @override
  bool operator ==(Object other) =>
      other is OwnedLinkDeleted && other.link == link;

  @override
  int get hashCode => link.hashCode;
}

/// An immutable, authority-generated record of a committed fact.
@immutable
final class Event {
  /// An Event whose [data] matches its [type].
  Event({
    required this.id,
    required this.ordinal,
    required this.type,
    required this.source,
    required this.subject,
    required this.subjectType,
    required this.transaction,
    required this.time,
    required this.data,
  }) {
    final matches = switch (type) {
      EventType.created => data is CreatedData,
      EventType.updated => data is UpdatedData,
      EventType.deleted => data is DeletedData,
      EventType.linked || EventType.unlinked => data is LinkDeltaData,
    };
    if (!matches) {
      throw ArgumentError.value(data, 'data', 'does not match ${type.name}');
    }
  }

  /// Decodes an Event.
  factory Event.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    final type = r.decode('type', EventType.fromJson);
    return Event(
      id: r.decode('id', EventId.fromJson),
      ordinal: r.integer('ordinal'),
      type: type,
      source: r.string('source'),
      subject: r.string('subject'),
      subjectType: r.string('subjectType'),
      transaction: r.decode('transaction', TransactionId.fromJson),
      time: r.string('time'),
      data: r.decode('data', switch (type) {
        EventType.created => CreatedData.fromJson,
        EventType.updated => UpdatedData.fromJson,
        EventType.deleted => DeletedData.fromJson,
        EventType.linked || EventType.unlinked => LinkDeltaData.fromJson,
      }),
    );
  }

  /// The source-local Event ID.
  final EventId id;

  /// The Event's stable ordinal within its change group.
  final int ordinal;

  /// The Event type.
  final EventType type;

  /// The Event Source URL.
  final String source;

  /// The affected Resource.
  final String subject;

  /// The affected Resource's Type.
  final String subjectType;

  /// The transaction the fact committed in.
  final TransactionId transaction;

  /// The RFC 3339 commit time, as served.
  final String time;

  /// The type-specific delta.
  final EventData data;

  /// The wire form.
  JsonObject toJson() => {
    'id': id.toJson(),
    'ordinal': ordinal,
    'type': type.toJson(),
    'source': source,
    'subject': subject,
    'subjectType': subjectType,
    'transaction': transaction.toJson(),
    'time': time,
    'data': data.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Event &&
      other.id == id &&
      other.ordinal == ordinal &&
      other.type == type &&
      other.source == source &&
      other.subject == subject &&
      other.subjectType == subjectType &&
      other.transaction == transaction &&
      other.time == time &&
      other.data == data;

  @override
  int get hashCode => Object.hash(
    id,
    ordinal,
    type,
    source,
    subject,
    subjectType,
    transaction,
    time,
    data,
  );

  @override
  String toString() => 'Event($id ${type.name} $subject)';
}

/// A finite page of an Event Source.
@immutable
final class EventPage {
  /// A page of [events] from [source].
  EventPage({
    required this.source,
    required List<Event> events,
    required this.next,
  }) : events = List.unmodifiable(events);

  /// Decodes an Event page.
  factory EventPage.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    if (!r.has('next')) {
      throw FormatException('${r.at('next')}: required member is missing');
    }
    return EventPage(
      source: r.string('source'),
      events: r.list('events', Event.fromJson),
      next: r.optionalString('next'),
    );
  }

  /// The Event Source URL.
  final String source;

  /// The Events, in source order.
  final List<Event> events;

  /// The continuation, or `null` at the Source's current end.
  final String? next;

  /// The wire form.
  JsonObject toJson() => {
    'source': source,
    'events': [for (final event in events) event.toJson()],
    'next': next,
  };

  @override
  bool operator ==(Object other) =>
      other is EventPage &&
      other.source == source &&
      other.next == next &&
      const ListEquality<Event>().equals(other.events, events);

  @override
  int get hashCode =>
      Object.hash(source, next, const ListEquality<Event>().hash(events));
}
