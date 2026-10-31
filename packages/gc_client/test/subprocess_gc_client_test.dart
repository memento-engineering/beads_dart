import 'dart:convert';
import 'dart:io';

import 'package:gc_client/gc_client.dart';
import 'package:test/test.dart';

/// One run of `gc` that a [Runner] answered.
typedef Run = ({
  String executable,
  List<String> arguments,
  String? workingDirectory,
  Map<String, String>? environment,
});

/// A [GcRunner] that answers every run with [exitCode], [stdout] and
/// [stderr], or throws [error], and records each run in [runs].
final class Runner {
  Runner({this.exitCode = 0, this.stdout = '', this.stderr = '', this.error});

  final int exitCode;
  final String stdout;
  final String stderr;
  final ProcessException? error;
  final runs = <Run>[];

  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    runs.add((
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    ));
    if (error case final error?) throw error;
    return ProcessResult(1, exitCode, stdout, stderr);
  }
}

const drained =
    '{"schema_version":"1","ok":true,"command":"hook","action":"drain",'
    '"reason":"no_work"}';

void main() {
  group('each call runs the command line the bash seat ran', () {
    for (final (name, call, stdout, arguments)
        in <(String, Future<Object?> Function(GcClient), String, List<String>)>[
          (
            'showBead',
            (gc) => gc.showBead('b-1'),
            '[{"id":"b-1"}]',
            ['bd', 'show', 'b-1', '--json'],
          ),
          (
            'updateMetadata',
            (gc) => gc.updateMetadata('b-1', {
              'k.one': 'v=1',
              'k.two': 'two words',
            }),
            '',
            [
              'bd',
              'update',
              'b-1',
              '--set-metadata',
              'k.one=v=1',
              '--set-metadata',
              'k.two=two words',
            ],
          ),
          (
            'appendNotes',
            (gc) => gc.appendNotes('b-1', 'a\nnote'),
            '',
            ['bd', 'update', 'b-1', '--append-notes', 'a\nnote'],
          ),
          (
            'closeBead, passed',
            (gc) => gc.closeBead('b-1', const Passed()),
            '',
            [
              'bd',
              'update',
              'b-1',
              '--set-metadata',
              'gc.outcome=pass',
              '--status',
              'closed',
            ],
          ),
          (
            'closeBead, failed',
            (gc) => gc.closeBead(
              'b-1',
              const Failed(FailureClass.transient, 'line one\nline two'),
            ),
            '',
            [
              'bd',
              'update',
              'b-1',
              '--set-metadata',
              'gc.outcome=fail',
              '--set-metadata',
              'gc.failure_class=transient',
              '--set-metadata',
              'gc.failure_reason=line one line two',
              '--status',
              'closed',
            ],
          ),
          (
            'release',
            (gc) => gc.release('b-1', status: 'open'),
            '',
            [
              'bd',
              'update',
              'b-1',
              '--status',
              'open',
              '--assignee',
              '',
              '--force',
            ],
          ),
          (
            'convoyStatus',
            (gc) => gc.convoyStatus('c-1'),
            '{"children":[]}',
            ['convoy', 'status', 'c-1', '--json'],
          ),
          (
            'mail',
            (gc) => gc.mail('human', 'a subject', 'a\nbody'),
            '',
            ['mail', 'send', 'human', '-s', 'a subject', '-m', 'a\nbody'],
          ),
          (
            'claimHook',
            (gc) => gc.claimHook(),
            drained,
            ['hook', '--claim', '--json'],
          ),
          (
            'claimHook, acknowledging a drain',
            (gc) => gc.claimHook(drainAck: true),
            drained,
            ['hook', '--claim', '--drain-ack', '--json'],
          ),
          (
            'listByRoot',
            (gc) => gc.listByRoot('r-1'),
            '{"issues":[]}',
            [
              'bd',
              'list',
              '--all',
              '--metadata-field',
              'gc.root_bead_id=r-1',
              '--limit',
              '0',
              '--brief',
              '--skip-labels',
              '--flat',
              '--json',
            ],
          ),
          (
            'searchBeads',
            (gc) => gc.searchBeads('needle', limit: 5),
            '[]',
            ['bd', 'search', 'needle', '--json', '--limit', '5'],
          ),
        ]) {
      test(name, () async {
        final runner = Runner(stdout: stdout);
        await call(SubprocessGcClient(runner: runner.call));
        expect(runner.runs, hasLength(1));
        expect(runner.runs.single.executable, 'gc');
        expect(runner.runs.single.arguments, arguments);
      });
    }
  });

  test('runs its executable in its directory with its environment', () async {
    final runner = Runner(stdout: '[{"id":"b-1"}]');
    final gc = SubprocessGcClient(
      executable: '/opt/gc/bin/gc',
      workingDirectory: '/city',
      environment: {'GC_CITY': '/city'},
      runner: runner.call,
    );
    await gc.showBead('b-1');
    expect(runner.runs.single.executable, '/opt/gc/bin/gc');
    expect(runner.runs.single.workingDirectory, '/city');
    expect(runner.runs.single.environment, {'GC_CITY': '/city'});
  });

  test('sling starts gc itself, never through the runner, and a gc that '
      'cannot start is a transport failure', () async {
    final runner = Runner();
    await expectLater(
      SubprocessGcClient(
        executable: '/no/such/gc',
        runner: runner.call,
      ).sling(['b-1', '--on', 'code']),
      throwsA(
        isA<GcTransportException>().having(
          (e) => e.message,
          'message',
          startsWith('gc sling b-1 could not start: '),
        ),
      ),
    );
    expect(runner.runs, isEmpty);
  });

  test('updateMetadata refuses an empty map or a bad key and runs nothing', () {
    final runner = Runner();
    final gc = SubprocessGcClient(runner: runner.call);
    for (final metadata in [
      <String, String>{},
      {'': 'v'},
      {'k=v': 'v'},
    ]) {
      expect(() => gc.updateMetadata('b-1', metadata), throwsArgumentError);
    }
    expect(runner.runs, isEmpty);
  });

  test(
    'closeBead writes a failure reason on one line of 400 characters',
    () async {
      final runner = Runner();
      await SubprocessGcClient(
        runner: runner.call,
      ).closeBead('b-1', Failed(FailureClass.hard, 'a\n${'x' * 500}'));
      expect(
        runner.runs.single.arguments,
        contains('gc.failure_reason=a ${'x' * 398}'),
      );
    },
  );

  group('reads what gc prints', () {
    test('a bead, from the array gc bd show prints or a bare object', () async {
      for (final stdout in [
        '[{"id":"b-1","title":"T","status":"open","issue_type":"task",'
            '"metadata":{"k":"v","n":2,"t":true,"z":null,"l":["a"]}}]',
        '{"id":"b-1","title":"T","status":"open","issue_type":"task",'
            '"metadata":{"k":"v","n":2,"t":true,"z":null,"l":["a"]}}',
      ]) {
        final runner = Runner(stdout: stdout);
        final bead = await SubprocessGcClient(
          runner: runner.call,
        ).showBead('b-1');
        expect(bead.id, 'b-1');
        expect(bead.title, 'T');
        expect(bead.status, 'open');
        expect(bead.issueType, 'task');
        expect(bead.metadata, {'k': 'v', 'n': '2', 't': 'true', 'l': '["a"]'});
      }
    });

    test('a convoy, with its one child', () async {
      final runner = Runner(
        stdout:
            '{"children":[{"id":"w-1","title":"W","status":"open",'
            '"type":"task"}],"convoy":{"id":"c-1"},"ok":true}',
      );
      final convoy = await SubprocessGcClient(
        runner: runner.call,
      ).convoyStatus('c-1');
      expect(convoy.id, 'c-1');
      expect(convoy.children, ['w-1']);
      expect(convoy.soleChild, 'w-1');
    });

    test('a convoy with no children or with several has no sole child', () {
      for (final (stdout, children) in [
        ('{"children":null}', <String>[]),
        ('{}', <String>[]),
        ('{"children":[{"id":"w-1"},{"id":"w-2"}]}', ['w-1', 'w-2']),
      ]) {
        final convoy = Convoy.fromJson('c-1', jsonDecode(stdout))!;
        expect(convoy.children, children);
        expect(convoy.soleChild, isNull);
      }
    });

    test('the beads of a list and of a search', () async {
      final list = Runner(
        stdout:
            '{"issues":[{"id":"s-1","status":"closed",'
            '"started_at":"2026-10-25T10:00:00Z",'
            '"closed_at":"2026-10-25T10:05:00Z"},{"id":"s-2"}]}',
      );
      final beads = await SubprocessGcClient(
        runner: list.call,
      ).listByRoot('r-1');
      expect([for (final b in beads) b.id], ['s-1', 's-2']);
      expect(beads.first.startedAt, '2026-10-25T10:00:00Z');
      expect(beads.first.closedAt, '2026-10-25T10:05:00Z');
      expect(beads.last.startedAt, isNull);
      final search = Runner(stdout: '[{"id":"h-1"},{"id":"h-2"}]');
      final hits = await SubprocessGcClient(
        runner: search.call,
      ).searchBeads('q', limit: 2);
      expect([for (final b in hits) b.id], ['h-1', 'h-2']);
    });
  });

  group('claimHook reads gc answer whatever its exit status', () {
    for (final (name, exitCode, stdout, claim) in [
      (
        'a claimed bead',
        0,
        '{"schema_version":"1","ok":true,"command":"hook","action":"work",'
            '"reason":"claimed","bead_id":"s-1","assignee":"seat-1",'
            '"route":"pool.seat","root_bead_id":"r-1"}',
        const HookWork(
          beadId: 's-1',
          assignee: 'seat-1',
          reason: 'claimed',
          route: 'pool.seat',
          rootBeadId: 'r-1',
        ),
      ),
      (
        'a drain, which gc exits 1 on',
        1,
        drained,
        const HookDrain(reason: 'no_work'),
      ),
      (
        'an acknowledged drain',
        0,
        '{"schema_version":"1","ok":true,"command":"hook","action":"drain",'
            '"reason":"no_work","drain_acknowledged":true}',
        const HookDrain(reason: 'no_work', drainAcknowledged: true),
      ),
    ]) {
      test(name, () async {
        final runner = Runner(exitCode: exitCode, stdout: stdout);
        expect(
          await SubprocessGcClient(runner: runner.call).claimHook(),
          claim,
        );
      });
    }
  });

  group('a failed call', () {
    for (final (name, runner, matcher) in [
      (
        'exit 1 is a refusal, without gc banners',
        Runner(
          exitCode: 1,
          stderr:
              'gc bd: answering from the city store\nIssue b-1 not found\n'
              'Hint: try bd history b-1\n',
        ),
        refusal(
          'gc bd show b-1 exited 1: Issue b-1 not found\n'
          'Hint: try bd history b-1',
          1,
        ),
      ),
      (
        'exit 13 is a refusal',
        Runner(exitCode: 13, stderr: 'guard no longer holds'),
        refusal('gc bd show b-1 exited 13: guard no longer holds', 13),
      ),
      (
        'exit 2 is a refusal',
        Runner(exitCode: 2),
        refusal('gc bd show b-1 exited 2', 2),
      ),
      (
        'exit 4, the unreachable Dolt server, is a transport failure',
        Runner(
          exitCode: 4,
          stderr: 'gc bd: managed Dolt unreachable; bd fell back\n',
        ),
        transport('gc bd show b-1 exited 4', 4),
      ),
      (
        'a stderr naming a transport failure is a transport failure',
        Runner(
          exitCode: 1,
          stderr: 'Error: dial tcp 127.0.0.1:3307: connect: refused',
        ),
        transport(
          'gc bd show b-1 exited 1: '
          'Error: dial tcp 127.0.0.1:3307: connect: refused',
          1,
        ),
      ),
      (
        'the transport markers match in any case',
        Runner(exitCode: 1, stderr: 'Connection Refused'),
        transport('gc bd show b-1 exited 1: Connection Refused', 1),
      ),
      (
        'a signal is a transport failure',
        Runner(exitCode: -15),
        transport('gc bd show b-1 exited -15', -15),
      ),
      (
        'only the last 400 characters of stderr are kept',
        Runner(exitCode: 1, stderr: 'gc bd: banner\nhead ${'x' * 400}'),
        refusal('gc bd show b-1 exited 1: ${'x' * 400}', 1),
      ),
      (
        'output that is not JSON is a transport failure',
        Runner(stdout: 'not json'),
        transport('gc bd show b-1 printed unexpected output: not json', 0),
      ),
      (
        'an empty array is a transport failure',
        Runner(stdout: '[]'),
        transport('gc bd show b-1 printed unexpected output: []', 0),
      ),
      (
        'a bead without an id is a transport failure',
        Runner(stdout: '[{"title":"no id"}]'),
        transport(
          'gc bd show b-1 printed unexpected output: [{"title":"no id"}]',
          0,
        ),
      ),
      (
        'gc that cannot start is a transport failure',
        Runner(
          error: const ProcessException(
            'gc',
            ['bd'],
            'No such file or directory',
            2,
          ),
        ),
        transport('gc bd show b-1 could not start: No such file or directory'),
      ),
    ]) {
      test(name, () {
        expect(
          SubprocessGcClient(runner: runner.call).showBead('b-1'),
          throwsA(matcher),
        );
      });
    }

    test('a gc line that is no banner stays in the message', () {
      final runner = Runner(
        exitCode: 1,
        stderr:
            'gc convoy status: bead not found\n'
            'hint: run "gc doctor" for diagnostics\n',
      );
      expect(
        SubprocessGcClient(runner: runner.call).convoyStatus('c-1'),
        throwsA(
          refusal(
            'gc convoy status c-1 exited 1: gc convoy status: bead not found\n'
            'hint: run "gc doctor" for diagnostics',
            1,
          ),
        ),
      );
    });

    test('a hook failure without an answer is read as any other', () {
      final failed = Runner(
        exitCode: 1,
        stdout:
            '{"schema_version":"1","ok":false,"error":{"code":"command_failed",'
            '"message":"command failed","exit_code":1}}',
        stderr: 'gc hook --claim: assignee not specified\n',
      );
      expect(
        SubprocessGcClient(runner: failed.call).claimHook(),
        throwsA(
          refusal(
            'gc hook exited 1: gc hook --claim: assignee not specified',
            1,
          ),
        ),
      );
      final silent = Runner();
      expect(
        SubprocessGcClient(runner: silent.call).claimHook(),
        throwsA(transport('gc hook printed unexpected output: (empty)', 0)),
      );
    });

    test('a write that fails throws as a read does', () {
      final runner = Runner(exitCode: 1, stderr: 'Error: issue b-1 not found');
      expect(
        SubprocessGcClient(
          runner: runner.call,
        ).updateMetadata('b-1', {'k': 'v'}),
        throwsA(
          refusal('gc bd update b-1 exited 1: Error: issue b-1 not found', 1),
        ),
      );
    });

    test('a failure keeps what gc printed on stderr, banners and all; a '
        'call that exited 0 keeps none', () {
      const said =
          'gc bd: answering from the city store\n'
          'store unreachable: dial tcp\n';
      expect(
        SubprocessGcClient(
          runner: Runner(exitCode: 1, stderr: said).call,
        ).searchBeads('q', limit: 14),
        throwsA(
          isA<GcTransportException>().having((e) => e.stderr, 'stderr', said),
        ),
      );
      expect(
        SubprocessGcClient(
          runner: Runner(stdout: 'not json', stderr: said).call,
        ).showBead('b-1'),
        throwsA(
          isA<GcTransportException>().having((e) => e.stderr, 'stderr', ''),
        ),
      );
    });
  });
}

/// A [GcRefusal] with [message] and [exitCode].
Matcher refusal(String message, int exitCode) => isA<GcRefusal>()
    .having((e) => e.message, 'message', message)
    .having((e) => e.exitCode, 'exitCode', exitCode);

/// A [GcTransportException] with [message] and [exitCode].
Matcher transport(String message, [int? exitCode]) =>
    isA<GcTransportException>()
        .having((e) => e.message, 'message', message)
        .having((e) => e.exitCode, 'exitCode', exitCode);
