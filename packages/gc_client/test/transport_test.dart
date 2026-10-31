import 'dart:io';

import 'package:gc_client/gc_client.dart';
import 'package:gc_client/testing.dart';
import 'package:test/test.dart';

/// The package root: `dart test` runs here.
final package = Directory.current.path;

/// The fixture directory both fakes serve.
final fixtures = '$package/test/fixtures';

// The one transport test: SubprocessGcClient spawns test/fake-gc.sh,
// first on PATH as `gc`, and the command lines the bash fake logs are pinned
// exactly.
void main() {
  late Directory tmp;
  late File log;

  /// The transport with the bash fake first on PATH, and [extra] variables.
  SubprocessGcClient transport([Map<String, String> extra = const {}]) =>
      SubprocessGcClient(
        environment: {
          'PATH': '${tmp.path}/bin:${Platform.environment['PATH']}',
          'GC_FIXTURES': fixtures,
          'FAKE_GC_LOG': log.path,
          ...extra,
        },
      );

  /// What the bash fake logged since the last [setUp].
  List<String> logged() => log.readAsLinesSync();

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('gc-transport.');
    Directory('${tmp.path}/bin').createSync();
    Link('${tmp.path}/bin/gc').createSync('$package/test/fake-gc.sh');
    log = File('${tmp.path}/gc.log')..writeAsStringSync('');
    // Nothing below may reach a real gc: the bash fake must answer first.
    final bead = await transport().showBead('fx-step');
    if (bead.title != 'A step bead') {
      throw StateError('gc on PATH is not test/fake-gc.sh');
    }
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));
  setUp(() => log.writeAsStringSync(''));

  test('showBead serves the fixtures through the bash fake', () async {
    final step = await transport().showBead('fx-step');
    expect(step.metadata['gc.root_bead_id'], 'fx-root');
    final work = await transport().showBead('fx-work');
    expect(work.description, 'What to build.');
    expect(work.metadata, {'validation_plan': 'bash tests/run.sh'});
  });

  test('a missing bead is refused with the bash fake words', () {
    expect(
      transport().showBead('fx-missing'),
      throwsA(
        isA<GcRefusal>().having(
          (e) => e.message,
          'message',
          'gc bd show fx-missing exited 1: fake-gc: no fixture for bead '
              'fx-missing (looked in $fixtures/fx-missing.json)',
        ),
      ),
    );
  });

  test('every write is logged as the bash seat logged it', () async {
    final gc = transport();
    await gc.updateMetadata('fx-step', {
      'example.a': '1',
      'example.b': 'two words',
    });
    await gc.closeBead('fx-step', const Passed());
    await gc.closeBead(
      'fx-step',
      const Failed(FailureClass.hard, 'line one\nline two'),
    );
    await gc.release('fx-root', status: 'in_progress');
    await gc.appendNotes('fx-work', 'a note');
    await gc.mail('human', 'a subject', 'a body');
    expect(logged(), [
      'bd update fx-step --set-metadata example.a=1 '
          '--set-metadata example.b=two words',
      'bd update fx-step --set-metadata gc.outcome=pass --status closed',
      'bd update fx-step --set-metadata gc.outcome=fail '
          '--set-metadata gc.failure_class=hard '
          '--set-metadata gc.failure_reason=line one line two --status closed',
      'bd update fx-root --status in_progress --assignee  --force',
      'bd update fx-work --append-notes a note',
      'mail send human -s a subject -m a body',
    ]);
  });

  test(
    'a refused write is logged, then refused as the fake refuses it',
    () async {
      final refused = isA<GcRefusal>().having(
        (e) => e.message,
        'message',
        'gc bd update fx-step exited 1',
      );
      await expectLater(
        transport({
          'FAKE_GC_FAIL_UPDATE': 'fx-step',
        }).updateMetadata('fx-step', {'k': 'v'}),
        throwsA(refused),
      );
      await expectLater(
        FakeGcClient(
          fixtures,
          refuseWrites: {'fx-step'},
        ).updateMetadata('fx-step', {'k': 'v'}),
        throwsA(refused),
      );
      expect(logged(), ['bd update fx-step --set-metadata k=v']);
    },
  );

  test('the reads the bash fake logs are logged', () async {
    final gc = transport();
    expect((await gc.convoyStatus('fx-convoy')).soleChild, 'fx-work');
    expect(
      [for (final b in await gc.listByRoot('fx-root')) b.id],
      ['fx-step', 'fx-root'],
    );
    expect(
      [for (final b in await gc.searchBeads('fx-query', limit: 5)) b.id],
      ['fx-work', 'fx-prior'],
    );
    expect(logged(), [
      'convoy status fx-convoy',
      'bd list --all --metadata-field gc.root_bead_id=fx-root --limit 0 '
          '--brief --skip-labels --flat --json',
      'bd search fx-query',
    ]);
  });

  test('a .fail fixture fails the read, read as gc reads it', () {
    expect(
      transport().searchBeads('fx-down', limit: 5),
      throwsA(
        isA<GcTransportException>().having(
          (e) => e.message,
          'message',
          'gc bd search fx-down exited 1: '
              'dial tcp 127.0.0.1:3307: connect: connection refused',
        ),
      ),
    );
    expect(
      transport().listByRoot('fx-refused'),
      throwsA(
        isA<GcRefusal>().having(
          (e) => e.message,
          'message',
          'gc bd list exited 1: Error: invalid --metadata-field filter',
        ),
      ),
    );
  });

  test('sling hands gc its arguments and answers its exit status, as the '
      'in-process fake does', () async {
    const args = [
      'mingle/houston.judge',
      'fx-work',
      '--on',
      'code',
      '--var',
      'review_shape=docs',
    ];
    expect(await transport().sling(args), 0);
    expect(await transport({'FAKE_GC_SLING_RC': '4'}).sling(args), 4);
    expect(await FakeGcClient(fixtures, slingExitCode: 4).sling(args), 4);
    expect(logged(), [
      'sling mingle/houston.judge fx-work --on code --var review_shape=docs',
      'sling mingle/houston.judge fx-work --on code --var review_shape=docs',
    ]);
  });

  test('claimHook gets no answer from the bash fake', () {
    expect(
      transport().claimHook(),
      throwsA(
        isA<GcTransportException>().having(
          (e) => e.message,
          'message',
          'gc hook printed unexpected output: (empty)',
        ),
      ),
    );
  });

  test('a gc that cannot start is a transport failure', () {
    expect(
      SubprocessGcClient(
        executable: '${tmp.path}/no-such-gc',
      ).showBead('fx-step'),
      throwsA(
        isA<GcTransportException>().having(
          (e) => e.message,
          'message',
          startsWith('gc bd show fx-step could not start: '),
        ),
      ),
    );
  });

  test(
    'the in-process fake answers every read as the bash fake does',
    () async {
      final gc = transport();
      final fake = FakeGcClient(fixtures);
      for (final read in <Future<Object?> Function(GcClient)>[
        (c) => c.showBead('fx-step'),
        (c) => c.showBead('fx-work'),
        (c) => c.showBead('fx-root'),
        (c) => c.showBead('fx-missing'),
        (c) => c.convoyStatus('fx-convoy'),
        (c) => c.convoyStatus('fx-pair'),
        (c) => c.convoyStatus('fx-none'),
        (c) => c.listByRoot('fx-root'),
        (c) => c.listByRoot('fx-nobody'),
        (c) => c.listByRoot('fx-refused'),
        (c) => c.searchBeads('fx-query', limit: 5),
        (c) => c.searchBeads('fx-nothing', limit: 5),
        (c) => c.searchBeads('fx-down', limit: 5),
      ]) {
        expect(
          await describe(() => read(fake)),
          await describe(() => read(gc)),
        );
      }
    },
  );
}

/// What [call] answers, or how it fails, as one line.
Future<String> describe(Future<Object?> Function() call) async {
  try {
    return switch (await call()) {
      final Bead bead => _bead(bead),
      final List<Bead> beads => beads.map(_bead).join('; '),
      final Convoy convoy => 'convoy ${convoy.id} ${convoy.children}',
      final other => '$other',
    };
  } on GcException catch (error) {
    return '${error.runtimeType} ${error.exitCode}: ${error.message}';
  }
}

String _bead(Bead bead) => [
  bead.id,
  bead.title,
  bead.description,
  bead.design,
  bead.acceptanceCriteria,
  bead.notes,
  bead.status,
  bead.issueType,
  bead.startedAt,
  bead.closedAt,
  bead.metadata,
].join('|');
