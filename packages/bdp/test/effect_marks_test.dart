// What the authority does to the world is an `@effect`, so `genesis_lint`
// rejects it from a build or from any other code that no effect leaf owns:
// every member of ScopeAuthority's interface, inherited ones included, is
// either marked or reviewed as acting on nothing, and the analyzer reports
// the marked ones where a build calls them. The same holds of every public
// type, extension and function the package exports: each member is an
// `@effect` or on a reviewed list of members that act on nothing.
// The probe shells out to `dart analyze`, which builds the lint plugin on a
// cold runner; that one-time cost exceeds the default 30 s test timeout.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:test/test.dart';

import 'support/lint_probe.dart';

/// This package's root, wherever `dart test` was started from.
final Directory _package = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:bdp/bdp.dart'))!,
).parent.parent;

/// The members of ScopeAuthority that act on the world: they commit to the
/// store, close it, open a stream over it or retain a snapshot handle.
const _effects = {
  // Administration.
  'close',
  'reinitialize',
  'installType',
  // The raw surface the HTTP handler drives.
  'mutate',
  'watch',
  'snapshotDocument',
  // LocalScope's mutations, follow and snapshot.
  'createBead',
  'updateBeadProperties',
  'deleteBead',
  'createLink',
  'updateLinkProperties',
  'deleteLink',
  'batch',
  'follow',
  'snapshot',
};

/// Members that act on nothing: each reads the store in one transaction, or
/// answers from the value it is called on.
const _reads = {
  // Getters, the configured limits among them.
  'address',
  'discovery',
  'epoch',
  'typeRegistry',
  'receiptRetention',
  'snapshotLifetime',
  'defaultPageItems',
  'maximumPageItems',
  'maximumOperations',
  'backlogBatchGroups',
  // The raw read surface.
  'observe',
  'discoveryDocument',
  'operationDirectory',
  'typeInventory',
  'typeDescriptor',
  'resource',
  'collection',
  'incidentLinkPage',
  'receipt',
  'changePage',
  'snapshotHandle',
  'events',
  'requireMinimum',
  // LocalScope's reads.
  'readBead',
  'readLink',
  'beads',
  'links',
  'incidentLinks',
  'nextBeads',
  'nextLinks',
  'types',
  'nextTypes',
  'readTypeDescriptor',
  'readReceipt',
  'readReceiptPage',
  'changes',
  'nextChanges',
};

/// The exported types every member of which answers from the value it is
/// called on: the wire types and their codecs, the opaque tokens, the
/// problems and exceptions, the queries and the replica, whose `apply`
/// answers a new replica. A type here has no `@effect` member.
const _values = {
  // Wire records, references and pages.
  'Attribution', 'AttributionStatus', 'BeadRecord', 'LinkRecord',
  'ResourceRecord', 'ResourceIdentity', 'ResourceKind', 'DeletedIdentity',
  'LinkEndpoint', 'Reference', 'UriReference', 'PinnedReference',
  'TypedLinkReference', 'Page',
  // Types.
  'TypeDescriptor', 'TypeSummary', 'EndpointConstraint',
  'ExternalEndpointPolicy', 'OwnedLinkDeclaration',
  // Discovery and its limits.
  'ScopeDiscovery', 'Profile', 'OperationDirectory', 'AdvertisedLimits',
  'PageLimits', 'RequestLimits', 'ResourceLimits', 'SelectorLimits',
  'PatchLimits', 'SequenceLimits', 'ValidationLimits', 'TransactionLimits',
  'RetentionLimits', 'MaximumEndpointMultiplicity', 'UnsupportedBdpVersion',
  // Mutations, patches and their answers.
  'MutationOperation', 'CreateBead', 'UpdateBeadProperties', 'DeleteBead',
  'CreateLink', 'UpdateLinkProperties', 'DeleteLink', 'BatchRequest',
  'UnsupportedOperation', 'PatchOp', 'AddOp', 'RemoveOp', 'ReplaceOp',
  'PropertyChange', 'MutationResponse', 'ResultResponse', 'ReceiptResponse',
  'MutationResult', 'MutationOutcome', 'MutationReceipt',
  'MutationReceiptPage', 'ReceiptResult', 'ReceiptOutcome', 'ReceiptStatus',
  'ReceiptDetail', 'AllocatedIdentity',
  // The changefeed, events and snapshots, and the replica they fold into.
  'ChangefeedStart', 'StartNow', 'AfterCheckpoint', 'ChangefeedPage',
  'ChangeGroup', 'StateChange', 'Upsert', 'Tombstone', 'ErasureRecord',
  'ErasureDigest', 'Event', 'EventType', 'EventPage', 'EventData',
  'CreatedData', 'UpdatedData', 'DeletedData', 'LinkDeltaData',
  'OwnedLinkChange', 'OwnedLinkCreated', 'OwnedLinkUpdated',
  'OwnedLinkDeleted', 'OwnedLinkDelta', 'SnapshotManifest', 'Replica',
  'ReplicationException', 'ReplicationFault', 'SseFrame', 'SseMessage',
  'SseRetry',
  // Opaque tokens.
  'OpaqueToken', 'Revision', 'Checkpoint', 'ScopeEpoch', 'ScopePosition',
  'IdempotencyKey', 'EventId', 'TransactionId', 'AuthorizationView',
  // Problems and exceptions.
  'ProblemDetails', 'ProblemCodes', 'RetryDisposition',
  'ValidationDiagnostic', 'BdpException', 'BdpHttpException',
  'BdpProblemException', 'BdpProtocolException', 'AuthorityProblem',
  // Queries.
  'BeadQuery', 'LinkQuery', 'LinkDirection', 'Selector',
  // The authority's reads, receipts and Types, as values.
  'AuthorityRead', 'AuthorityReceipt', 'AuthorityNotAdmitted',
  'AuthorityResourceKind', 'AuthorityTypeDescriptor',
  'AuthorityEndpointConstraint', 'AuthorityTypeRevision',
  // What a bd call printed, and how it failed; what a failed write was.
  'BdOutput', 'BdFailure', 'BdWriteFailure',
};

/// The members of the exported service types that act on nothing, by the
/// type that declares them, each reviewed. ScopeAuthority's are [_reads].
final _servicePure = {
  // A Scope's reads, whoever answers them.
  for (final type in ['LocalScope', 'ScopeClient'])
    for (final read in [
      'readBead',
      'readLink',
      'beads',
      'links',
      'incidentLinks',
      'nextBeads',
      'nextLinks',
      'types',
      'nextTypes',
      'readTypeDescriptor',
      'readReceipt',
      'readReceiptPage',
      'changes',
      'nextChanges',
      'discovery',
    ])
      '$type.$read',
  // What a client was configured with, and how it discovers a Scope: one
  // read of its discovery document.
  'ScopeClient.operations', 'ScopeClient.reconnectDelay',
  'ScopeClient.discover',
  // An authority's raw read surface, whichever authority answers it: each
  // reads the Scope it serves, or answers from the value it is called on.
  for (final read in [
    'address',
    'typeRegistry',
    'epoch',
    'observe',
    'discoveryDocument',
    'operationDirectory',
    'typeInventory',
    'typeDescriptor',
    'resource',
    'collection',
    'incidentLinkPage',
    'receipt',
    'changePage',
    'snapshotHandle',
    'events',
    'requireMinimum',
  ])
    'AuthorityScope.$read',
  // The targets the authority lists and refuses, and the request body it
  // accepts and advertises: constants.
  'ScopeAuthority.unservedTargets', 'ScopeAuthority.maximumBodyBytes',
  // Whether a follow has ended: a future, observed, not an act.
  'ChangefeedSubscription.done',
  // Paging every bead, link or incident link: reads.
  'LocalScopeReading.allBeads', 'LocalScopeReading.allLinks',
  'LocalScopeReading.allIncidentLinks',
  // A Type registry answers from what it holds; installing writes only to
  // the registry it is called on, never a store, and the authority's own is
  // a read-only view whose install throws.
  'AuthorityTypeRegistry.[]', 'AuthorityTypeRegistry.schemaOf',
  'AuthorityTypeRegistry.install', 'AuthorityTypeRegistry.effectiveTypes',
  'AuthorityTypeRegistry.conformingTo', 'AuthorityTypeRegistry.validate',
  'AuthorityTypeRegistry.all', 'AuthorityTypeRegistry.length',
  'AuthorityTypeRegistry.revisionsOf', 'AuthorityTypeRegistry.project',
  // Functions that make a value: the handler over an authority, the frames
  // of an SSE body, how a Scope reads a JSON value's numbers and identity,
  // and the revision a Type's content is named by.
  'authorityHandler', 'decodeSse', 'isAdmissibleNumber', 'semanticText',
  'authorityTypeRevisionOf',
  // The bd authority's reads: the projection's, or what it was opened with,
  // its constants among them.
  for (final read in [
    'address',
    'typeRegistry',
    'epoch',
    'observe',
    'discoveryDocument',
    'operationDirectory',
    'typeInventory',
    'typeDescriptor',
    'resource',
    'collection',
    'incidentLinkPage',
    'receipt',
    'changePage',
    'snapshotHandle',
    'events',
    'requireMinimum',
    'readBead',
    'readLink',
    'beads',
    'links',
    'incidentLinks',
    'nextBeads',
    'nextLinks',
    'types',
    'nextTypes',
    'readTypeDescriptor',
    'readReceipt',
    'readReceiptPage',
    'changes',
    'nextChanges',
    'discovery',
    'interval',
    'confirmInterval',
    'within',
    'receiptRetention',
    'changeBound',
    'beadType',
    'linkType',
    'defaultPageItems',
    'maximumPageItems',
    'maximumOperations',
    'servedOperations',
    'safetyFactor',
    'safetyInterval',
    'followsJournal',
  ])
    'BdScopeAuthority.$read',
  // What a bd server and a bd CLI were made with, how a failed call is
  // explained from what it printed, and how a failed write is read from its
  // receipt's problem.
  'BdStoreServer.url', 'BdStoreServer.bdVersion', 'BdStoreServer.interval',
  'BdProcessCli.executable', 'BdProcessCli.workspace', 'BdProcessCli.actor',
  'BdProcessCli.bound', 'BdProcessCli.environment',
  'BdProcessCli.environmentAllowlist', 'bdExplain', 'bdWriteFailureOf',
};

/// The public constructors of the exported types that are not values, each
/// reviewed. `genesis_lint` diagnoses calls to `@effect` members, never
/// instance creation, so a constructor is classified here instead of
/// marked: [_actingConstructors] act on the world and the lint cannot
/// police them; [_pureConstructors] hold what they are given. A new public
/// constructor fails the inventory until it is classified. A value type's
/// constructors are whitelisted with the type.
const _actingConstructors = {
  // Opening an authority opens, and may initialize, its SQLite store.
  'ScopeAuthority.file', 'ScopeAuthority.memory',
};

/// See [_actingConstructors].
const _pureConstructors = {
  // A client holds the HTTP client, discovery and headers it is given;
  // discovering a Scope is the static `discover`, a read.
  'ScopeClient.new',
  // A handler client holds its handler; sending through it is `send`, an
  // @effect.
  'HandlerClient.new',
  // An empty registry, in memory.
  'AuthorityTypeRegistry.new',
  // The implicit constructors of the abstract contracts, which construct
  // nothing outside the classes that implement them.
  'LocalScope.new', 'ChangefeedSubscription.new', 'AuthorityScope.new',
  'BdCli.new',
  // A bd CLI holds its configuration; it runs bd only from `run`, an
  // @effect.
  'BdProcessCli.new',
};

/// Whether [element] carries the `genesis_foundation` mark [className].
bool _marked(Element element, String className) =>
    element.metadata.annotations.any(
      (annotation) => switch (annotation.element) {
        PropertyAccessorElement(:final variable) =>
          variable.type.element?.name == className &&
              variable.type.element?.library?.uri.toString() ==
                  'package:genesis_foundation/src/annotations.dart',
        _ => false,
      },
    );

/// The public members of [type]'s interface, declared or inherited from
/// anything but `Object`, each with whether it or a member it overrides is
/// marked `@effect`: what `genesis_lint` treats as an effect.
Map<String, bool> _interface(InterfaceElement type) {
  final members = <String, bool>{};
  for (final owner in [
    type,
    for (final supertype in type.allSupertypes)
      if (!supertype.isDartCoreObject) supertype.element,
  ]) {
    for (final member in <ExecutableElement>[
      ...owner.methods,
      ...owner.getters,
      ...owner.setters,
    ]) {
      final name = member.name;
      if (name == null || name.startsWith('_') || member.isStatic) continue;
      final effect = _marked(member, 'EffectMarker');
      members[name] = (members[name] ?? false) || effect;
    }
  }
  return members;
}

/// The path of the library [uri] names.
String _pathOf(String uri) =>
    File.fromUri(Isolate.resolvePackageUriSync(Uri.parse(uri))!).path;

/// Whether [member] is declared outside this package — by the SDK, `http`
/// or another dependency — which reviews its own.
bool _foreign(Element member) =>
    member.library?.uri.scheme != 'package' ||
    member.library?.uri.pathSegments.first != 'bdp';

void main() {
  late Map<String, bool> authority;
  late ({
    Set<String> checked,
    Set<String> reviewed,
    List<String> unmarked,
    List<String> mislabelled,
    Set<String> constructors,
  })
  surface;

  setUpAll(() async {
    final collection = AnalysisContextCollection(
      includedPaths: [Directory('${_package.path}/lib').path],
    );
    try {
      final path = '${_package.path}/lib/src/authority/authority.dart';
      final library = await collection
          .contextFor(path)
          .currentSession
          .getResolvedLibrary(path);
      final type = (library as ResolvedLibraryResult).element.getClass(
        'ScopeAuthority',
      )!;
      authority = _interface(type);
    } finally {
      await collection.dispose();
    }
    surface = await _surfaceInventory();
  });

  test('every member of every public type, extension and function the '
      'package exports, inherited members included, is an @effect or a '
      'reviewed pure member, and every value type acts on nothing', () {
    final (:checked, :reviewed, :unmarked, :mislabelled, constructors: _) =
        surface;
    expect(
      unmarked,
      isEmpty,
      reason:
          'each of these is exported and neither @effect nor a reviewed '
          'pure member: mark it, or review it with a reason',
    );
    expect(mislabelled, isEmpty, reason: 'a value type acts on the world');
    expect(
      _values.difference(checked),
      isEmpty,
      reason: 'a value type the list names is no longer exported',
    );
    expect(
      _servicePure.difference(reviewed),
      isEmpty,
      reason: 'a pure member the list names is no longer exported',
    );
    expect(
      checked,
      containsAll([
        'ScopeAuthority',
        'ScopeClient',
        'LocalScope',
        'ChangefeedSubscription',
        'LocalScopeReading',
        'HandlerClient',
      ]),
    );
  });

  test('every public constructor of an exported type that is not a value is '
      'classified: the lint does not see instance creation, so the ones that '
      'act are named', () {
    expect(
      surface.constructors.difference({
        ..._actingConstructors,
        ..._pureConstructors,
      }),
      isEmpty,
      reason: 'a new public constructor: classify it',
    );
    expect(
      {
        ..._actingConstructors,
        ..._pureConstructors,
      }.difference(surface.constructors),
      isEmpty,
      reason: 'a classified constructor the package no longer exports',
    );
  });

  test('every public member of ScopeAuthority, inherited ones included, is '
      'reviewed: an effect or a read', () {
    expect(
      authority.keys.toSet(),
      {..._effects, ..._reads},
      reason: 'a member added to the authority is classified here',
    );
  });

  test('each of its effects is marked @effect, on itself or on a member it '
      'overrides', () {
    expect({
      for (final MapEntry(:key, :value) in authority.entries)
        if (value) key,
    }, _effects);
  });

  test('a build that administers an authority is a lint error at every '
      'effect it calls and at no read', () async {
    final fixtures = Directory('${_package.path}/test/lint_fixtures');
    final found = await analyzeEffects(
      fixtures: fixtures,
      package: _package,
      workspace: workspaceOf(_package),
    );
    expect(found.keys.toSet(), markedEffects(fixtures));
    expect(found.values.toSet(), {
      'reinitialize',
      'close',
      'installType',
      'mutate',
      'watch',
      'snapshotDocument',
      'send',
    });
  });
}

/// The exported surface of `package:bdp/bdp.dart` and
/// `package:bdp/testing.dart`, inventoried member by member.
Future<
  ({
    Set<String> checked,
    Set<String> reviewed,
    List<String> unmarked,
    List<String> mislabelled,
    Set<String> constructors,
  })
>
_surfaceInventory() async {
  final paths = [
    _pathOf('package:bdp/bdp.dart'),
    _pathOf('package:bdp/testing.dart'),
    _pathOf('package:bdp/bd.dart'),
  ];
  final collection = AnalysisContextCollection(includedPaths: paths);
  final exported = <String, Element>{};
  try {
    for (final path in paths) {
      final library = await collection
          .contextFor(path)
          .currentSession
          .getResolvedLibrary(path);
      exported.addAll(
        (library as ResolvedLibraryResult)
            .element
            .exportNamespace
            .definedNames2,
      );
    }
  } finally {
    await collection.dispose();
  }
  final checked = <String>{};
  final reviewed = <String>{};
  final unmarked = <String>[];
  final mislabelled = <String>[];
  final constructors = <String>{};
  void judge(String owner, String name, Element member, bool effect) {
    final key = '${member.enclosingElement?.name ?? owner}.$name';
    if (_values.contains(owner)) {
      if (effect) mislabelled.add('$owner.$name');
      return;
    }
    if (owner == 'ScopeAuthority' &&
        (_effects.contains(name) || _reads.contains(name))) {
      return;
    }
    if (effect) return;
    if (_servicePure.contains(key)) {
      reviewed.add(key);
    } else if (_servicePure.contains('$owner.$name')) {
      reviewed.add('$owner.$name');
    } else {
      unmarked.add(key);
    }
  }

  for (final MapEntry(key: name, value: element) in exported.entries) {
    switch (element) {
      case InterfaceElement type:
        checked.add(name);
        if (!_values.contains(name)) {
          for (final constructor in type.constructors) {
            if (!constructor.isPublic) continue;
            constructors.add('$name.${constructor.name ?? 'new'}');
          }
        }
        for (final MapEntry(key: member, value: declaration)
            in type.interfaceMembers.entries) {
          if (!member.isPublic || _foreign(declaration)) continue;
          final effect =
              _marked(declaration.baseElement, 'EffectMarker') ||
              type.allSupertypes.any(
                (supertype) => supertype.element.interfaceMembers.entries.any(
                  (entry) =>
                      entry.key.name == member.name &&
                      _marked(entry.value.baseElement, 'EffectMarker'),
                ),
              );
          judge(name, member.name, declaration, effect);
        }
        for (final member in [...type.methods, ...type.getters]) {
          if (!member.isStatic || !member.isPublic) continue;
          judge(name, member.name!, member, _marked(member, 'EffectMarker'));
        }
      case ExtensionElement extension:
        checked.add(name);
        for (final member in [...extension.methods, ...extension.getters]) {
          if (!member.isPublic) continue;
          judge(name, member.name!, member, _marked(member, 'EffectMarker'));
        }
      case TopLevelFunctionElement function:
        checked.add(name);
        final effect = _marked(function, 'EffectMarker');
        if (effect) continue;
        if (_servicePure.contains(name)) {
          reviewed.add(name);
        } else {
          unmarked.add(name);
        }
      default:
        // Type aliases and constants: no members of their own.
        break;
    }
  }
  return (
    checked: checked,
    reviewed: reviewed,
    unmarked: unmarked,
    mislabelled: mislabelled,
    constructors: constructors,
  );
}
