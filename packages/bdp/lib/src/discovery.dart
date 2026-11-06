import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'json.dart';
import 'records.dart';
import 'tokens.dart';

/// The BDP version this client implements.
const String bdpVersion = '0';

/// A Scope's advertised cumulative conformance profile.
enum Profile {
  /// Discovery and safe retrieval.
  read('read'),

  /// Read plus the single-Resource targets and `sequence`.
  readUpdate('read-update'),

  /// The complete transaction and replication contract.
  transactional('transactional');

  const Profile(this.wire);

  /// The wire token.
  final String wire;

  /// Decodes a profile from its wire token.
  static Profile fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (profile) => profile.wire);

  /// The wire token.
  String toJson() => wire;

  /// Whether this profile claims every surface of [other].
  bool includes(Profile other) => index >= other.index;
}

/// The discovery document named a BDP version this client does not
/// implement; the client stops rather than guessing compatibility.
final class UnsupportedBdpVersion implements Exception {
  /// The advertised version.
  const UnsupportedBdpVersion(this.advertised);

  /// The version the Scope advertised.
  final String advertised;

  @override
  String toString() =>
      'UnsupportedBdpVersion: the Scope advertises bdpVersion "$advertised"; '
      'this client implements "$bdpVersion"';
}

/// Page sizes counted in records.
@immutable
final class PageLimits {
  /// Page limits.
  const PageLimits({this.defaultItems, this.maximumItems});

  /// Decodes the `page` group.
  factory PageLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return PageLimits(
      defaultItems: r.optionalInteger('defaultItems'),
      maximumItems: r.optionalInteger('maximumItems'),
    );
  }

  /// Items in a page when the request names no `limit`.
  final int? defaultItems;

  /// The most items one page may hold.
  final int? maximumItems;

  /// The wire form.
  JsonObject toJson() =>
      _members({'defaultItems': defaultItems, 'maximumItems': maximumItems});

  @override
  bool operator ==(Object other) =>
      other is PageLimits &&
      other.defaultItems == defaultItems &&
      other.maximumItems == maximumItems;

  @override
  int get hashCode => Object.hash(defaultItems, maximumItems);
}

/// Request size bounds in octets.
@immutable
final class RequestLimits {
  /// Request limits.
  const RequestLimits({this.targetBytes, this.bodyBytes});

  /// Decodes the `request` group.
  factory RequestLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return RequestLimits(
      targetBytes: r.optionalInteger('targetBytes'),
      bodyBytes: r.optionalInteger('bodyBytes'),
    );
  }

  /// Octets in the encoded request target.
  final int? targetBytes;

  /// Octets in the request body.
  final int? bodyBytes;

  /// The wire form.
  JsonObject toJson() =>
      _members({'targetBytes': targetBytes, 'bodyBytes': bodyBytes});

  @override
  bool operator ==(Object other) =>
      other is RequestLimits &&
      other.targetBytes == targetBytes &&
      other.bodyBytes == bodyBytes;

  @override
  int get hashCode => Object.hash(targetBytes, bodyBytes);
}

/// Resource size bounds in UTF-8 bytes.
@immutable
final class ResourceLimits {
  /// Resource limits.
  const ResourceLimits({this.representationBytes, this.propertiesBytes});

  /// Decodes the `resource` group.
  factory ResourceLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return ResourceLimits(
      representationBytes: r.optionalInteger('representationBytes'),
      propertiesBytes: r.optionalInteger('propertiesBytes'),
    );
  }

  /// Bytes in one Resource representation.
  final int? representationBytes;

  /// Bytes in one `properties` document.
  final int? propertiesBytes;

  /// The wire form.
  JsonObject toJson() => _members({
    'representationBytes': representationBytes,
    'propertiesBytes': propertiesBytes,
  });

  @override
  bool operator ==(Object other) =>
      other is ResourceLimits &&
      other.representationBytes == representationBytes &&
      other.propertiesBytes == propertiesBytes;

  @override
  int get hashCode => Object.hash(representationBytes, propertiesBytes);
}

/// Selector complexity bounds.
@immutable
final class SelectorLimits {
  /// Selector limits.
  const SelectorLimits({this.bytes, this.depth, this.nodes});

  /// Decodes the `selector` group.
  factory SelectorLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return SelectorLimits(
      bytes: r.optionalInteger('bytes'),
      depth: r.optionalInteger('depth'),
      nodes: r.optionalInteger('nodes'),
    );
  }

  /// UTF-8 bytes after percent-decoding.
  final int? bytes;

  /// Parsed nesting depth.
  final int? depth;

  /// Parsed node count.
  final int? nodes;

  /// The wire form.
  JsonObject toJson() =>
      _members({'bytes': bytes, 'depth': depth, 'nodes': nodes});

  @override
  bool operator ==(Object other) =>
      other is SelectorLimits &&
      other.bytes == bytes &&
      other.depth == depth &&
      other.nodes == nodes;

  @override
  int get hashCode => Object.hash(bytes, depth, nodes);
}

/// Bounds on one Property Change.
@immutable
final class PatchLimits {
  /// Patch limits.
  const PatchLimits({this.operations, this.pathBytes, this.pathDepth});

  /// Decodes the `patch` group.
  factory PatchLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return PatchLimits(
      operations: r.optionalInteger('operations'),
      pathBytes: r.optionalInteger('pathBytes'),
      pathDepth: r.optionalInteger('pathDepth'),
    );
  }

  /// Operations in one patch.
  final int? operations;

  /// Bytes in one patch path.
  final int? pathBytes;

  /// Segments in one patch path.
  final int? pathDepth;

  /// The wire form.
  JsonObject toJson() => _members({
    'operations': operations,
    'pathBytes': pathBytes,
    'pathDepth': pathDepth,
  });

  @override
  bool operator ==(Object other) =>
      other is PatchLimits &&
      other.operations == operations &&
      other.pathBytes == pathBytes &&
      other.pathDepth == pathDepth;

  @override
  int get hashCode => Object.hash(operations, pathBytes, pathDepth);
}

/// Bounds on one `sequence` request.
@immutable
final class SequenceLimits {
  /// Sequence limits.
  const SequenceLimits({this.operations});

  /// Decodes the `sequence` group.
  factory SequenceLimits.fromJson(Object? json, [String path = '']) =>
      SequenceLimits(
        operations: JsonReader.of(json, path).optionalInteger('operations'),
      );

  /// Members in one sequence.
  final int? operations;

  /// The wire form.
  JsonObject toJson() => _members({'operations': operations});

  @override
  bool operator ==(Object other) =>
      other is SequenceLimits && other.operations == operations;

  @override
  int get hashCode => operations.hashCode;
}

/// Bounds on a `validation-failed` problem's diagnostics.
@immutable
final class ValidationLimits {
  /// Validation limits.
  const ValidationLimits({this.diagnostics, this.diagnosticBytes});

  /// Decodes the `validation` group.
  factory ValidationLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return ValidationLimits(
      diagnostics: r.optionalInteger('diagnostics'),
      diagnosticBytes: r.optionalInteger('diagnosticBytes'),
    );
  }

  /// Entries in the diagnostics list.
  final int? diagnostics;

  /// UTF-8 bytes of the serialized diagnostics list.
  final int? diagnosticBytes;

  /// The wire form.
  JsonObject toJson() => _members({
    'diagnostics': diagnostics,
    'diagnosticBytes': diagnosticBytes,
  });

  @override
  bool operator ==(Object other) =>
      other is ValidationLimits &&
      other.diagnostics == diagnostics &&
      other.diagnosticBytes == diagnosticBytes;

  @override
  int get hashCode => Object.hash(diagnostics, diagnosticBytes);
}

/// Bounds on one Mutation Transaction.
@immutable
final class TransactionLimits {
  /// Transaction limits.
  const TransactionLimits({
    this.operations,
    this.examinedResources,
    this.matchedResources,
    this.mutatedResources,
    this.inducedEvents,
    this.duration,
  });

  /// Decodes the `transaction` group.
  factory TransactionLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return TransactionLimits(
      operations: r.optionalInteger('operations'),
      examinedResources: r.optionalInteger('examinedResources'),
      matchedResources: r.optionalInteger('matchedResources'),
      mutatedResources: r.optionalInteger('mutatedResources'),
      inducedEvents: r.optionalInteger('inducedEvents'),
      duration: r.optionalString('duration'),
    );
  }

  /// Operations in one batch.
  final int? operations;

  /// Resources one transaction may examine.
  final int? examinedResources;

  /// Resources one transaction may match.
  final int? matchedResources;

  /// Resources one transaction may mutate.
  final int? mutatedResources;

  /// Events one transaction may induce.
  final int? inducedEvents;

  /// The ISO 8601 duration bounding admitted execution, as advertised.
  final String? duration;

  /// The wire form.
  JsonObject toJson() => _members({
    'operations': operations,
    'examinedResources': examinedResources,
    'matchedResources': matchedResources,
    'mutatedResources': mutatedResources,
    'inducedEvents': inducedEvents,
    'duration': duration,
  });

  @override
  bool operator ==(Object other) =>
      other is TransactionLimits &&
      other.operations == operations &&
      other.examinedResources == examinedResources &&
      other.matchedResources == matchedResources &&
      other.mutatedResources == mutatedResources &&
      other.inducedEvents == inducedEvents &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(
    operations,
    examinedResources,
    matchedResources,
    mutatedResources,
    inducedEvents,
    duration,
  );
}

/// Retention intervals, each an ISO 8601 duration as advertised.
@immutable
final class RetentionLimits {
  /// Retention limits.
  const RetentionLimits({
    this.idempotency,
    this.receipt,
    this.maximumSnapshotLifetime,
    this.replay,
  });

  /// Decodes the `retention` group.
  factory RetentionLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return RetentionLimits(
      idempotency: r.optionalString('idempotency'),
      receipt: r.optionalString('receipt'),
      maximumSnapshotLifetime: r.optionalString('maximumSnapshotLifetime'),
      replay: r.optionalString('replay'),
    );
  }

  /// Read+Update idempotency-disposition retention.
  final String? idempotency;

  /// Transactional receipt-detail and failed-receipt retention.
  final String? receipt;

  /// The longest a snapshot or cursor remains continuable.
  final String? maximumSnapshotLifetime;

  /// Changefeed replay retention.
  final String? replay;

  /// The wire form.
  JsonObject toJson() => _members({
    'idempotency': idempotency,
    'receipt': receipt,
    'maximumSnapshotLifetime': maximumSnapshotLifetime,
    'replay': replay,
  });

  @override
  bool operator ==(Object other) =>
      other is RetentionLimits &&
      other.idempotency == idempotency &&
      other.receipt == receipt &&
      other.maximumSnapshotLifetime == maximumSnapshotLifetime &&
      other.replay == replay;

  @override
  int get hashCode =>
      Object.hash(idempotency, receipt, maximumSnapshotLifetime, replay);
}

/// The optional `limits` discovery member, divided into capability groups.
/// An absent group or field is not pre-advertised; it never means infinite.
@immutable
final class AdvertisedLimits {
  /// Advertised limits.
  const AdvertisedLimits({
    this.page,
    this.request,
    this.resource,
    this.selector,
    this.patch,
    this.sequence,
    this.validation,
    this.transaction,
    this.retention,
  });

  /// Decodes the `limits` member.
  factory AdvertisedLimits.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return AdvertisedLimits(
      page: r.optionalDecode('page', PageLimits.fromJson),
      request: r.optionalDecode('request', RequestLimits.fromJson),
      resource: r.optionalDecode('resource', ResourceLimits.fromJson),
      selector: r.optionalDecode('selector', SelectorLimits.fromJson),
      patch: r.optionalDecode('patch', PatchLimits.fromJson),
      sequence: r.optionalDecode('sequence', SequenceLimits.fromJson),
      validation: r.optionalDecode('validation', ValidationLimits.fromJson),
      transaction: r.optionalDecode('transaction', TransactionLimits.fromJson),
      retention: r.optionalDecode('retention', RetentionLimits.fromJson),
    );
  }

  /// The `page` group.
  final PageLimits? page;

  /// The `request` group.
  final RequestLimits? request;

  /// The `resource` group.
  final ResourceLimits? resource;

  /// The `selector` group.
  final SelectorLimits? selector;

  /// The `patch` group.
  final PatchLimits? patch;

  /// The `sequence` group.
  final SequenceLimits? sequence;

  /// The `validation` group.
  final ValidationLimits? validation;

  /// The `transaction` group.
  final TransactionLimits? transaction;

  /// The `retention` group.
  final RetentionLimits? retention;

  /// The wire form.
  JsonObject toJson() => _members({
    'page': page?.toJson(),
    'request': request?.toJson(),
    'resource': resource?.toJson(),
    'selector': selector?.toJson(),
    'patch': patch?.toJson(),
    'sequence': sequence?.toJson(),
    'validation': validation?.toJson(),
    'transaction': transaction?.toJson(),
    'retention': retention?.toJson(),
  });

  @override
  bool operator ==(Object other) =>
      other is AdvertisedLimits &&
      other.page == page &&
      other.request == request &&
      other.resource == resource &&
      other.selector == selector &&
      other.patch == patch &&
      other.sequence == sequence &&
      other.validation == validation &&
      other.transaction == transaction &&
      other.retention == retention;

  @override
  int get hashCode => Object.hash(
    page,
    request,
    resource,
    selector,
    patch,
    sequence,
    validation,
    transaction,
    retention,
  );
}

/// A Scope aggregate policy bounding Links per endpoint.
@immutable
final class MaximumEndpointMultiplicity {
  /// A policy.
  const MaximumEndpointMultiplicity({
    required this.linkConformsTo,
    required this.endpoint,
    required this.max,
  });

  /// Decodes a policy.
  factory MaximumEndpointMultiplicity.fromJson(
    Object? json, [
    String path = '',
  ]) {
    final r = JsonReader.of(json, path);
    return MaximumEndpointMultiplicity(
      linkConformsTo: r.string('linkConformsTo'),
      endpoint: r.decode('endpoint', LinkEndpoint.fromJson),
      max: r.integer('max'),
    );
  }

  /// The Link Type the policy applies to by conformance.
  final String linkConformsTo;

  /// The endpoint the bound counts at.
  final LinkEndpoint endpoint;

  /// The largest number of such Links one endpoint may carry.
  final int max;

  /// The wire form.
  JsonObject toJson() => {
    'linkConformsTo': linkConformsTo,
    'endpoint': endpoint.toJson(),
    'max': max,
  };

  @override
  bool operator ==(Object other) =>
      other is MaximumEndpointMultiplicity &&
      other.linkConformsTo == linkConformsTo &&
      other.endpoint == endpoint &&
      other.max == max;

  @override
  int get hashCode => Object.hash(linkConformsTo, endpoint, max);
}

/// The machine-readable Scope discovery document, for any profile.
///
/// Members are validated against the advertised [profile]: `operations` is
/// required above Read and prohibited in it, and the history, receipt,
/// snapshot, changefeed and Event members are required exactly in the
/// Transactional profile.
@immutable
final class ScopeDiscovery {
  ScopeDiscovery._({
    required this.profile,
    required this.scope,
    required this.beads,
    required this.links,
    required this.types,
    required this.operations,
    required this.aliases,
    required this.order,
    required this.limits,
    required List<MaximumEndpointMultiplicity>? maximumEndpointMultiplicity,
    required JsonObject? historicalResolution,
    required this.scopeEpoch,
    required this.authorizationView,
    required this.headPosition,
    required this.minimumReplayPosition,
    required this.receipts,
    required this.snapshot,
    required this.changes,
    required this.events,
  }) : maximumEndpointMultiplicity = maximumEndpointMultiplicity == null
           ? null
           : List.unmodifiable(maximumEndpointMultiplicity),
       historicalResolution = historicalResolution == null
           ? null
           : freezeObject(historicalResolution);

  /// A Read discovery document.
  factory ScopeDiscovery.read({
    required String scope,
    required String beads,
    required String links,
    required String types,
    String? aliases,
    String? order,
    AdvertisedLimits? limits,
    List<MaximumEndpointMultiplicity>? maximumEndpointMultiplicity,
  }) => ScopeDiscovery._(
    profile: Profile.read,
    scope: scope,
    beads: beads,
    links: links,
    types: types,
    operations: null,
    aliases: aliases,
    order: order,
    limits: limits,
    maximumEndpointMultiplicity: maximumEndpointMultiplicity,
    historicalResolution: null,
    scopeEpoch: null,
    authorizationView: null,
    headPosition: null,
    minimumReplayPosition: null,
    receipts: null,
    snapshot: null,
    changes: null,
    events: null,
  );

  /// A Read+Update discovery document.
  factory ScopeDiscovery.readUpdate({
    required String scope,
    required String beads,
    required String links,
    required String types,
    required String operations,
    required String aliases,
    String? order,
    AdvertisedLimits? limits,
    List<MaximumEndpointMultiplicity>? maximumEndpointMultiplicity,
  }) => ScopeDiscovery._(
    profile: Profile.readUpdate,
    scope: scope,
    beads: beads,
    links: links,
    types: types,
    operations: operations,
    aliases: aliases,
    order: order,
    limits: limits,
    maximumEndpointMultiplicity: maximumEndpointMultiplicity,
    historicalResolution: null,
    scopeEpoch: null,
    authorizationView: null,
    headPosition: null,
    minimumReplayPosition: null,
    receipts: null,
    snapshot: null,
    changes: null,
    events: null,
  );

  /// A Transactional discovery document.
  factory ScopeDiscovery.transactional({
    required String scope,
    required String beads,
    required String links,
    required String types,
    required String operations,
    required String aliases,
    required ScopeEpoch scopeEpoch,
    required AuthorizationView authorizationView,
    required ScopePosition headPosition,
    required ScopePosition minimumReplayPosition,
    required String receipts,
    required String snapshot,
    required String changes,
    required String events,
    String? order,
    AdvertisedLimits? limits,
    List<MaximumEndpointMultiplicity>? maximumEndpointMultiplicity,
  }) => ScopeDiscovery._(
    profile: Profile.transactional,
    scope: scope,
    beads: beads,
    links: links,
    types: types,
    operations: operations,
    aliases: aliases,
    order: order,
    limits: limits,
    maximumEndpointMultiplicity: maximumEndpointMultiplicity,
    historicalResolution: null,
    scopeEpoch: scopeEpoch,
    authorizationView: authorizationView,
    headPosition: headPosition,
    minimumReplayPosition: minimumReplayPosition,
    receipts: receipts,
    snapshot: snapshot,
    changes: changes,
    events: events,
  );

  /// Decodes a discovery document, refusing a `bdpVersion` other than
  /// [bdpVersion] with [UnsupportedBdpVersion].
  factory ScopeDiscovery.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    final version = r.string('bdpVersion');
    if (version != bdpVersion) throw UnsupportedBdpVersion(version);
    final profile = r.decode('profile', Profile.fromJson);
    final transactional = profile == Profile.transactional;

    String? member(String key, {required bool required}) {
      if (required) return r.string(key);
      if (r.has(key)) {
        throw FormatException(
          '${r.at(key)}: prohibited for profile ${profile.wire}',
        );
      }
      return null;
    }

    final operations = member('operations', required: profile != Profile.read);
    final aliases = profile == Profile.read
        ? r.optionalString('aliases')
        : r.string('aliases');
    return ScopeDiscovery._(
      profile: profile,
      scope: r.string('scope'),
      beads: r.string('beads'),
      links: r.string('links'),
      types: r.string('types'),
      operations: operations,
      aliases: aliases,
      order: r.optionalString('order'),
      limits: r.optionalDecode('limits', AdvertisedLimits.fromJson),
      maximumEndpointMultiplicity: r.optionalList(
        'maximumEndpointMultiplicity',
        MaximumEndpointMultiplicity.fromJson,
      ),
      historicalResolution: r.optionalObject('historicalResolution'),
      scopeEpoch: transactional
          ? r.decode('scopeEpoch', ScopeEpoch.fromJson)
          : _prohibited(r, 'scopeEpoch', profile),
      authorizationView: transactional
          ? r.decode('authorizationView', AuthorizationView.fromJson)
          : _prohibited(r, 'authorizationView', profile),
      headPosition: transactional
          ? r.decode('headPosition', ScopePosition.fromJson)
          : _prohibited(r, 'headPosition', profile),
      minimumReplayPosition: transactional
          ? r.decode('minimumReplayPosition', ScopePosition.fromJson)
          : _prohibited(r, 'minimumReplayPosition', profile),
      receipts: member('receipts', required: transactional),
      snapshot: member('snapshot', required: transactional),
      changes: member('changes', required: transactional),
      events: member('events', required: transactional),
    );
  }

  /// The advertised cumulative profile.
  final Profile profile;

  /// The canonical Scope URL; the base for resolving local IDs.
  final String scope;

  /// The Bead collection URL.
  final String beads;

  /// The Link collection URL.
  final String links;

  /// The Type inventory URL.
  final String types;

  /// The Operation Directory URL, above Read.
  final String? operations;

  /// The alias root, when alias resolution is served.
  final String? aliases;

  /// The advertised collection order; absent means `canonical-uri`.
  final String? order;

  /// Pre-advertised limits.
  final AdvertisedLimits? limits;

  /// Maximum endpoint multiplicity policies.
  final List<MaximumEndpointMultiplicity>? maximumEndpointMultiplicity;

  /// The History capability advertisement, carried verbatim.
  final JsonObject? historicalResolution;

  /// The current Scope epoch (Transactional).
  final ScopeEpoch? scopeEpoch;

  /// The Authorization View the request was bound to (Transactional).
  final AuthorizationView? authorizationView;

  /// The projected head position (Transactional).
  final ScopePosition? headPosition;

  /// The oldest position still legal as a changefeed cursor (Transactional).
  final ScopePosition? minimumReplayPosition;

  /// The receipts root (Transactional).
  final String? receipts;

  /// The snapshot creation target (Transactional).
  final String? snapshot;

  /// The Scope changefeed (Transactional).
  final String? changes;

  /// The Scope Event Source (Transactional).
  final String? events;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{
      'bdpVersion': bdpVersion,
      'profile': profile.toJson(),
      'scope': scope,
    };
    putIfPresent(json, 'scopeEpoch', scopeEpoch?.toJson());
    putIfPresent(json, 'authorizationView', authorizationView?.toJson());
    putIfPresent(json, 'headPosition', headPosition?.toJson());
    putIfPresent(
      json,
      'minimumReplayPosition',
      minimumReplayPosition?.toJson(),
    );
    json['beads'] = beads;
    json['links'] = links;
    json['types'] = types;
    putIfPresent(json, 'operations', operations);
    putIfPresent(json, 'aliases', aliases);
    putIfPresent(json, 'receipts', receipts);
    putIfPresent(json, 'snapshot', snapshot);
    putIfPresent(json, 'changes', changes);
    putIfPresent(json, 'events', events);
    putIfPresent(json, 'order', order);
    putIfPresent(json, 'limits', limits?.toJson());
    putIfPresent(
      json,
      'maximumEndpointMultiplicity',
      switch (maximumEndpointMultiplicity) {
        null => null,
        final policies => [for (final policy in policies) policy.toJson()],
      },
    );
    putIfPresent(json, 'historicalResolution', historicalResolution);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is ScopeDiscovery && jsonEquality.equals(other.toJson(), toJson());

  @override
  int get hashCode => jsonEquality.hash(toJson());

  @override
  String toString() => 'ScopeDiscovery(${profile.wire} $scope)';
}

/// The Operation Directory: mutation target names mapped to target URLs
/// relative to the directory.
@immutable
final class OperationDirectory {
  /// A directory of [targets].
  OperationDirectory(Map<String, String> targets)
    : targets = Map.unmodifiable(targets);

  /// Decodes a directory document.
  factory OperationDirectory.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return OperationDirectory({for (final key in r.keys) key: r.string(key)});
  }

  /// Every advertised target, by directory name.
  final Map<String, String> targets;

  /// The relative target for [name], or `null` when the Scope does not
  /// advertise it.
  String? operator [](String name) => targets[name];

  /// The wire form.
  JsonObject toJson() => Map.of(targets);

  @override
  bool operator ==(Object other) =>
      other is OperationDirectory &&
      const MapEquality<String, String>().equals(other.targets, targets);

  @override
  int get hashCode => const MapEquality<String, String>().hash(targets);
}

Null _prohibited(JsonReader reader, String key, Profile profile) {
  if (reader.has(key)) {
    throw FormatException(
      '${reader.at(key)}: prohibited for profile ${profile.wire}',
    );
  }
  return null;
}

JsonObject _members(Map<String, Object?> members) => {
  for (final entry in members.entries)
    if (entry.value != null) entry.key: entry.value,
};
