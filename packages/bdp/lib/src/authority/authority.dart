import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;

import 'authority_scope.dart';
import 'identity.dart';
import 'json_text.dart';
import 'local.dart';
import 'operations.dart';
import 'problem.dart';
import 'store.dart';
import 'transaction.dart';
import 'types.dart';

/// A strict read: the body plus the Scope context it observed.
final class AuthorityRead {
  const AuthorityRead(this.body, {required this.epoch, required this.position});

  final JsonMap body;

  /// The Scope epoch the read observed.
  final String epoch;

  /// The visible Scope position the read observed.
  final String position;

  /// The constant Authorization View token.
  String get authorizationView => authorityViewToken;
}

/// The one Authorization View token.
const authorityViewToken = authorizationView;

/// A Mutation Receipt as served, plus the head position observed when it
/// was served.
final class AuthorityReceipt {
  const AuthorityReceipt(this.json, {required this.position});

  final JsonMap json;
  final String position;

  /// `completed` or `failed`.
  String get status => json['status']! as String;

  /// The failure's problem, for a `failed` receipt with detail available.
  JsonMap? get problem => json['problem'] as JsonMap?;

  /// The ordered result entries, for a `completed` receipt with detail.
  List<JsonMap> get results =>
      (json['results'] as List?)?.cast<JsonMap>() ?? const [];
}

/// Thrown by [ScopeAuthority.mutate] with `admitNew: false` when the key is
/// unknown, so the submission was neither admitted nor bound.
final class AuthorityNotAdmitted implements Exception {
  const AuthorityNotAdmitted();
}

/// The anonymous principal: every unauthenticated caller shares its
/// idempotency namespace.
const authorityAnonymousPrincipal = 'anonymous';

/// The single writer of one BDP Scope (Transactional subset) over one
/// SQLite database it opens and owns.
///
/// It is a [LocalScope]: in process, the kernel reads, mutates and follows
/// it through the same typed operations a `ScopeClient` performs over HTTP,
/// and [authorityHandler] serves the same documents on the wire.
///
/// The database is reachable only through this type, so current state
/// changes only by a committed change group.
///
/// Every mutation runs synchronously inside one SQLite write transaction
/// that holds the database write lock for its whole duration: idempotency
/// comparison, staging, the state write, the change group and the receipt
/// commit together or not at all. Calls on one isolate are therefore
/// serialized by the event loop, and calls from other connections to the
/// same file by the write lock. No receipt is ever observable as `pending`.
final class ScopeAuthority with AuthorityLocalScope implements AuthorityScope {
  /// Opens (creating if needed) the Scope database at [path] in WAL mode.
  /// The same file may be opened by several authorities, in this or other
  /// isolates; SQLite's write lock gives their commits one total order.
  ///
  /// While a [watch] stream is listened to, the authority checks SQLite's
  /// `data_version` every [liveTailInterval] and delivers the groups other
  /// connections committed, or ends the stream when another connection
  /// reinitialized the Scope. With no stream listened to it does not check.
  ///
  /// Every statement on the file, from the open's first, waits up to
  /// [lockTimeout] for a lock another connection holds instead of failing
  /// with `SQLITE_BUSY`. [onLockWait] is called on the opening isolate each
  /// time a statement finds such a lock held, before it waits; for a lock
  /// the open meets, that is before this factory returns. It runs inside
  /// SQLite's busy handler, mid statement, so it must not use this
  /// authority. If it throws, that statement stops waiting and fails, and
  /// what it threw reaches the caller of this factory or of the operation
  /// that met the lock, in place of `SQLITE_BUSY`.
  factory ScopeAuthority.file(
    String path, {
    required String scope,
    Duration lockTimeout = const Duration(seconds: 10),
    void Function()? onLockWait,
    DateTime Function()? clock,
    Duration receiptRetention = const Duration(days: 7),
    Duration snapshotLifetime = const Duration(minutes: 5),
    Duration liveTailInterval = const Duration(milliseconds: 50),
    int defaultPageItems = 50,
    int maximumPageItems = 200,
    int maximumOperations = 200,
    int backlogBatchGroups = 256,
  }) => ScopeAuthority._(
    SqliteScopeStore.open(
      path,
      scope: scope,
      lockTimeout: lockTimeout,
      onLockWait: onLockWait,
    ),
    clock: clock,
    receiptRetention: receiptRetention,
    snapshotLifetime: snapshotLifetime,
    liveTailInterval: liveTailInterval,
    defaultPageItems: defaultPageItems,
    maximumPageItems: maximumPageItems,
    maximumOperations: maximumOperations,
    backlogBatchGroups: backlogBatchGroups,
  );

  /// A Scope held in an in-memory database that ends with [close].
  factory ScopeAuthority.memory({
    required String scope,
    DateTime Function()? clock,
    Duration receiptRetention = const Duration(days: 7),
    Duration snapshotLifetime = const Duration(minutes: 5),
    int defaultPageItems = 50,
    int maximumPageItems = 200,
    int maximumOperations = 200,
    int backlogBatchGroups = 256,
  }) => ScopeAuthority._(
    SqliteScopeStore.inMemory(scope: scope),
    clock: clock,
    receiptRetention: receiptRetention,
    snapshotLifetime: snapshotLifetime,
    liveTailInterval: Duration.zero,
    defaultPageItems: defaultPageItems,
    maximumPageItems: maximumPageItems,
    maximumOperations: maximumOperations,
    backlogBatchGroups: backlogBatchGroups,
  );

  ScopeAuthority._(
    this._store, {
    required DateTime Function()? clock,
    required this.receiptRetention,
    required this.snapshotLifetime,
    required this._liveTailInterval,
    required this.defaultPageItems,
    required this.maximumPageItems,
    required this.maximumOperations,
    required this.backlogBatchGroups,
  }) : _clock = clock ?? DateTime.now {
    try {
      if (backlogBatchGroups < 1) {
        throw ArgumentError.value(
          backlogBatchGroups,
          'backlogBatchGroups',
          'is not positive',
        );
      }
      // Every result entry must fit a receipt's inline `results`, because
      // this authority never pages a receipt. One operation yields one entry.
      if (maximumOperations > maximumPageItems) {
        throw ArgumentError.value(
          maximumOperations,
          'maximumOperations',
          'exceeds maximumPageItems ($maximumPageItems)',
        );
      }
      _published = _store.read(() {
        _refreshTypes();
        _servedEpoch = _store.epoch;
        return _store.head();
      });
    } catch (_) {
      _store.close();
      rethrow;
    }
  }

  final SqliteScopeStore _store;
  final DateTime Function() _clock;
  final Duration _liveTailInterval;

  /// The current Scope epoch: stable across reopen, replaced by
  /// [reinitialize] through any authority open on the same file.
  @override
  String get epoch => _store.read(() => _store.epoch);

  /// The epoch this instance last served from. When a transaction finds the
  /// store on another epoch, another connection reinitialized the Scope.
  late String _servedEpoch;

  /// Ends this instance's live [watch] streams with `cursor-expired` and
  /// drops its snapshot manifests when the store's epoch has moved since
  /// this instance last served; call after a transaction.
  void _noticeEpoch() {
    if (_store.epoch == _servedEpoch) return;
    _servedEpoch = _store.epoch;
    _manifests.clear();
    _published = _store.read(_store.head);
    _commits.addError(_cursorExpired());
  }

  bool _closed = false;

  /// Ends every live [watch] stream (each is done after the groups already
  /// delivered to it) and closes the database.
  @override
  @effect
  void close() {
    if (_closed) return;
    _closed = true;
    _stopTail();
    for (final end in [..._watchers]) {
      end();
    }
    unawaited(_commits.close());
    _store.close();
  }

  /// How long a receipt's detail, and a failed receipt at all, is retained.
  final Duration receiptRetention;

  /// How long a snapshot handle stays continuable.
  final Duration snapshotLifetime;
  final int defaultPageItems;
  final int maximumPageItems;

  /// The most operations one transaction may carry.
  final int maximumOperations;

  /// The largest request body, in bytes, that [authorityHandler] accepts:
  /// 1 MiB. A longer body is refused as `request-too-large`.
  ///
  /// Every authority advertises it in its discovery as
  /// `limits.request.bodyBytes`. A request made in process has no body and
  /// is never refused for its size, but the bound is advertised there too,
  /// so a client sizes what it sends by one number whichever way it reaches
  /// the Scope.
  static const maximumBodyBytes = 1 << 20;

  /// The most change groups one read transaction of a [watch] backlog
  /// carries. A longer backlog takes several transactions, each checked
  /// against the epoch the stream started in.
  final int backlogBatchGroups;

  /// The Types pinned in the store, as of this instance's latest
  /// transaction. It is read-only: Types are installed by [installType].
  @override
  AuthorityTypeRegistry get typeRegistry => _types;
  late AuthorityTypeRegistry _types;

  /// Brings [typeRegistry] up to the Types pinned in the store, including
  /// those another connection installed; call inside a transaction. Pinned
  /// rows are never changed or removed, so an equal count is an equal set.
  AuthorityTypeRegistry _refreshTypes() {
    if (_store.typeCount() != _typesLoaded) {
      final rows = _store.installedTypes();
      _types = pinnedTypes(rows);
      _typesLoaded = rows.length;
    }
    return _types;
  }

  int _typesLoaded = -1;

  /// Every committed group, published to the live [watch] streams in log
  /// order. It runs a tail of the store only while it has listeners.
  late final StreamController<JsonMap> _commits = StreamController.broadcast(
    sync: true,
    onListen: _startTail,
    onCancel: _stopTail,
  );

  /// The sequence of the last group published on [_commits] in the served
  /// epoch.
  late int _published;

  /// Ends one live [watch] stream, for [close].
  final Set<void Function()> _watchers = {};

  Timer? _tail;
  int? _seenVersion;

  void _startTail() {
    if (!_store.shared || _closed) return;
    _seenVersion = null;
    _tail = Timer.periodic(_liveTailInterval, (_) => _pollTail());
  }

  void _stopTail() {
    _tail?.cancel();
    _tail = null;
  }

  /// Publishes whatever other connections committed since the last check,
  /// or ends the live streams when they reinitialized the Scope. A store
  /// that cannot be read ends them with its error rather than leaving them
  /// silently stale.
  void _pollTail() {
    try {
      final version = _store.dataVersion();
      if (version == _seenVersion) return;
      _seenVersion = version;
      _publishCommitted();
    } on Object catch (error) {
      _commits.addError(error);
    }
  }

  /// Publishes [group], which this instance just committed, after any group
  /// another connection committed before it.
  void _publish(JsonMap group) {
    final seq = _seqOf(group);
    if (seq == _published + 1 || !_commits.hasListener) {
      _published = seq;
      _commits.add(group);
    } else {
      _publishCommitted();
    }
  }

  /// Publishes every group in the store after [_published], in order.
  void _publishCommitted() {
    final groups = _store.read(
      () =>
          _store.epoch == _servedEpoch ? _store.groupsAfter(_published) : null,
    );
    if (groups == null) return _noticeEpoch();
    for (final group in groups) {
      _published = _seqOf(group);
      _commits.add(group);
    }
  }

  @override
  ScopeAddress get address => _store.address;

  /// Targets in the Operation Directory that this authority does not serve:
  /// aliases, `sequence` and the set mutations. They stay listed so the
  /// directory keeps the Transactional shape, and every request to them is
  /// refused with `forbidden` before admission.
  static const unservedTargets = {
    'putAlias': 'put-alias',
    'deleteAlias': 'delete-alias',
    'sequence': 'sequence',
    'updateWhere': 'update-where',
    'deleteWhere': 'delete-where',
  };

  static final _keyPattern = RegExp(r'^[A-Za-z0-9_-]{1,256}$');

  /// Installs a Type (an administrative act outside BDP): validates the
  /// descriptor and schema against the Types pinned in the store, pins them
  /// there, and only once that commits makes the Type available to
  /// mutations. Installing content identical to a Type's current revision
  /// is a no-op and answers null; other content at a pinned Type ID, whichever
  /// connection pinned it, pins a new revision beside the earlier ones. The
  /// new revision is the current one, which every connection validates
  /// writes against; records written under an earlier one stay as written.
  /// A malformed install throws [ArgumentError] and pins nothing. Answers
  /// the revision it pinned. The schema is copied: later changes to
  /// [schema] change nothing. It commits to the store, so it is an
  /// `@effect`.
  @effect
  AuthorityTypeRevision? installType(JsonMap descriptor, {JsonMap? schema}) {
    final parsed = AuthorityTypeDescriptor.fromJson(descriptor);
    final frozen = schema == null ? null : freezeJson(schema) as JsonMap;
    final installed = _store.write(() {
      final pinned = _refreshTypes();
      final staged = withType(pinned, parsed, frozen);
      if (staged != null) {
        _store.putType(
          parsed.toJson(),
          frozen,
          revision: pinned[parsed.id] != null,
        );
      }
      return staged;
    });
    if (installed == null) return null;
    _types = installed;
    _typesLoaded += 1;
    return installed.revisionsOf(parsed.id).last;
  }

  /// Discards current state and receipts and starts a new epoch. Every
  /// idempotency key, receipt, checkpoint and snapshot of the old epoch is
  /// unbound; live [watch] streams end with `cursor-expired`. The old
  /// epoch's change groups stay in the database: the log is never pruned.
  @effect
  void reinitialize() {
    _store.reinitialize();
    _noticeEpoch();
  }

  // Mutations.

  /// Submits [body] to the operation [target] (`batch` or a singleton target
  /// name such as `create-bead`) as one Mutation Transaction.
  ///
  /// Throws [AuthorityProblem] for a direct refusal (malformed request,
  /// conflicting key, limit). Every admitted request returns its receipt,
  /// `completed` or `failed`. [inadmissibleNumbers] maps the body pointer
  /// of each number literal that does not round-trip through binary64 to
  /// the exact decimal value it denotes; such a literal fails its operation,
  /// and the value keeps the request's identity exact. With
  /// [admitNew] false, a request whose key is unknown throws [AuthorityNotAdmitted]
  /// instead of executing, while a retained duplicate still returns its
  /// receipt.
  @override
  @effect
  AuthorityReceipt mutate(
    String target,
    Object? body, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
    Map<String, String> inadmissibleNumbers = const {},
    bool admitNew = true,
  }) {
    if (!_keyPattern.hasMatch(idempotencyKey)) {
      throw AuthorityProblem(
        'malformed-request',
        title: 'Idempotency-Key is not a valid key',
      );
    }
    if (unservedTargets.containsValue(target)) throw _unserved();
    final List<Operation> operations;
    if (target == 'batch') {
      operations = parseBatch(body, address);
    } else {
      final kind = OperationKind.byTarget(target);
      if (kind == null) {
        throw AuthorityProblem(
          'resource-not-found',
          title: 'No such operation target',
        );
      }
      operations = [parseSingleton(kind, body, address)];
    }
    final fingerprint = semanticFingerprint(
      operations,
      inadmissibleNumbers: inadmissibleNumbers,
    );
    final now = _clock().toUtc();
    final (receipt, group) = _store.write(() {
      _refreshTypes();
      final retained = _store.receiptByKey(principal, idempotencyKey);
      if (retained != null) {
        if (retained.status == 'failed' && now.isAfter(retained.expiresAt)) {
          _store.forgetReceipt(retained.token);
        } else if (retained.fingerprint != fingerprint) {
          throw AuthorityProblem(
            'idempotency-conflict',
            title: 'Idempotency key is bound to a different request',
            instance: _receiptUrl(retained.token),
          );
        } else {
          return (_project(retained, now)!, null);
        }
      }
      if (operations.length > maximumOperations) {
        throw AuthorityProblem(
          'limit-exceeded',
          title: 'Too many operations',
          limit: 'transaction.operations',
        );
      }
      if (!admitNew) throw const AuthorityNotAdmitted();
      return _execute(
        operations,
        fingerprint,
        idempotencyKey,
        principal,
        now,
        inadmissibleNumbers,
      );
    });
    _noticeEpoch();
    if (group != null) _publish(group);
    return AuthorityReceipt(receipt, position: _store.position(_store.head()));
  }

  (JsonMap, JsonMap?) _execute(
    List<Operation> operations,
    String fingerprint,
    String key,
    String principal,
    DateTime now,
    Map<String, String> inadmissible,
  ) {
    final number = _store.nextTransaction();
    final head = _store.head();
    final token = '${_store.epoch}-r$number';
    final staged = StagedTransaction(
      store: _store,
      types: typeRegistry,
      seq: head + 1,
      transaction: 't$number',
      time: instant(now),
      inadmissibleNumbers: inadmissible,
    );
    final expiresAt = now.add(receiptRetention);
    final core = <String, Object?>{
      'id': _receiptUrl(token),
      'status': 'completed',
      'detail': 'available',
      'idempotencyKey': key,
      'scopeEpoch': _store.epoch,
      'authorizationView': authorizationView,
      'transaction': 't$number',
      'requiredPosition': _store.position(head),
    };
    JsonMap receipt;
    JsonMap? group;
    try {
      staged.run(operations);
      if (staged.events.isNotEmpty) {
        group = staged.commit();
        core['requiredPosition'] = _store.position(head + 1);
        core['effectPosition'] = _store.position(head + 1);
      }
      receipt = {
        ...core,
        'results': staged.results,
        'next': null,
        'expiresAt': instant(expiresAt),
      };
    } on OperationFailure catch (failure) {
      receipt = {
        ...core,
        'status': 'failed',
        'problem': failure.toJson(),
        'expiresAt': instant(expiresAt),
      };
    }
    _store.putReceipt(
      principal: principal,
      key: key,
      receipt: StoredReceipt(
        token: token,
        principal: principal,
        fingerprint: fingerprint,
        status: receipt['status']! as String,
        expiresAt: expiresAt,
        receipt: receipt,
      ),
    );
    return (receipt, group);
  }

  String _receiptUrl(String token) => '${address.receipts}$token';

  /// The receipt as served at [now]: its detail until it expires, then the
  /// compact `expired` form for a completed receipt and nothing (forgotten)
  /// for a failed one.
  JsonMap? _project(StoredReceipt stored, DateTime now) {
    final receipt = stored.receipt;
    if (!now.isAfter(stored.expiresAt)) return receipt;
    if (stored.status == 'failed') return null;
    return {
      for (final key in [
        'id', 'status', 'idempotencyKey', 'scopeEpoch', 'authorizationView', //
        'transaction', 'requiredPosition', 'effectPosition',
      ])
        if (receipt.containsKey(key)) key: receipt[key],
      'detail': 'expired',
      'allocated': [
        for (final entry in (receipt['results']! as List).cast<JsonMap>())
          if (entry['outcome'] == 'created')
            {
              'operationIndex': entry['operationIndex'],
              'operationName': ?entry['operationName'],
              'id': (entry['resource']! as JsonMap)['id'],
              'type': (entry['resource']! as JsonMap)['type'],
            },
      ],
    };
  }

  // Reads.

  AuthorityRead _read(JsonMap Function(int head) body) {
    final read = _store.read(() {
      _refreshTypes();
      final head = _store.head();
      return AuthorityRead(
        body(head),
        epoch: _store.epoch,
        position: _store.position(head),
      );
    });
    _noticeEpoch();
    return read;
  }

  /// The Scope context as it stands, with an empty body: what a response
  /// that carries no representation (a problem, a `406`) reports.
  @override
  AuthorityRead observe() => _read((_) => const {});

  /// The Transactional discovery document. `aliases` is advertised because
  /// the profile requires it; no alias ever exists, so every alias URL
  /// resolves to `resource-not-found`.
  @override
  AuthorityRead discoveryDocument() => _read(
    (head) => {
      'bdpVersion': '0',
      'profile': 'transactional',
      'scope': address.scope,
      'scopeEpoch': _store.epoch,
      'authorizationView': authorizationView,
      'headPosition': _store.position(head),
      'minimumReplayPosition': _store.position(0),
      'beads': address.beads,
      'links': address.links,
      'types': address.types,
      'operations': address.operations,
      'aliases': address.aliases,
      'receipts': address.receipts,
      'snapshot': address.snapshot,
      'changes': address.changes,
      'events': address.events,
      'order': 'canonical-uri',
      'limits': {
        'page': {
          'defaultItems': defaultPageItems,
          'maximumItems': maximumPageItems,
        },
        'request': {'bodyBytes': maximumBodyBytes},
        'transaction': {'operations': maximumOperations},
        'retention': {
          'receipt': 'PT${receiptRetention.inSeconds}S',
          'maximumSnapshotLifetime': 'PT${snapshotLifetime.inSeconds}S',
        },
      },
    },
  );

  /// The twelve-entry Transactional Operation Directory. The
  /// [unservedTargets] are listed and refuse every request.
  @override
  AuthorityRead operationDirectory() => _read(
    (_) => {
      for (final kind in OperationKind.values) kind.name: kind.target,
      ...unservedTargets,
      'batch': 'batch',
    },
  );

  /// A page of the `types/` inventory in canonical-uri order. A cursor
  /// continues only in the epoch that issued it and while the pinned Types
  /// are unchanged; otherwise it fails `cursor-expired`. The Types survive a
  /// reinitialization; their cursors, like every other, do not.
  @override
  AuthorityRead typeInventory({int? limit, String? cursor}) => _read((_) {
    final size = _pageSize(limit);
    final pinned = typeRegistry.all.fold(
      0,
      (n, t) => n + typeRegistry.revisionsOf(t.id).length,
    );
    final inventory = _typesCursorScope(_store.epoch);
    var after = '';
    if (cursor != null) {
      final (bound, lastId) = _decodeCursor(cursor, inventory);
      if (bound != '$pinned') throw _cursorExpired();
      after = lastId;
    }
    final ids = [
      for (final t in typeRegistry.all)
        if (t.id.compareTo(after) > 0) t.id,
    ]..sort();
    final items = [for (final id in ids.take(size)) typeRegistry[id]!.summary];
    return {
      'items': items,
      'next': ids.length > size
          ? Uri.parse(address.types)
                .replace(
                  queryParameters: {
                    if (limit != null) 'limit': '$limit',
                    'cursor': _encodeCursor(
                      inventory,
                      '$pinned',
                      ids[size - 1],
                    ),
                  },
                )
                .toString()
          : null,
    };
  });

  /// The Type Descriptor of the installed Type [id], read in a transaction
  /// that observes Types pinned by any connection.
  @override
  AuthorityRead typeDescriptor(String id) =>
      _read((_) => (typeRegistry[id] ?? (throw _notFound())).toJson());

  /// The canonical record of the Bead or Link at [reference].
  @override
  AuthorityRead resource(String reference) =>
      _read((_) => _resource(reference));

  JsonMap _resource(String reference) {
    final spelling = address.classify(reference);
    final record = switch (spelling) {
      InScopeSpelling(:final url, kind: final AuthorityResourceKind kind) =>
        _store.resource(kind, url),
      _ => null,
    };
    return record ?? (throw _notFound());
  }

  /// A page of [kind]'s collection in canonical-uri order under the
  /// structural predicates. A cursor continues only while the Scope epoch
  /// and head are unchanged; otherwise it fails `cursor-expired` rather than
  /// restarting against newer state.
  @override
  AuthorityRead collection(
    AuthorityResourceKind kind, {
    String? type,
    String? conformsTo,
    String? source,
    String? target,
    String? endpoint,
    int? limit,
    String? cursor,
  }) => _read((head) {
    Set<String>? allowed;
    if (type != null) allowed = {type};
    if (conformsTo != null) {
      final conforming = typeRegistry.conformingTo(conformsTo);
      allowed = allowed == null ? conforming : allowed.intersection(conforming);
    }
    return _page(
      kind,
      head: head,
      base: kind == AuthorityResourceKind.bead ? address.beads : address.links,
      parameters: {
        'type': ?type,
        'conformsTo': ?conformsTo,
        'source': ?source,
        'target': ?target,
        'endpoint': ?endpoint,
        if (limit != null) 'limit': '$limit',
      },
      types: allowed,
      source: source == null ? null : _endpointParameter(source),
      target: target == null ? null : _endpointParameter(target),
      endpoint: endpoint == null ? null : _endpointParameter(endpoint),
      limit: limit,
      cursor: cursor,
    );
  });

  /// The incident Link view of the Bead at [reference].
  @override
  AuthorityRead incidentLinkPage(
    String reference, {
    String direction = 'both',
    int? limit,
    String? cursor,
  }) => _read((head) {
    final id = _resource(reference)['id']! as String;
    if (!id.startsWith(address.beads)) {
      throw AuthorityProblem(
        'invalid-parameter',
        title: 'view=links is a Bead view',
      );
    }
    return _page(
      AuthorityResourceKind.link,
      head: head,
      base: id,
      parameters: {
        'view': 'links',
        'direction': direction,
        if (limit != null) 'limit': '$limit',
      },
      source: direction == 'outbound' ? id : null,
      target: direction == 'inbound' ? id : null,
      endpoint: direction == 'both' ? id : null,
      limit: limit,
      cursor: cursor,
    );
  });

  String _endpointParameter(String value) => switch (address.classify(value)) {
    InScopeSpelling(:final url) => url,
    ExternalSpelling(:final uri) => uri,
    InvalidSpelling() => throw AuthorityProblem(
      'invalid-parameter',
      title: 'Invalid reference parameter',
    ),
  };

  JsonMap _page(
    AuthorityResourceKind kind, {
    required int head,
    required String base,
    required Map<String, String> parameters,
    Set<String>? types,
    String? source,
    String? target,
    String? endpoint,
    int? limit,
    String? cursor,
  }) {
    final size = _pageSize(limit);
    var after = '';
    if (cursor != null) {
      final (bound, lastId) = _decodeCursor(cursor, _store.epoch);
      if (bound != '$head') throw _cursorExpired();
      after = lastId;
    }
    final rows = types != null && types.isEmpty
        ? <JsonMap>[]
        : _store.page(
            kind,
            afterId: after,
            limit: size + 1,
            types: types,
            source: source,
            target: target,
            endpoint: endpoint,
          );
    final more = rows.length > size;
    final items = more ? rows.sublist(0, size) : rows;
    return {
      'items': items,
      'next': more
          ? Uri.parse(base)
                .replace(
                  queryParameters: {
                    ...parameters,
                    'cursor': _encodeCursor(
                      _store.epoch,
                      '$head',
                      items.last['id']! as String,
                    ),
                  },
                )
                .toString()
          : null,
    };
  }

  int _pageSize(int? limit) {
    if (limit == null) return defaultPageItems;
    if (limit < 1) {
      throw AuthorityProblem(
        'invalid-parameter',
        title: 'limit is a positive integer',
      );
    }
    return limit > maximumPageItems ? maximumPageItems : limit;
  }

  /// The cursor scope of the `types/` inventory in [epoch]: distinct from
  /// every Resource collection's, which is the epoch itself.
  static String _typesCursorScope(String epoch) => 'types@$epoch';

  /// A collection cursor: the [scope] it belongs to (the epoch, or the
  /// epoch's Type inventory), the [bound] state it continues (the head, or
  /// the pinned Type count) and the last canonical id served.
  static String _encodeCursor(String scope, String bound, String lastId) =>
      base64Url
          .encode(utf8.encode('$scope\n$bound\n$lastId'))
          .replaceAll('=', '');

  /// The bound and last id of a cursor issued in [scope]; a cursor from
  /// another epoch or collection is `cursor-expired`.
  static (String, String) _decodeCursor(String cursor, String scope) {
    final List<String> parts;
    try {
      final text = utf8.decode(base64Url.decode(base64Url.normalize(cursor)));
      parts = text.split('\n');
    } on FormatException {
      throw AuthorityProblem('invalid-parameter', title: 'Invalid cursor');
    }
    if (parts.length < 3) {
      throw AuthorityProblem('invalid-parameter', title: 'Invalid cursor');
    }
    if (parts[0] != scope) throw _cursorExpired();
    return (parts[1], parts.sublist(2).join('\n'));
  }

  /// The receipt at [token] for [principal]; another principal's, an
  /// unknown, a forgotten or a prior epoch's receipt is `resource-not-found`.
  @override
  AuthorityRead receipt(
    String token, {
    String principal = authorityAnonymousPrincipal,
  }) => _read((_) {
    final stored = _store.receiptByToken(token);
    if (stored == null || stored.principal != principal) throw _notFound();
    return _project(stored, _clock().toUtc()) ?? (throw _notFound());
  });

  // Replication.

  /// A finite changefeed page after [after] (a checkpoint, or `genesis`),
  /// or, with [startNow], an empty page anchored at the current head.
  /// Supplying neither, or both, is `invalid-parameter`.
  @override
  AuthorityRead changePage({String? after, bool startNow = false, int? limit}) {
    if ((after == null) != startNow) {
      throw AuthorityProblem(
        'invalid-parameter',
        title: 'Supply exactly one of after and start=now',
      );
    }
    return _read((head) {
      final from = startNow
          ? head
          : (_store.checkpointSeq(after!) ?? (throw _cursorExpired()));
      final size = _pageSize(limit);
      final groups = startNow
          ? <JsonMap>[]
          : _store.groupsAfter(from, limit: size + 1);
      final more = groups.length > size;
      final page = more ? groups.sublist(0, size) : groups;
      return {
        'scope': address.scope,
        'scopeEpoch': _store.epoch,
        'authorizationView': authorizationView,
        'after': startNow ? _store.checkpoint(head) : after,
        'observedHeadPosition': _store.position(head),
        'groups': page,
        'next': more
            ? '${address.changes}?after=${page.last['checkpoint']}'
            : null,
      };
    });
  }

  /// Every committed change group after [after] (a checkpoint or `genesis`;
  /// null means from now), then each group committed to the Scope, live.
  ///
  /// The backlog is read in transactions of at most [backlogBatchGroups]
  /// groups, yielding to the event loop between them, and every one of those
  /// transactions checks that the Scope is still in the epoch the stream
  /// started in. The backlog and the live tail are joined without a gap or
  /// duplicate. Past the backlog, groups this instance commits arrive at
  /// once, after any group another connection committed before them; groups
  /// other connections commit arrive within the file authority's live-tail
  /// interval. The stream errors with
  /// `cursor-expired` for a checkpoint that is not this epoch's and when any
  /// connection reinitializes the Scope, during the backlog or after it, and
  /// is done when this authority closes.
  @override
  @effect
  Stream<JsonMap> watch({String? after}) {
    StreamSubscription<JsonMap>? live;
    late final StreamController<JsonMap> out;
    void end() {
      _watchers.remove(end);
      unawaited(live?.cancel());
      if (!out.isClosed) unawaited(out.close());
    }

    void fail(Object error) {
      if (!out.isClosed) out.addError(error);
      end();
    }

    /// Delivers the groups after [start] in [epoch], then joins the live
    /// tail. Each batch is its own read transaction.
    Future<void> deliver(int start, String epoch) async {
      var last = start;
      while (true) {
        if (_closed || out.isClosed) return;
        final List<JsonMap>? batch;
        try {
          batch = _store.read(
            () => _store.epoch == epoch
                ? _store.groupsAfter(last, limit: backlogBatchGroups)
                : null,
          );
        } on Object catch (error) {
          return fail(error);
        }
        if (batch == null) {
          fail(_cursorExpired());
          return _noticeEpoch();
        }
        if (batch.isEmpty) break;
        for (final group in batch) {
          out.add(group);
        }
        last = _seqOf(batch.last);
        await Future<void>.delayed(Duration.zero);
      }
      if (!_commits.hasListener) _published = last;
      live = _commits.stream.listen((group) {
        final seq = _seqOf(group);
        if (seq > last && !out.isClosed) {
          out.add(group);
          last = seq;
        }
      }, onError: fail);
    }

    out = StreamController<JsonMap>(
      onListen: () {
        if (_closed) return end();
        final (int?, String) start;
        try {
          start = _store.read(
            () => (
              after == null ? _store.head() : _store.checkpointSeq(after),
              _store.epoch,
            ),
          );
          _noticeEpoch();
        } on Object catch (error) {
          return fail(error);
        }
        final (seq, epoch) = start;
        if (seq == null) return fail(_cursorExpired());
        _watchers.add(end);
        unawaited(deliver(seq, epoch));
      },
      onCancel: end,
    );
    return out.stream;
  }

  static int _seqOf(JsonMap group) =>
      int.parse((group['position']! as String).substring(1));

  /// Manifests served by [snapshotDocument] while their handles live, so a refetch
  /// costs a lookup. A handle that outlives this instance (a restart) is
  /// reconstructed by folding the log up to its position.
  final Map<String, JsonMap> _manifests = {};

  /// A snapshot manifest at the current head with both streams inline. Its
  /// handle is retained for [snapshotLifetime].
  @override
  @effect
  AuthorityRead snapshotDocument() => _read((head) {
    final now = _clock().toUtc();
    _manifests.removeWhere(
      (_, manifest) =>
          now.isAfter(DateTime.parse(manifest['expiresAt']! as String)),
    );
    final expires = now.add(snapshotLifetime);
    final token = '${_store.epoch}-$head-${expires.millisecondsSinceEpoch}';
    return _manifests[token] = _manifest(
      token,
      head,
      expires,
      _store.page(AuthorityResourceKind.bead, afterId: '', limit: -1),
      _store.page(AuthorityResourceKind.link, afterId: '', limit: -1),
    );
  });

  /// Refetches the manifest a [snapshotDocument] handle names, with the same
  /// anchor, checkpoint and expiry.
  @override
  AuthorityRead snapshotHandle(String token) => _read((head) {
    final parts = token.split('-');
    final seq = parts.length == 3 ? int.tryParse(parts[1]) : null;
    final millis = parts.length == 3 ? int.tryParse(parts[2]) : null;
    if (seq == null || millis == null || seq > head) throw _notFound();
    final expires = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    if (parts[0] != _store.epoch || _clock().toUtc().isAfter(expires)) {
      throw _cursorExpired();
    }
    final retained = _manifests[token];
    if (retained != null) return retained;
    final beads = SplayTreeMap<String, JsonMap>();
    final links = SplayTreeMap<String, JsonMap>();
    for (final group in _store.groupsAfter(0, limit: seq)) {
      for (final change in (group['changes']! as List).cast<JsonMap>()) {
        final into = change['resourceKind'] == 'bead' ? beads : links;
        final record = change['resource']! as JsonMap;
        if (change['operation'] == 'upsert') {
          into[record['id']! as String] = record;
        } else {
          into.remove(record['id']);
        }
      }
    }
    return _manifest(
      token,
      seq,
      expires,
      beads.values.toList(),
      links.values.toList(),
    );
  });

  JsonMap _manifest(
    String token,
    int seq,
    DateTime expires,
    List<JsonMap> beads,
    List<JsonMap> links,
  ) => {
    'id': '${address.snapshot}?snapshot=$token',
    'scope': address.scope,
    'scopeEpoch': _store.epoch,
    'authorizationView': authorizationView,
    'scopePosition': _store.position(seq),
    'checkpoint': _store.checkpoint(seq),
    'expiresAt': instant(expires),
    'erasures': <Object?>[],
    'beads': {'items': beads, 'next': null},
    'links': {'items': links, 'next': null},
  };

  // Event Sources.

  /// A finite page of an Event Source: the Scope's (`events/`) when
  /// [resource] is null, else the Bead's or Link's own. [after] is an
  /// exclusive Event ID; null starts at the earliest Event.
  @override
  AuthorityRead events({String? resource, String? after, int? limit}) => _read((
    head,
  ) {
    final size = _pageSize(limit);
    var (seq, ordinal) = (0, -1);
    if (after != null) {
      final parts = after.split('_');
      final s = parts.length == 3 ? int.tryParse(parts[1]) : null;
      final o = parts.length == 3 ? int.tryParse(parts[2]) : null;
      if (s == null || o == null) {
        throw AuthorityProblem(
          'invalid-parameter',
          title: 'Invalid Event cursor',
        );
      }
      if (parts[0] != _store.epoch || s > head) throw _cursorExpired();
      (seq, ordinal) = (s, o);
    }
    final String source;
    final List<JsonMap> found = [];
    if (resource == null) {
      source = address.events;
      var cursor = seq - 1;
      while (found.length <= size) {
        final groups = _store.groupsAfter(cursor < 0 ? 0 : cursor, limit: 64);
        if (groups.isEmpty) break;
        for (final group in groups) {
          final groupSeq = _seqOf(group);
          for (final event in (group['events']! as List).cast<JsonMap>()) {
            if (groupSeq > seq || (event['ordinal']! as int) > ordinal) {
              found.add(event);
            }
          }
          cursor = groupSeq;
        }
      }
    } else {
      final id = switch (address.classify(resource)) {
        InScopeSpelling(:final url, kind: AuthorityResourceKind _)
            when _store.everCommitted(url) =>
          url,
        _ => throw _notFound(),
      };
      source = '$id?view=events';
      final cache = <int, List<JsonMap>>{};
      for (final (s, o) in _store.sourceEvents(id, seq, ordinal, size + 1)) {
        final event = cache.putIfAbsent(s, () => _store.groupEvents(s))[o];
        found.add({...event, 'source': source});
      }
    }
    final more = found.length > size;
    final page = more ? found.sublist(0, size) : found;
    return {
      'source': source,
      'events': page,
      'next': more
          ? Uri.parse(source)
                .replace(
                  queryParameters: {
                    ...Uri.parse(source).queryParameters,
                    'after': page.last['id']! as String,
                  },
                )
                .toString()
          : null,
    };
  });

  // Consistency.

  /// Enforces a minimum-position read context against [observed], the
  /// position a read already served from: a foreign epoch is
  /// `cursor-expired`, a foreign view `foreign-view`, and a position past
  /// [observed] `catch-up-timeout` (a single authority has nothing to wait
  /// for). Callers decide non-disclosure first, so a hidden target never
  /// reaches this check.
  @override
  void requireMinimum({
    String? epoch,
    String? view,
    required String position,
    required AuthorityRead observed,
  }) {
    if (epoch != null && epoch != observed.epoch) throw _cursorExpired();
    if (view != null && view != authorizationView) {
      throw AuthorityProblem(
        'foreign-view',
        title: 'Position belongs to another view',
      );
    }
    final seq = _positionSeq(position);
    if (seq == null) throw _cursorExpired();
    if (seq > _positionSeq(observed.position)!) {
      throw AuthorityProblem('catch-up-timeout', title: 'Position not reached');
    }
  }

  static int? _positionSeq(String position) =>
      position.startsWith('p') ? int.tryParse(position.substring(1)) : null;

  static AuthorityProblem _notFound() =>
      AuthorityProblem('resource-not-found', title: 'No such Resource');

  static AuthorityProblem _unserved() => AuthorityProblem(
    'forbidden',
    title: 'Operation is not served by this authority',
  );

  static AuthorityProblem _cursorExpired() =>
      AuthorityProblem('cursor-expired', title: 'Cursor is not continuable');
}

/// An RFC 3339 instant with uppercase `T` and `Z`, to the second.
String instant(DateTime time) =>
    time.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
