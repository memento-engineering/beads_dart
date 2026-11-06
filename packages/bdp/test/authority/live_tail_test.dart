// Live observation follows the durable log, not the instance: a watcher sees
// groups any connection to the file commits, ends when any connection
// reinitializes the Scope, and is done when its own authority closes.
import 'dart:async';
import 'dart:io';

import 'package:bdp/bdp.dart';
import 'package:test/test.dart';

import '../support/scope.dart';

void main() {
  late Directory dir;
  late String path;
  late ScopeAuthority a;
  late ScopeAuthority b;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bdp-live-');
    path = '${dir.path}/scope.db';
    a = ScopeAuthority.file(path, scope: scope);
    installWorkTypes(a);
    b = ScopeAuthority.file(path, scope: scope);
  });

  tearDown(() {
    a.close();
    b.close();
    dir.deleteSync(recursive: true);
  });

  /// The positions [watch] delivers, or the problem code that ended it.
  Future<Object> next(StreamIterator<Json> watch) async {
    try {
      if (!await watch.moveNext()) return 'done';
      return watch.current['position']!;
    } on AuthorityProblem catch (problem) {
      return problem.code;
    }
  }

  test("a watcher observes another connection's commit", () async {
    final watch = StreamIterator(a.watch());
    final first = next(watch);
    createTask(b, 'beads/from-b');
    expect(await first, 'p1');
    await watch.cancel();
  });

  test(
    'a local commit is delivered after the foreign group it follows',
    () async {
      final watch = StreamIterator(a.watch());
      final first = next(watch);
      // Both commit before the watcher's tail can look: A's own commit must
      // not overtake B's.
      createTask(b, 'beads/from-b');
      createTask(a, 'beads/from-a');
      expect(await first, 'p1');
      expect(await next(watch), 'p2');
      await watch.cancel();
    },
  );

  test('a watcher ends with cursor-expired when another connection '
      'reinitializes the Scope', () async {
    createTask(a, 'beads/before');
    final watch = StreamIterator(a.watch(after: 'genesis'));
    expect(await next(watch), 'p1');
    final ended = next(watch);
    b.reinitialize();
    expect(await ended, 'cursor-expired');
    expect(await next(watch), 'done');
  });

  test('a backlog read across several transactions stays in the epoch it '
      'started in', () async {
    final c = ScopeAuthority.file(path, scope: scope, backlogBatchGroups: 1);
    addTearDown(c.close);
    for (final id in ['one', 'two', 'three']) {
      createTask(b, 'beads/$id');
    }
    final oldEpoch = c.epoch;
    final delivered = <Json>[];
    final problems = <String>[];
    final done = Completer<void>();
    c
        .watch(after: 'genesis')
        .listen(
          (group) {
            delivered.add(group);
            if (delivered.length > 1) return;
            // Between the first batch and the second, another connection
            // starts a new epoch with as many groups as the old one had.
            b.reinitialize();
            for (final id in ['four', 'five', 'six']) {
              createTask(b, 'beads/$id');
            }
          },
          onError: (Object error) =>
              problems.add((error as AuthorityProblem).code),
          onDone: done.complete,
        );
    await done.future.timeout(const Duration(seconds: 5));
    expect(c.epoch, isNot(oldEpoch));
    expect([for (final g in delivered) g['position']], ['p1']);
    expect([for (final g in delivered) g['scopeEpoch']], [oldEpoch]);
    expect(problems, ['cursor-expired']);
  });

  test('close during a backlog ends the watcher, done', () async {
    final c = ScopeAuthority.file(path, scope: scope, backlogBatchGroups: 1);
    createTask(b, 'beads/one');
    createTask(b, 'beads/two');
    final delivered = <Object?>[];
    final errors = <Object>[];
    final done = Completer<void>();
    c
        .watch(after: 'genesis')
        .listen(
          (group) {
            delivered.add(group['position']);
            c.close();
          },
          onError: errors.add,
          onDone: done.complete,
        );
    await done.future.timeout(const Duration(seconds: 5));
    expect(delivered, ['p1']);
    expect(errors, isEmpty);
  });

  test('the backlog batch size is positive', () {
    expect(
      () => ScopeAuthority.file(path, scope: scope, backlogBatchGroups: 0),
      throwsArgumentError,
    );
  });

  test('a follow over the file sees a foreign commit and ends with its '
      'authority', () async {
    final LocalScope scope = a;
    final applied = <String>[];
    final seen = Completer<void>();
    final follow = scope.follow(const ChangefeedStart.now(), (group) async {
      applied.add(group.position.value);
      seen.complete();
    });
    createTask(b, 'beads/from-b');
    await seen.future;
    a.close();
    await follow.done;
    expect(applied, ['p1']);
  });

  test(
    'close ends every live watcher, from now and from a checkpoint',
    () async {
      createTask(a, 'beads/a');
      final fromNow = StreamIterator(a.watch());
      final fromGenesis = StreamIterator(a.watch(after: 'genesis'));
      expect(await next(fromGenesis), 'p1');
      final endings = [next(fromNow), next(fromGenesis)];
      a.close();
      expect(await Future.wait(endings), ['done', 'done']);
    },
  );

  test('close ends an in-memory watcher too', () async {
    final memory = memoryAuthority(TestClock());
    final watch = StreamIterator(memory.watch());
    final ended = next(watch);
    memory.close();
    expect(await ended, 'done');
  });
}
