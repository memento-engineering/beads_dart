import 'dart:convert';
import 'dart:io' show sleep;
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'identity.dart';
import 'json_text.dart';

/// The one Authorization View this authority serves: one principal class,
/// one constant projection.
const authorizationView = 'v1';

/// The reserved checkpoint that asks for the current epoch's complete
/// history. It names no epoch, so the authority never issues it: an empty
/// epoch's own checkpoint is `<epoch>_0`.
const genesisCheckpoint = 'genesis';

/// One retained Mutation Receipt row.
final class StoredReceipt {
  const StoredReceipt({
    required this.token,
    required this.principal,
    required this.fingerprint,
    required this.status,
    required this.expiresAt,
    required this.receipt,
  });

  final String token;
  final String principal;
  final String fingerprint;
  final String status;
  final DateTime expiresAt;

  /// The terminal receipt representation with its detail available.
  final JsonMap receipt;
}

/// One SQLite database holding a Scope: current state, the change-group log,
/// mutation receipts, installed Types, and the Scope epoch.
///
/// Current state is written only by [appendGroup], which applies a group's
/// changes in the same transaction that appends the group, so live state is
/// always the fold of the log. The log is never pruned, not even by
/// [reinitialize]: every epoch's groups stay in the database, keyed by
/// epoch. Writes take SQLite's write lock up front (`BEGIN IMMEDIATE`), so
/// several connections to one file still produce one total order.
///
/// This type is internal to the authority library; only a `ScopeAuthority`
/// writes through it.
final class SqliteScopeStore {
  SqliteScopeStore._(
    this._db,
    this.address,
    this._lockWaiter, {
    required this.shared,
  }) {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute(_schema);
    _write(() {
      final recorded = _meta('scope');
      if (recorded == null) {
        _setMeta('scope', address.scope);
        _setMeta('epoch', _epoch = _newEpoch());
        _setMeta('transactions', '0');
      } else if (recorded != address.scope) {
        throw StateError('store holds $recorded, not ${address.scope}');
      }
    });
  }

  /// Opens (creating if needed) the Scope store at [path] in WAL mode. A
  /// failure to initialize closes the connection it opened.
  ///
  /// Every statement on the connection, from the first, waits up to
  /// [lockTimeout] for a lock another connection holds before it fails with
  /// `SQLITE_BUSY`. [onLockWait] is called on this isolate each time a
  /// statement finds such a lock held, before it waits, from inside SQLite's
  /// busy handler: it must not use this store, whose connection is mid
  /// statement. If it throws, the statement stops waiting and fails, and
  /// what it threw reaches the caller of the open, [write], [read],
  /// [reinitialize] or [dataVersion] in place of `SQLITE_BUSY`.
  factory SqliteScopeStore.open(
    String path, {
    required String scope,
    Duration lockTimeout = const Duration(seconds: 10),
    void Function()? onLockWait,
  }) {
    final address = ScopeAddress(scope);
    final db = sqlite3.open(path);
    final waiter = _LockWaiter(lockTimeout, onLockWait);
    try {
      // Switching to WAL takes a lock; several authorities opening one file
      // at once wait for it rather than fail with SQLITE_BUSY.
      db.busyHandler = waiter.call;
      return waiter.guard(() {
        db.execute('PRAGMA journal_mode = WAL');
        return SqliteScopeStore._(db, address, waiter, shared: true);
      });
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  /// An in-memory Scope store, for tests and throwaway stations. No other
  /// connection can reach it.
  factory SqliteScopeStore.inMemory({required String scope}) {
    final address = ScopeAddress(scope);
    final db = sqlite3.openInMemory();
    try {
      return SqliteScopeStore._(db, address, null, shared: false);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  final Database _db;

  /// The busy handler of a file store; null for an in-memory one, which no
  /// other connection can lock.
  final _LockWaiter? _lockWaiter;

  /// Runs [body], letting what an `onLockWait` threw while one of its
  /// statements waited reach the caller in place of `SQLITE_BUSY`.
  T _guarded<T>(T Function() body) =>
      _lockWaiter == null ? body() : _lockWaiter.guard(body);

  /// Whether other connections can commit to this database: true for a
  /// file, false for an in-memory store.
  final bool shared;

  /// SQLite's `data_version` for this connection: it changes exactly when
  /// another connection has committed to the database since the last call.
  int dataVersion() => _guarded(
    () => _db.select('PRAGMA data_version').first.values.first! as int,
  );

  /// The canonical Scope URL and its derived addresses.
  final ScopeAddress address;

  late String _epoch;

  /// The Scope epoch as of this connection's latest transaction: stable
  /// across reopen, replaced by [reinitialize] on any connection to the
  /// file. Every [write] and [read] re-reads it first, so a group, receipt
  /// or checkpoint is never stamped with an epoch another connection has
  /// already replaced.
  String get epoch => _epoch;

  /// Closes the database.
  void close() => _db.close();

  /// Destructive reinitialization: discards current state and receipts and
  /// starts a new epoch. The old epoch's change groups and Event Source
  /// index stay in the log, unreachable through the new epoch's
  /// checkpoints. Identity non-reuse survives, so the canonical Scope URL
  /// stays the same logical Scope.
  void reinitialize() => _guarded(
    () => _write(() {
      for (final table in ['beads', 'links', 'receipts']) {
        _db.execute('DELETE FROM $table');
      }
      _setMeta('epoch', _epoch = _newEpoch());
      _setMeta('transactions', '0');
    }),
  );

  static String _newEpoch() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 12; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Runs [body] holding the write lock; commits on return, rolls back on
  /// throw.
  T write<T>(T Function() body) => _guarded(() => _write(body));

  T _write<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _observeEpoch();
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Runs [body] in one read transaction, so every statement observes the
  /// same committed prefix.
  T read<T>(T Function() body) => _guarded(() {
    _db.execute('BEGIN');
    try {
      _observeEpoch();
      return body();
    } finally {
      _db.execute('COMMIT');
    }
  });

  /// Takes the epoch the open transaction sees; absent only before the
  /// first open has recorded one.
  void _observeEpoch() {
    final recorded = _meta('epoch');
    if (recorded != null) _epoch = recorded;
  }

  String? _meta(String key) =>
      _db.select('SELECT value FROM meta WHERE key = ?', [
            key,
          ]).firstOrNull?['value']
          as String?;

  void _setMeta(String key, String value) => _db.execute(
    'INSERT INTO meta (key, value) VALUES (?, ?) '
    'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  /// The sequence number of the last committed group (0 at genesis).
  int head() =>
      _db.select(
            'SELECT coalesce(max(seq), 0) AS head FROM groups WHERE epoch = ?',
            [_epoch],
          ).first['head']
          as int;

  /// Allocates the next transaction number; call inside [write].
  int nextTransaction() {
    final next = int.parse(_meta('transactions')!) + 1;
    _setMeta('transactions', '$next');
    return next;
  }

  /// The live record of [id], or null.
  JsonMap? resource(AuthorityResourceKind kind, String id) {
    final row = _db.select('SELECT record FROM ${_table(kind)} WHERE id = ?', [
      id,
    ]).firstOrNull;
    return row == null ? null : decodeMap(row['record'] as String);
  }

  /// Whether [id] was ever committed in this logical Scope.
  bool everCommitted(String id) =>
      _db.select('SELECT 1 FROM identities WHERE id = ?', [id]).isNotEmpty;

  /// Live Links whose source or target URI is [bead].
  List<String> incidentLinks(String bead) => [
    for (final row in _db.select(
      'SELECT id FROM links WHERE source = ? OR target = ? ORDER BY id',
      [bead, bead],
    ))
      row['id'] as String,
  ];

  static String _table(AuthorityResourceKind kind) =>
      kind == AuthorityResourceKind.bead ? 'beads' : 'links';

  void _put(AuthorityResourceKind kind, JsonMap record) {
    final id = record['id']! as String;
    if (kind == AuthorityResourceKind.bead) {
      _db.execute(
        'INSERT OR REPLACE INTO beads (id, type, revision, record) VALUES (?, ?, ?, ?)',
        [id, record['type'], record['revision'], jsonEncode(record)],
      );
    } else {
      _db.execute(
        'INSERT OR REPLACE INTO links (id, type, revision, source, target, record) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          id,
          record['type'],
          record['revision'],
          referenceUri(record['source']),
          referenceUri(record['target']),
          jsonEncode(record),
        ],
      );
    }
  }

  /// Appends one change group, applies its [changes] to current state, and
  /// writes the Event Source index rows for it; call inside [write].
  ///
  /// [allocated] lists every identity the transaction committed, including
  /// one created and deleted within it, which leaves no change behind but is
  /// never reassigned.
  void appendGroup({
    required int seq,
    required String transaction,
    required List<JsonMap> changes,
    required List<JsonMap> events,
    required Map<int, Set<String>> sources,
    Iterable<String> allocated = const [],
  }) {
    final identities = <String, AuthorityResourceKind>{};
    for (final change in changes) {
      final kind = change['resourceKind'] == 'bead'
          ? AuthorityResourceKind.bead
          : AuthorityResourceKind.link;
      final record = change['resource']! as JsonMap;
      final id = record['id']! as String;
      if (change['operation'] == 'upsert') {
        _put(kind, record);
      } else {
        _db.execute('DELETE FROM ${_table(kind)} WHERE id = ?', [id]);
      }
      identities[id] = kind;
    }
    for (final id in allocated) {
      identities.putIfAbsent(
        id,
        () => address.localId(id).startsWith(AuthorityResourceKind.bead.root)
            ? AuthorityResourceKind.bead
            : AuthorityResourceKind.link,
      );
    }
    for (final MapEntry(key: id, value: kind) in identities.entries) {
      _db.execute('INSERT OR IGNORE INTO identities (id, kind) VALUES (?, ?)', [
        id,
        kind.name,
      ]);
    }
    _db.execute(
      'INSERT INTO groups (epoch, seq, position, previous_position, checkpoint, '
      'transaction_id, changes, erasures, events) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        _epoch,
        seq,
        position(seq),
        position(seq - 1),
        checkpoint(seq),
        transaction,
        jsonEncode(changes),
        '[]',
        jsonEncode(events),
      ],
    );
    final insert = _db.prepare(
      'INSERT OR IGNORE INTO event_sources (epoch, resource, seq, ordinal) VALUES (?, ?, ?, ?)',
    );
    try {
      for (final entry in sources.entries) {
        for (final resource in entry.value) {
          insert.execute([_epoch, resource, seq, entry.key]);
        }
      }
    } finally {
      insert.close();
    }
  }

  /// The opaque Scope position of group [seq]; `p0` is genesis.
  String position(int seq) => 'p$seq';

  /// The epoch-qualified checkpoint of group [seq]; `<epoch>_0` is this
  /// epoch's genesis position, so an empty Scope's checkpoint expires with
  /// its epoch like any other.
  String checkpoint(int seq) => '${_epoch}_$seq';

  /// The group sequence a checkpoint names, or null when it is neither the
  /// reserved `genesis` (complete history of the current epoch) nor one of
  /// this epoch's checkpoints at or before the head.
  int? checkpointSeq(String checkpoint) {
    if (checkpoint == genesisCheckpoint) return 0;
    final prefix = '${_epoch}_';
    if (!checkpoint.startsWith(prefix)) return null;
    final seq = int.tryParse(checkpoint.substring(prefix.length));
    if (seq == null ||
        seq < 0 ||
        '$seq' != checkpoint.substring(prefix.length)) {
      return null;
    }
    return seq <= head() ? seq : null;
  }

  /// Committed groups after [afterSeq], in order, at most [limit].
  List<JsonMap> groupsAfter(int afterSeq, {int? limit}) => [
    for (final row in _db.select(
      'SELECT * FROM groups WHERE epoch = ? AND seq > ? ORDER BY seq LIMIT ?',
      [_epoch, afterSeq, limit ?? -1],
    ))
      _group(row),
  ];

  JsonMap _group(Row row) {
    final events = jsonDecode(row['events'] as String) as List<Object?>;
    return {
      'scopeEpoch': row['epoch'],
      'authorizationView': authorizationView,
      'checkpoint': row['checkpoint'],
      'position': row['position'],
      'previousPosition': row['previous_position'],
      'projectionAdvance': false,
      'transaction': row['transaction_id'],
      'eventCount': events.length,
      'changes': jsonDecode(row['changes'] as String),
      'erasures': jsonDecode(row['erasures'] as String),
      'events': events,
    };
  }

  /// `(seq, ordinal)` of the Events in [resource]'s Event Source after the
  /// given cursor, at most [limit].
  List<(int, int)> sourceEvents(
    String resource,
    int seq,
    int ordinal,
    int limit,
  ) => [
    for (final row in _db.select(
      'SELECT seq, ordinal FROM event_sources WHERE epoch = ? AND resource = ? '
      'AND (seq > ? OR (seq = ? AND ordinal > ?)) ORDER BY seq, ordinal LIMIT ?',
      [_epoch, resource, seq, seq, ordinal, limit],
    ))
      (row['seq'] as int, row['ordinal'] as int),
  ];

  /// The Events of group [seq].
  List<JsonMap> groupEvents(int seq) {
    final row = _db.select(
      'SELECT events FROM groups WHERE epoch = ? AND seq = ?',
      [_epoch, seq],
    ).first;
    return (jsonDecode(row['events'] as String) as List).cast<JsonMap>();
  }

  /// Live records of [kind] in canonical-uri order after [afterId].
  List<JsonMap> page(
    AuthorityResourceKind kind, {
    required String afterId,
    required int limit,
    Set<String>? types,
    String? source,
    String? target,
    String? endpoint,
  }) {
    final where = ['id > ?'];
    final args = <Object?>[afterId];
    if (types != null) {
      where.add('type IN (${List.filled(types.length, '?').join(', ')})');
      args.addAll(types);
    }
    if (source != null) {
      where.add('source = ?');
      args.add(source);
    }
    if (target != null) {
      where.add('target = ?');
      args.add(target);
    }
    if (endpoint != null) {
      where.add('(source = ? OR target = ?)');
      args.addAll([endpoint, endpoint]);
    }
    args.add(limit);
    return [
      for (final row in _db.select(
        'SELECT record FROM ${_table(kind)} WHERE ${where.join(' AND ')} '
        'ORDER BY id LIMIT ?',
        args,
      ))
        decodeMap(row['record'] as String),
    ];
  }

  /// The retained receipt bound to ([principal], [key]) in this epoch.
  StoredReceipt? receiptByKey(String principal, String key) => _receipt(
    'scope = ? AND epoch = ? AND principal = ? AND idempotency_key = ?',
    [address.scope, _epoch, principal, key],
  );

  /// The retained receipt with [token] in this epoch.
  StoredReceipt? receiptByToken(String token) =>
      _receipt('epoch = ? AND token = ?', [_epoch, token]);

  StoredReceipt? _receipt(String where, List<Object?> args) {
    final row = _db
        .select('SELECT * FROM receipts WHERE $where', args)
        .firstOrNull;
    if (row == null) return null;
    return StoredReceipt(
      token: row['token'] as String,
      principal: row['principal'] as String,
      fingerprint: row['fingerprint'] as String,
      status: row['status'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        row['expires_at'] as int,
        isUtc: true,
      ),
      receipt: decodeMap(row['receipt'] as String),
    );
  }

  /// Retains a terminal receipt under its key.
  void putReceipt({
    required String principal,
    required String key,
    required StoredReceipt receipt,
  }) => _db.execute(
    'INSERT INTO receipts (scope, epoch, principal, idempotency_key, fingerprint, '
    'token, status, expires_at, receipt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      address.scope,
      _epoch,
      principal,
      key,
      receipt.fingerprint,
      receipt.token,
      receipt.status,
      receipt.expiresAt.millisecondsSinceEpoch,
      jsonEncode(receipt.receipt),
    ],
  );

  /// Forgets a failed receipt whose retention elapsed; its key is unbound.
  void forgetReceipt(String token) => _db.execute(
    'DELETE FROM receipts WHERE epoch = ? AND token = ?',
    [_epoch, token],
  );

  /// Pins a Type's descriptor and schema; call inside [write], after
  /// checking it can be installed. A Type's first revision goes in `types`
  /// and every later [revision] in `type_revisions`. Pinned rows are never
  /// changed or removed, so their count identifies the pinned set.
  void putType(JsonMap descriptor, JsonMap? schema, {required bool revision}) =>
      _db.execute(
        revision
            ? 'INSERT INTO type_revisions (id, descriptor, schema) '
                  'VALUES (?, ?, ?)'
            : 'INSERT INTO types (id, descriptor, schema) VALUES (?, ?, ?)',
        [
          descriptor['id'],
          jsonEncode(descriptor),
          schema == null ? null : jsonEncode(schema),
        ],
      );

  /// How many Type revisions are pinned.
  int typeCount() =>
      _db
              .select(
                'SELECT (SELECT count(*) FROM types) + '
                '(SELECT count(*) FROM type_revisions) AS n',
              )
              .first['n']
          as int;

  /// Every pinned Type revision, in an installation order: each Type's first
  /// revision (parents before children), then every later revision in the
  /// order it was pinned. A later revision introduces no Type ID and keeps
  /// its Type's category, so it installs after every first one.
  List<(JsonMap, JsonMap?)> installedTypes() => [
    for (final row in _db.select(
      'SELECT descriptor, schema FROM ('
      'SELECT 0 AS part, rowid AS seq, descriptor, schema FROM types '
      'UNION ALL '
      'SELECT 1 AS part, seq, descriptor, schema FROM type_revisions'
      ') ORDER BY part, seq',
    ))
      (
        decodeMap(row['descriptor'] as String),
        row['schema'] == null ? null : decodeMap(row['schema'] as String),
      ),
  ];
}

/// The URI of a stored Reference: the string itself or a pin's `uri`.
String referenceUri(Object? reference) =>
    reference is Map ? reference['uri']! as String : reference! as String;

/// A busy handler that waits out another connection's lock the way SQLite's
/// own `busy_timeout` does: it sleeps between attempts, a little longer each
/// time, and gives up once the sleeps would pass [timeout]. [onLockWait] runs
/// on the first attempt of each wait; if it throws, the wait ends there and
/// [guard] hands what it threw to the caller of the failed statement.
final class _LockWaiter {
  _LockWaiter(this.timeout, this.onLockWait);

  final Duration timeout;
  final void Function()? onLockWait;

  static const _delays = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100];

  int _waited = 0;

  /// What [onLockWait] threw during the current wait, until [guard] takes
  /// it. SQLite runs this handler through a native callback that turns a
  /// throw into `SQLITE_BUSY` and drops it, so the handler never throws.
  (Object, StackTrace)? _failure;

  /// Whether SQLite retries the statement after [attempt] busy results.
  bool call(int attempt) {
    if (attempt == 0) {
      _waited = 0;
      _failure = null;
      try {
        onLockWait?.call();
      } catch (error, stackTrace) {
        _failure = (error, stackTrace);
        return false;
      }
    }
    final remaining = timeout.inMilliseconds - _waited;
    if (remaining <= 0) return false;
    final delay = min(_delays[min(attempt, _delays.length - 1)], remaining);
    sleep(Duration(milliseconds: delay));
    _waited += delay;
    return true;
  }

  /// Runs [body], throwing what [onLockWait] threw in place of the
  /// `SQLITE_BUSY` its throw ended a statement with.
  T guard<T>(T Function() body) {
    try {
      return body();
    } on SqliteException catch (e) {
      final failure = _failure;
      if (failure == null || e.resultCode != SqlError.SQLITE_BUSY) rethrow;
      _failure = null;
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
  }
}

const _schema = '''
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
CREATE TABLE IF NOT EXISTS identities (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL) STRICT;
CREATE TABLE IF NOT EXISTS types (
  id TEXT PRIMARY KEY, descriptor TEXT NOT NULL, schema TEXT);
CREATE TABLE IF NOT EXISTS type_revisions (
  seq INTEGER PRIMARY KEY, id TEXT NOT NULL, descriptor TEXT NOT NULL,
  schema TEXT) STRICT;
CREATE TABLE IF NOT EXISTS beads (
  id TEXT PRIMARY KEY, type TEXT NOT NULL, revision TEXT NOT NULL,
  record TEXT NOT NULL) STRICT;
CREATE TABLE IF NOT EXISTS links (
  id TEXT PRIMARY KEY, type TEXT NOT NULL, revision TEXT NOT NULL,
  source TEXT NOT NULL, target TEXT NOT NULL, record TEXT NOT NULL) STRICT;
CREATE INDEX IF NOT EXISTS links_by_source ON links (source);
CREATE INDEX IF NOT EXISTS links_by_target ON links (target);
CREATE TABLE IF NOT EXISTS groups (
  epoch TEXT NOT NULL, seq INTEGER NOT NULL, position TEXT NOT NULL,
  previous_position TEXT NOT NULL, checkpoint TEXT NOT NULL,
  transaction_id TEXT NOT NULL, changes TEXT NOT NULL, erasures TEXT NOT NULL,
  events TEXT NOT NULL, PRIMARY KEY (epoch, seq)) STRICT;
CREATE TABLE IF NOT EXISTS event_sources (
  epoch TEXT NOT NULL, resource TEXT NOT NULL, seq INTEGER NOT NULL,
  ordinal INTEGER NOT NULL, PRIMARY KEY (epoch, resource, seq, ordinal)) STRICT;
CREATE TABLE IF NOT EXISTS receipts (
  scope TEXT NOT NULL, epoch TEXT NOT NULL, principal TEXT NOT NULL,
  idempotency_key TEXT NOT NULL, fingerprint TEXT NOT NULL,
  token TEXT NOT NULL UNIQUE, status TEXT NOT NULL, expires_at INTEGER NOT NULL,
  receipt TEXT NOT NULL,
  PRIMARY KEY (scope, epoch, principal, idempotency_key)) STRICT;
''';
