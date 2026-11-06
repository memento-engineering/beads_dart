import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'json_text.dart';
import 'operations.dart';
import 'patch.dart';
import 'problem.dart';
import 'store.dart';
import 'types.dart';

/// An operation failure after admission: the transaction rolls back and its
/// receipt carries [problem] located at [operation].
final class OperationFailure implements Exception {
  const OperationFailure(this.operation, this.problem);

  final Operation operation;
  final AuthorityProblem problem;

  /// The receipt form of the problem.
  JsonMap toJson() => problem.toJson(
    operationIndex: operation.index,
    operationName: operation.name,
  );
}

/// The revision of a Resource version: a digest of its canonical content.
///
/// Local discipline, not a protocol scheme: SHA-256 over the canonical JSON
/// (sorted members, Dart number spelling) of the record without its
/// `revision`, base64url, first 22 characters. Equal versions share a
/// token, which the revision rules permit; no peer derives tokens from it.
String revisionOf(JsonMap content) => base64Url
    .encode(sha256.convert(utf8.encode(canonicalJson(content))).bytes)
    .substring(0, 22);

/// One Mutation Transaction staged in memory against the store's committed
/// state. Operations see earlier operations' effects; nothing is written
/// until [commit].
final class StagedTransaction {
  StagedTransaction({
    required this.store,
    required this.types,
    required this.seq,
    required this.transaction,
    required this.time,
    required this.inadmissibleNumbers,
  });

  final SqliteScopeStore store;
  final AuthorityTypeRegistry types;

  /// The group sequence this transaction will occupy if it has effect.
  final int seq;
  final String transaction;
  final String time;

  /// Body pointers of inadmissible number literals, with the exact values
  /// they denote.
  final Map<String, String> inadmissibleNumbers;

  ScopeAddress get _address => store.address;

  final Map<String, JsonMap?> _staged = {};
  final Map<String, JsonMap> _tombstones = {};
  final List<String> _touched = [];
  final Map<int, String> _allocated = {};

  /// Ordered result entries, one per operation.
  final List<JsonMap> results = [];

  /// Ordered Events with their group ordinals.
  final List<JsonMap> events = [];
  final Map<int, Set<String>> _sources = {};

  static final _random = Random.secure();

  /// Applies [operations] in order; throws [OperationFailure] at the first
  /// that cannot apply.
  void run(List<Operation> operations) {
    for (final op in operations) {
      switch (op) {
        case CreateBead():
          _createBead(op);
        case CreateLink():
          _createLink(op);
        case UpdateProperties():
          _update(op);
        case Delete():
          _delete(op);
      }
    }
  }

  /// Writes the change group, and through it the staged state; returns the
  /// group as the log serves it.
  ///
  /// A Resource created and deleted within this transaction was never in
  /// the projection, so it contributes no change; its identity is still
  /// committed.
  JsonMap commit() {
    final created = _allocated.values.toSet();
    final changes = <JsonMap>[];
    for (final id in _touched) {
      final kind = _kindOf(id);
      final record = _staged[id];
      if (record != null) {
        changes.add({
          'operation': 'upsert',
          'resourceKind': kind.name,
          'resource': record,
        });
      } else if (!created.contains(id)) {
        changes.add({
          'operation': 'tombstone',
          'resourceKind': kind.name,
          'resource': _tombstones[id],
        });
      }
    }
    store.appendGroup(
      seq: seq,
      transaction: transaction,
      changes: changes,
      events: events,
      sources: _sources,
      allocated: created,
    );
    return store.groupsAfter(seq - 1, limit: 1).single;
  }

  AuthorityResourceKind _kindOf(String id) =>
      _address.localId(id).startsWith(AuthorityResourceKind.bead.root)
      ? AuthorityResourceKind.bead
      : AuthorityResourceKind.link;

  JsonMap? _live(String id) =>
      _staged.containsKey(id) ? _staged[id] : store.resource(_kindOf(id), id);

  void _stage(String id, JsonMap? record, {JsonMap? previous}) {
    if (!_touched.contains(id)) _touched.add(id);
    _staged[id] = record;
    if (record == null && previous != null) {
      _tombstones[id] = {
        'id': id,
        'type': previous['type'],
        'revision': previous['revision'],
      };
    }
  }

  void _emit(
    String type,
    String subject,
    String subjectType,
    JsonMap data,
    Set<String> sources,
  ) {
    final ordinal = events.length;
    events.add({
      'id': '${store.checkpoint(seq)}_$ordinal',
      'ordinal': ordinal,
      'type': type,
      'source': _address.events,
      'subject': subject,
      'subjectType': subjectType,
      'transaction': transaction,
      'time': time,
      'data': data,
    });
    _sources[ordinal] = sources;
  }

  Never _fail(
    Operation op,
    String code,
    String member, {
    String? title,
    String? detail,
    List<JsonMap>? diagnostics,
  }) => throw OperationFailure(
    op,
    AuthorityProblem(
      code,
      title: title,
      detail: detail,
      pointer: '${op.pointer}$member',
      diagnostics: diagnostics,
    ),
  );

  Never _invalid(Operation op, String member, String message) => _fail(
    op,
    'validation-failed',
    member,
    title: 'Resource state is not admissible',
    diagnostics: [
      {'message': message},
    ],
  );

  String _identity(Operation op, String? supplied, AuthorityResourceKind kind) {
    if (supplied != null) {
      if (store.everCommitted(supplied) || _staged.containsKey(supplied)) {
        _fail(
          op,
          'identity-taken',
          '/id',
          title: 'Supplied identity was previously committed',
          detail: '${_address.localId(supplied)} is never reassigned.',
        );
      }
      return supplied;
    }
    while (true) {
      final segment = [
        for (var i = 0; i < 8; i++)
          _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();
      final id = '${_address.scope}${kind.root}$segment';
      if (!store.everCommitted(id) && !_staged.containsKey(id)) return id;
    }
  }

  String? _resolve(Ref ref) => switch (ref) {
    CanonicalRef(:final url) => url,
    LabelRef(:final index) => _allocated[index],
    UnresolvableRef() => null,
  };

  AuthorityTypeDescriptor _type(
    Operation op,
    String type,
    AuthorityResourceKind kind,
  ) {
    final descriptor = types[type];
    if (descriptor == null) {
      _fail(op, 'type-not-installed', '/type', title: 'Type is not installed');
    }
    if (descriptor.describes != kind) {
      _invalid(op, '/type', '$type describes ${descriptor.describes.name}s');
    }
    return descriptor;
  }

  void _admissible(Operation op, String member, Object? value) {
    final prefix = '${op.pointer}$member';
    final offending = [
      ...inadmissibleNumbers.keys.where(
        (p) => p == prefix || p.startsWith('$prefix/'),
      ),
      if (_holdsInadmissible(value)) prefix,
    ];
    if (offending.isNotEmpty) {
      _fail(
        op,
        'validation-failed',
        member,
        title: 'Number literal is not admissible',
        diagnostics: [
          for (final p in offending)
            {'message': 'number at $p does not round-trip through binary64'},
        ],
      );
    }
  }

  /// Whether [value] holds, at any depth, a number whose exact decimal
  /// value does not round-trip through binary64 — an in-process caller's
  /// integer past 2^53 that no shortest literal spells, or a non-finite
  /// double.
  static bool _holdsInadmissible(Object? value) => switch (value) {
    final num n => !isAdmissibleNumber(n),
    final Map<Object?, Object?> m => m.values.any(_holdsInadmissible),
    final List<Object?> l => l.any(_holdsInadmissible),
    _ => false,
  };

  void _validate(Operation op, String type, JsonMap properties, String member) {
    final diagnostics = types.validate(type, properties);
    if (diagnostics.isNotEmpty) {
      _fail(
        op,
        'validation-failed',
        member,
        title: 'Properties violate an effective Type contract',
        diagnostics: diagnostics,
      );
    }
  }

  JsonMap _record(JsonMap content) {
    final revision = revisionOf(content);
    return {
      'id': content['id'],
      'type': content['type'],
      'revision': revision,
      for (final e in content.entries)
        if (e.key != 'id' && e.key != 'type') e.key: e.value,
    };
  }

  void _createBead(CreateBead op) {
    final id = _identity(op, op.id, AuthorityResourceKind.bead);
    _type(op, op.type, AuthorityResourceKind.bead);
    _admissible(op, '/properties', op.properties);
    _validate(op, op.type, op.properties, '/properties');
    final record = _record({
      'id': id,
      'type': op.type,
      'attribution': ?op.attribution,
      'properties': jsonCopy(op.properties),
    });
    _stage(id, record);
    _allocated[op.index] = id;
    results.add(_result(op, 'created', {'resource': record}));
    _emit(
      'created',
      id,
      op.type,
      {
        'revision': record['revision'],
        'properties': record['properties'],
        'attribution': ?op.attribution,
      },
      {id},
    );
  }

  void _createLink(CreateLink op) {
    final id = _identity(op, op.id, AuthorityResourceKind.link);
    _type(op, op.type, AuthorityResourceKind.link);
    final effective = types
        .effectiveTypes(op.type)
        .map((t) => types[t]!)
        .toList();
    final (source, sourceBead) = _endpoint(op, op.source, '/source', [
      for (final d in effective) d.source!,
    ]);
    final (target, targetBead) = _endpoint(op, op.target, '/target', [
      for (final d in effective) d.target!,
    ]);
    _admissible(op, '/properties', op.properties);
    _validate(op, op.type, op.properties, '/properties');
    final record = _record({
      'id': id,
      'type': op.type,
      'attribution': ?op.attribution,
      'source': source,
      'target': target,
      'properties': jsonCopy(op.properties),
    });
    _stage(id, record);
    _allocated[op.index] = id;
    results.add(_result(op, 'created', {'resource': record}));
    _emit(
      'created',
      id,
      op.type,
      {
        'revision': record['revision'],
        'properties': record['properties'],
        'attribution': ?op.attribution,
        'source': source,
        'target': target,
      },
      {id},
    );
    _graphFacts('linked', record, sourceBead, targetBead);
  }

  void _graphFacts(
    String type,
    JsonMap link,
    String? sourceBead,
    String? targetBead,
  ) {
    final id = link['id']! as String;
    for (final (endpoint, bead) in [
      ('source', sourceBead),
      ('target', targetBead),
    ]) {
      if (bead == null) continue;
      _emit(
        type,
        id,
        link['type']! as String,
        {
          'endpoint': endpoint,
          'link': {'id': id, 'type': link['type']},
          'source': link['source'],
          'target': link['target'],
        },
        {bead},
      );
    }
  }

  (Object, String?) _endpoint(
    CreateLink op,
    Endpoint endpoint,
    String member,
    List<AuthorityEndpointConstraint> constraints,
  ) {
    Object pinned(String uri) =>
        endpoint.pin == null ? uri : {'uri': uri, 'revision': endpoint.pin};
    switch (endpoint) {
      case LocalEndpoint(:final ref):
        final url = _resolve(ref);
        final bead = url == null ? null : _live(url);
        if (url == null || bead == null) {
          _fail(op, 'resource-not-found', member, title: 'No such Bead');
        }
        final have = types.effectiveTypes(bead['type']! as String);
        for (final c in constraints) {
          for (final required in c.conformsTo) {
            if (!have.contains(required)) {
              _invalid(
                op,
                member,
                'endpoint Bead does not conform to $required',
              );
            }
          }
        }
        return (pinned(url), url);
      case ExternalEndpoint(:final uri):
        for (final c in constraints) {
          if (c.external == 'none') {
            _invalid(op, member, 'the Link Type admits no external endpoint');
          }
          if (c.external == 'bead' && !_beadShaped(uri)) {
            _invalid(op, member, 'the Link Type admits only bead-shaped URLs');
          }
        }
        return (pinned(uri), null);
      case MiscategorizedEndpoint(:final spelling):
        _invalid(op, member, '$spelling is not a Bead reference');
    }
  }

  static bool _beadShaped(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null ||
        !(parsed.isScheme('http') || parsed.isScheme('https'))) {
      return false;
    }
    final segments = parsed.pathSegments;
    final at = segments.indexOf('beads');
    return at >= 0 && at < segments.length - 1 && segments[at + 1].isNotEmpty;
  }

  JsonMap _subject(Operation op, Ref ref, String? expectedRevision) {
    final member = '/${op.kind.kind.name}';
    final id = _resolve(ref);
    final live = id == null ? null : _live(id);
    if (live == null) {
      _fail(op, 'resource-not-found', member, title: 'No such Resource');
    }
    if (expectedRevision != null && expectedRevision != live['revision']) {
      _fail(
        op,
        'revision-mismatch',
        '/expectedRevision',
        title: 'Resource is not at the expected revision',
      );
    }
    return live;
  }

  void _update(UpdateProperties op) {
    final current = _subject(op, op.subject, op.expectedRevision);
    _admissible(op, '/change', op.change);
    final id = current['id']! as String;
    final type = current['type']! as String;
    final JsonMap next;
    try {
      next = applyPatch(current['properties']! as JsonMap, op.change);
    } on PatchFailure catch (f) {
      _fail(
        op,
        'validation-failed',
        '/change',
        title: 'Property Change cannot apply',
        diagnostics: [
          {'instanceLocation': f.instanceLocation, 'message': f.message},
        ],
      );
    }
    _validate(op, type, next, '/change');
    if (jsonEquals(next, current['properties'])) {
      results.add(_result(op, 'updated', {'resource': current}));
      return;
    }
    final record = _record({
      'id': id,
      'type': type,
      'attribution': ?op.attribution,
      'source': ?current['source'],
      'target': ?current['target'],
      'properties': next,
    });
    _stage(id, record);
    results.add(_result(op, 'updated', {'resource': record}));
    final sources = {id};
    if (op.kind == OperationKind.updateLinkProperties) {
      for (final end in [record['source'], record['target']]) {
        final uri = referenceUri(end);
        if (uri.startsWith(_address.beads)) sources.add(uri);
      }
    }
    _emit('updated', id, type, {
      'previousRevision': current['revision'],
      'revision': record['revision'],
      'change': op.change,
      'attribution': ?op.attribution,
    }, sources);
  }

  void _delete(Delete op) {
    final current = _subject(op, op.subject, op.expectedRevision);
    final id = current['id']! as String;
    final isBead = op.kind == OperationKind.deleteBead;
    if (isBead) {
      final candidates = {
        ...store.incidentLinks(id),
        ..._staged.keys.where((k) => _kindOf(k) == AuthorityResourceKind.link),
      };
      for (final link in candidates) {
        final live = _live(link);
        if (live != null &&
            (referenceUri(live['source']) == id ||
                referenceUri(live['target']) == id)) {
          _fail(
            op,
            'incident-links-exist',
            '/bead',
            title: 'Live Links are incident upon the Bead',
          );
        }
      }
    }
    _stage(id, null, previous: current);
    final identity = {
      'id': id,
      'type': current['type'],
      'revision': current['revision'],
    };
    results.add(
      _result(op, 'deleted', {
        'deleted': {'resourceKind': op.kind.kind.name, 'resource': identity},
      }),
    );
    _emit(
      'deleted',
      id,
      current['type']! as String,
      {'revision': current['revision']},
      {id},
    );
    if (!isBead) {
      String? inScope(Object? end) {
        final uri = referenceUri(end);
        return uri.startsWith(_address.beads) ? uri : null;
      }

      _graphFacts(
        'unlinked',
        current,
        inScope(current['source']),
        inScope(current['target']),
      );
    }
  }

  JsonMap _result(Operation op, String outcome, JsonMap body) => {
    'operationIndex': op.index,
    'operationName': ?op.name,
    'outcome': outcome,
    ...body,
  };
}
