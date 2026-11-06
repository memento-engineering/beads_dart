import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bdp/bdp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/scope.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bdp-durability-');
    path = '${dir.path}/scope.db';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ScopeAuthority open() => ScopeAuthority.file(path, scope: scope);

  /// Asserts the log is one contiguous chain whose every group has exactly
  /// one completed receipt, and returns the head sequence.
  int checkLog(ScopeAuthority authority) {
    final groups =
        (authority.changePage(after: 'genesis', limit: 200).body['groups']!
                as List)
            .cast<Json>();
    for (var i = 0; i < groups.length; i++) {
      expect(groups[i]['position'], 'p${i + 1}');
      expect(groups[i]['previousPosition'], 'p$i');
    }
    final db = sqlite3.open(path);
    try {
      final receipts = {
        for (final row in db.select(
          "SELECT receipt FROM receipts WHERE status = 'completed'",
        ))
          (jsonDecode(row['receipt'] as String) as Json)['effectPosition']:
              (jsonDecode(row['receipt'] as String) as Json)['transaction'],
      };
      expect(receipts.keys.toSet(), {for (final g in groups) g['position']});
      for (final g in groups) {
        expect(receipts[g['position']], g['transaction']);
      }
      final beads = db.select('SELECT count(*) AS n FROM beads').first['n'];
      expect(beads, groups.length);
    } finally {
      db.close();
    }
    return groups.length;
  }

  test('reinitialize starts a new epoch and keeps every old group', () {
    final authority = open();
    installWorkTypes(authority);
    for (var i = 0; i < 3; i++) {
      createTask(authority, 'beads/kept-$i');
    }
    final oldEpoch = authority.epoch;
    final oldGroups = groupsOf(authority.changePage(after: 'genesis'));
    authority.reinitialize();
    expect(authority.epoch, isNot(oldEpoch));
    expect(groupsOf(authority.changePage(after: 'genesis')), isEmpty);
    createTask(authority, 'beads/new');
    authority.close();

    final db = sqlite3.open(path);
    try {
      List<Object?> epochGroups(String epoch) => [
        for (final row in db.select(
          'SELECT checkpoint FROM groups WHERE epoch = ? ORDER BY seq',
          [epoch],
        ))
          row['checkpoint'],
      ];
      expect(epochGroups(oldEpoch), [
        for (final g in oldGroups) g['checkpoint'],
      ]);
      expect(
        db.select('SELECT count(*) AS n FROM beads').first['n'],
        1,
        reason: 'current state is the new epoch only',
      );
    } finally {
      db.close();
    }
  });

  test('a snapshot handle refetches the same manifest after a restart', () {
    final first = open();
    installWorkTypes(first);
    createTask(first, 'beads/a');
    createTask(first, 'beads/b');
    final manifest = first.snapshotDocument().body;
    final handle = Uri.parse(
      manifest['id']! as String,
    ).queryParameters['snapshot']!;
    expect(first.snapshotHandle(handle).body, manifest);
    createTask(first, 'beads/c');
    first.close();

    final second = open();
    expect(
      jsonEncode(second.snapshotHandle(handle).body),
      jsonEncode(manifest),
    );
    second.close();
  });

  test('an operation limit past the page bound is refused at construction', () {
    expect(
      () => ScopeAuthority.memory(
        scope: scope,
        maximumPageItems: 3,
        maximumOperations: 4,
      ),
      throwsArgumentError,
    );
  });

  test('close and reopen keeps the epoch, the log and the key bindings', () {
    final first = open();
    installWorkTypes(first);
    for (var i = 0; i < 5; i++) {
      createTask(first, 'beads/t$i');
    }
    final epoch = first.epoch;
    first.close();

    final second = open();
    expect(second.epoch, epoch);
    expect(second.typeRegistry[taskType], isNotNull);
    expect(checkLog(second), 5);
    // The retained key still answers without executing again.
    final retry = second.createBeadJson({
      'id': 'beads/t0',
      'type': taskType,
      'properties': {'title': 'Specify BDP mutation', 'status': 'open'},
    }, idempotencyKey: 'setup-beads-t0');
    expect(retry.json['effectPosition'], 'p1');
    expect(createTask(second, 'beads/t5')['id'], '${scope}beads/t5');
    expect(checkLog(second), 6);
    second.close();
  });

  test(
    'a writer killed mid-sequence loses no acknowledged group',
    () async {
      final setup = open();
      installWorkTypes(setup);
      setup.close();

      final writer = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/support/crash_writer.dart',
        path,
      ]);
      final acknowledged = <String>[];
      String? epoch;
      final enough = Completer<void>();
      final lines = writer.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('epoch ')) epoch = line.substring(6);
            if (line.startsWith('committed ')) {
              acknowledged.add(line.substring(10));
            }
            if (acknowledged.length >= 40 && !enough.isCompleted) {
              enough.complete();
            }
          });
      final stderr = writer.stderr.transform(utf8.decoder).join();
      await Future.any([
        enough.future,
        writer.exitCode.then(
          (code) async => fail('writer exited $code: ${await stderr}'),
        ),
      ]).timeout(const Duration(seconds: 90));
      writer.kill(ProcessSignal.sigkill);
      await writer.exitCode;
      await lines.cancel();

      final reopened = open();
      expect(reopened.epoch, epoch);
      final head = checkLog(reopened);
      expect(head, greaterThanOrEqualTo(acknowledged.length));
      expect(acknowledged.last, 'p${acknowledged.length}');
      // The next write continues the chain with no gap.
      final next = reopened.createBeadJson({
        'type': taskType,
        'properties': {'title': 'after'},
      }, idempotencyKey: 'after');
      expect(next.json['effectPosition'], 'p${head + 1}');
      reopened.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('writers released together by a barrier, behind a held write lock, '
      'produce one total order', () async {
    final setup = open();
    installWorkTypes(setup);
    setup.close();

    const writers = 6;
    const each = 25;
    final signals = ReceivePort();
    final results = ReceivePort();
    final arrivals = StreamIterator(signals);
    for (var w = 0; w < writers; w++) {
      await Isolate.spawn(_barrierWriter, (
        path,
        w,
        each,
        signals.sendPort,
        results.sendPort,
      ));
    }
    // Every writer has its authority open and waits at the barrier.
    final gates = <SendPort>[];
    while (gates.length < writers && await arrivals.moveNext()) {
      gates.add(arrivals.current as SendPort);
    }
    // Release them all while another connection holds the write lock, so
    // their first writes queue on it together; free it once every writer
    // reports it is past the barrier.
    final holder = sqlite3.open(path)..execute('BEGIN IMMEDIATE');
    for (final gate in gates) {
      gate.send(null);
    }
    for (var released = 0; released < writers; released++) {
      expect(await arrivals.moveNext(), isTrue);
      expect(arrivals.current, 'released');
    }
    holder
      ..execute('COMMIT')
      ..close();
    final positions = [
      for (final result in await results.take(writers).toList())
        if (result is List) result.cast<String>() else fail('$result'),
    ];
    await arrivals.cancel();
    final all = positions.expand((p) => p).toList();
    expect(all.toSet(), {for (var i = 1; i <= writers * each; i++) 'p$i'});
    expect(all, hasLength(writers * each));
    for (final mine in positions) {
      final order = [for (final p in mine) int.parse(p.substring(1))];
      expect(
        order,
        [...order]..sort(),
        reason: 'one writer sees its own order',
      );
    }
    final check = open();
    expect(checkLog(check), writers * each);
    check.close();
  });

  test('an open that fails to initialize closes the connection it opened', () {
    // The last connection to a WAL database to close removes its `-wal` and
    // `-shm` files; any connection still open keeps them.
    final wal = File('$path-wal');
    final first = open();
    expect(wal.existsSync(), isTrue);
    first.close();
    expect(wal.existsSync(), isFalse);
    expect(
      () => ScopeAuthority.file(path, scope: 'https://other.example/x/'),
      throwsStateError,
    );
    expect(wal.existsSync(), isFalse);
    expect(
      () => ScopeAuthority.file(
        path,
        scope: scope,
        maximumPageItems: 1,
        maximumOperations: 2,
      ),
      throwsArgumentError,
    );
    expect(wal.existsSync(), isFalse);
  });

  test('an open into an exclusively locked file meets the lock inside '
      'ScopeAuthority.file, waits for it, and completes over what the holder '
      'committed', () async {
    // A file still in rollback-journal mode with a writer holding its
    // exclusive lock: the opener cannot even read the journal mode until that
    // writer commits, so without lock waiting already in force when the open
    // issues its first statement it fails at once with SQLITE_BUSY. The
    // holder's transaction records the Scope with an epoch of its own, so
    // the epoch the open reports says whose committed state it read.
    const heldEpoch = '0123456789abcdef01234567';
    final holder = sqlite3.open(path)
      ..execute('PRAGMA journal_mode = DELETE')
      ..execute('BEGIN EXCLUSIVE')
      ..execute(
        'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT',
      )
      ..execute(
        "INSERT INTO meta VALUES ('scope', ?), ('epoch', ?), "
        "('transactions', '0')",
        [scope, heldEpoch],
      );
    final signals = ReceivePort();
    final exited = ReceivePort();
    addTearDown(() {
      signals.close();
      exited.close();
    });
    final arrivals = StreamIterator(signals);
    await Isolate.spawn(_lockedOpener, (
      path,
      signals.sendPort,
    ), onExit: exited.sendPort);
    // The open's own lock waiter reports from inside SQLite that a statement
    // of ScopeAuthority.file found the lock held. The holder has not let go,
    // so that open is still running, blocked on it.
    expect(
      await _observed(arrivals, 'the open meeting the held lock'),
      'waiting',
    );
    holder
      ..execute('COMMIT')
      ..close();
    // The open read the Scope the holder committed at its release: before
    // that commit no other connection could see the holder's epoch, so the
    // open finished after the release, and the write it made next is the
    // first group of that epoch.
    expect(await _observed(arrivals, 'the opener writing'), (heldEpoch, 'p1'));
    await exited.first.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('the opener never exited'),
    );
  });

  test('an open that meets a lock for longer than its lock timeout fails '
      'with SQLITE_BUSY, having said it met the lock', () {
    final holder = sqlite3.open(path)
      ..execute('PRAGMA journal_mode = DELETE')
      ..execute('BEGIN EXCLUSIVE')
      ..execute('CREATE TABLE held (x INTEGER)');
    var met = 0;
    expect(
      () => ScopeAuthority.file(
        path,
        scope: scope,
        lockTimeout: Duration.zero,
        onLockWait: () => met++,
      ),
      throwsA(
        isA<SqliteException>().having((e) => e.resultCode, 'resultCode', 5),
      ),
    );
    expect(met, 1);
    holder
      ..execute('COMMIT')
      ..close();
    final reopened = open();
    installWorkTypes(reopened);
    expect(createTaskReceipt(reopened, 'beads/after')['effectPosition'], 'p1');
    reopened.close();
  });

  test('what onLockWait throws ends the wait and reaches the caller of the '
      'open or the operation that met the lock, in place of SQLITE_BUSY', () {
    final observerFailure = StateError('the lock observer failed');
    // An open that meets the lock: the default lock timeout would wait ten
    // seconds, but the throw ends the wait at its first attempt.
    final holder = sqlite3.open(path)
      ..execute('PRAGMA journal_mode = DELETE')
      ..execute('BEGIN EXCLUSIVE')
      ..execute('CREATE TABLE held (x INTEGER)');
    expect(
      () => ScopeAuthority.file(
        path,
        scope: scope,
        onLockWait: () => throw observerFailure,
      ),
      throwsA(same(observerFailure)),
    );
    holder
      ..execute('ROLLBACK')
      ..close();

    // An operation of an open authority that meets another connection's
    // write lock.
    var throwing = true;
    final authority = ScopeAuthority.file(
      path,
      scope: scope,
      onLockWait: () {
        if (throwing) throw observerFailure;
      },
    );
    addTearDown(authority.close);
    final writer = sqlite3.open(path)..execute('BEGIN IMMEDIATE');
    expect(() => installWorkTypes(authority), throwsA(same(observerFailure)));
    writer
      ..execute('COMMIT')
      ..close();
    // The failure was handed over once: the next operation runs normally.
    throwing = false;
    installWorkTypes(authority);
    expect(createTaskReceipt(authority, 'beads/after')['effectPosition'], 'p1');
  });

  test('a completed receipt bound under an older request identity conflicts '
      'past its retention, and reinitializing the store unbinds it', () {
    final clock = TestClock();
    final body = {
      'type': taskType,
      'properties': {'title': 'counted', 'count': 1},
    };
    final before = ScopeAuthority.file(path, scope: scope, clock: clock.call);
    installWorkTypes(before);
    expect(
      before.createBeadJson(body, idempotencyKey: 'counted').status,
      'completed',
    );
    before.close();
    // The receipt as an authority that spelled request identity differently
    // left it: the same request, bound under another fingerprint.
    final db = sqlite3.open(path);
    try {
      db.execute("UPDATE receipts SET fingerprint = 'an older spelling'");
    } finally {
      db.close();
    }
    clock.now = clock.now.add(const Duration(days: 8));
    final after = ScopeAuthority.file(path, scope: scope, clock: clock.call);
    addTearDown(after.close);
    expect(
      () => after.createBeadJson(body, idempotencyKey: 'counted'),
      throwsA(
        isA<AuthorityProblem>().having(
          (p) => p.code,
          'code',
          'idempotency-conflict',
        ),
      ),
      reason: 'waiting out the retention does not unbind a completed receipt',
    );
    after.reinitialize();
    final retried = after.createBeadJson(body, idempotencyKey: 'counted');
    expect(retried.status, 'completed', reason: '${retried.json}');
    expect(retried.json['effectPosition'], 'p1');
  });

  test('a group written after another connection reinitializes carries the '
      'new epoch', () async {
    final a = open();
    installWorkTypes(a);
    final b = open();
    createTask(b, 'beads/before');
    final oldEpoch = b.epoch;
    final live = <Object>[];
    final ended = Completer<void>();
    b.watch().listen(live.add, onError: live.add, onDone: ended.complete);

    a.reinitialize();
    final newEpoch = a.epoch;
    expect(newEpoch, isNot(oldEpoch));

    final receipt = createTaskReceipt(b, 'beads/after');
    expect(receipt['status'], 'completed', reason: '$receipt');
    expect(receipt['scopeEpoch'], newEpoch);
    expect(receipt['effectPosition'], 'p1');
    expect(b.epoch, newEpoch);
    final groups = groupsOf(a.changePage(after: 'genesis'));
    expect(groups.single['scopeEpoch'], newEpoch);
    await ended.future;
    expect(live, [
      isA<AuthorityProblem>().having((p) => p.code, 'code', 'cursor-expired'),
    ]);
    a.close();
    b.close();

    final db = sqlite3.open(path);
    try {
      expect(
        db
            .select('SELECT epoch, seq FROM groups ORDER BY rowid')
            .map((row) => (row['epoch'], row['seq'])),
        [(oldEpoch, 1), (newEpoch, 1)],
      );
    } finally {
      db.close();
    }
  });
}

/// Creates a task Bead and returns its receipt's JSON. It runs in other
/// isolates too, so it asserts nothing itself.
Json createTaskReceipt(ScopeAuthority authority, String id) {
  final receipt = authority.createBeadJson({
    'id': id,
    'type': taskType,
    'properties': {'title': 'Specify BDP mutation'},
  }, idempotencyKey: 'receipt-${id.replaceAll('/', '-')}');
  return receipt.json;
}

/// One writer behind the barrier: opens its authority, announces itself on
/// [signals] with the port that releases it, reports `released` once
/// through, then writes [each] tasks and sends their positions to
/// [results] (or the failure, as text).
Future<void> _barrierWriter(
  (String, int, int, SendPort, SendPort) arguments,
) async {
  final (path, writer, each, signals, results) = arguments;
  try {
    final authority = ScopeAuthority.file(path, scope: scope);
    try {
      final gate = ReceivePort();
      signals.send(gate.sendPort);
      await gate.first;
      signals.send('released');
      results.send([
        for (var i = 0; i < each; i++)
          authority.createBeadJson({
                'type': taskType,
                'properties': {'title': 'w$writer-$i'},
              }, idempotencyKey: 'w$writer-$i').json['effectPosition']!
              as String,
      ]);
    } finally {
      authority.close();
    }
  } on Object catch (error) {
    results.send('writer $writer failed: $error');
  }
}

/// The next message on [arrivals], within a bound, named for the failure.
Future<Object?> _observed(
  StreamIterator<Object?> arrivals,
  String state,
) async {
  final arrived = await arrivals.moveNext().timeout(
    const Duration(seconds: 30),
    onTimeout: () => throw TimeoutException('never observed: $state'),
  );
  if (!arrived) fail('the port closed before $state');
  return arrivals.current;
}

/// Opens an authority into a file another connection holds locked, saying
/// `waiting` on [signals] the first time the open's lock waiter finds the
/// lock held, then writes, sending the authority's epoch and the write's
/// position once it is closed (or the failure, as text).
void _lockedOpener((String, SendPort) arguments) {
  final (path, signals) = arguments;
  try {
    var waited = false;
    final authority = ScopeAuthority.file(
      path,
      scope: scope,
      onLockWait: () {
        if (waited) return;
        waited = true;
        signals.send('waiting');
      },
    );
    final (String, Object?) written;
    try {
      if (!waited) {
        signals.send('the open never met the lock');
        return;
      }
      installWorkTypes(authority);
      written = (
        authority.epoch,
        createTaskReceipt(authority, 'beads/after-wait')['effectPosition'],
      );
    } finally {
      authority.close();
    }
    signals.send(written);
  } on Object catch (error) {
    signals.send('opener failed: $error');
  }
}
