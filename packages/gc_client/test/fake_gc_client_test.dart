import 'dart:io';

import 'package:gc_client/gc_client.dart';
import 'package:gc_client/testing.dart';
import 'package:test/test.dart';

/// The fixture directory the bash fake gc serves; `dart test` runs in
/// packages/gc_client, two levels below the repository root.
final fixtures = '${Directory.current.path}/test/fixtures';

void main() {
  late FakeGcClient gc;
  setUp(() => gc = FakeGcClient(fixtures));

  group('showBead', () {
    test('serves a bead from the array gc bd show prints', () async {
      final bead = await gc.showBead('fx-step');
      expect(bead.id, 'fx-step');
      expect(bead.title, 'A step bead');
      expect(bead.status, 'in_progress');
      expect(bead.issueType, 'task');
      expect(bead.startedAt, '2026-10-25T10:00:00Z');
      expect(bead.closedAt, isNull);
      expect(bead.metadata, {
        'gc.root_bead_id': 'fx-root',
        'gc.attempt': '2',
        'gc.kind': 'ralph',
      });
    });

    test('serves a bead written as a bare object', () async {
      final bead = await gc.showBead('fx-work');
      expect(bead.description, 'What to build.');
      expect(bead.design, '## Touches\n- `lib/a.dart` — created');
      expect(bead.acceptanceCriteria, '- [ ] AC-1 — it works');
      expect(bead.notes, 'A note.');
      expect(bead.metadata, {'validation_plan': 'bash tests/run.sh'});
    });

    test('reads every metadata value as text and leaves out null', () async {
      expect((await gc.showBead('fx-root')).metadata, {
        'gc.kind': 'workflow',
        'example.round': '1',
        'example.ready': 'true',
        'example.list': '["a","b"]',
      });
    });

    test('serves the dependency rows gc bd show prints', () async {
      final bead = await gc.showBead('fx-blocked');
      expect(bead.id, 'fx-blocked');
      expect(bead.status, 'open');
      expect(bead.dependencies, const [
        BeadDependency(id: 'fx-gate', status: 'open', type: 'blocks'),
        BeadDependency(id: 'fx-done', status: 'closed', type: 'blocks'),
      ]);
    });

    test('a bead gc prints no dependencies for has none', () async {
      expect((await gc.showBead('fx-step')).dependencies, isEmpty);
    });

    test('fails on a missing bead as the bash fake does', () {
      expect(
        gc.showBead('fx-missing'),
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
  });

  group('convoyStatus', () {
    test('serves a convoy and its sole child', () async {
      final convoy = await gc.convoyStatus('fx-convoy');
      expect(convoy.id, 'fx-convoy');
      expect(convoy.children, ['fx-work']);
      expect(convoy.soleChild, 'fx-work');
    });

    test('a convoy of two has no sole child', () async {
      final convoy = await gc.convoyStatus('fx-pair');
      expect(convoy.children, ['fx-work', 'fx-step']);
      expect(convoy.soleChild, isNull);
    });

    test('fails on a missing convoy as the bash fake does', () {
      expect(
        gc.convoyStatus('fx-none'),
        throwsA(
          isA<GcRefusal>().having(
            (e) => e.message,
            'message',
            'gc convoy status fx-none exited 1: fake-gc: no fixture for convoy '
                'fx-none (looked in $fixtures/convoy-fx-none.json)',
          ),
        ),
      );
    });
  });

  group('listByRoot', () {
    test('serves the beads of a root', () async {
      final beads = await gc.listByRoot('fx-root');
      expect([for (final b in beads) b.id], ['fx-step', 'fx-root']);
      expect(beads.first.closedAt, '2026-10-25T10:05:00Z');
    });

    test('serves nothing for a root without a fixture', () async {
      expect(await gc.listByRoot('fx-nobody'), isEmpty);
    });

    test('a .fail fixture fails the read with its text as stderr', () {
      expect(
        gc.listByRoot('fx-refused'),
        throwsA(
          isA<GcRefusal>().having(
            (e) => e.message,
            'message',
            'gc bd list exited 1: Error: invalid --metadata-field filter',
          ),
        ),
      );
    });
  });

  group('searchBeads', () {
    test('serves the hits of a query', () async {
      final hits = await gc.searchBeads('fx-query', limit: 5);
      expect([for (final b in hits) b.id], ['fx-work', 'fx-prior']);
    });

    test('serves nothing for a query without a fixture', () async {
      expect(await gc.searchBeads('fx-nothing', limit: 5), isEmpty);
    });

    test('a .fail fixture naming a transport failure is transient', () {
      expect(
        gc.searchBeads('fx-down', limit: 5),
        throwsA(
          isA<GcTransportException>().having(
            (e) => e.message,
            'message',
            'gc bd search fx-down exited 1: '
                'dial tcp 127.0.0.1:3307: connect: connection refused',
          ),
        ),
      );
    });

    test(
      "a .fail fixture's text, banners and all, is the failure's stderr",
      () {
        expect(
          gc.searchBeads('fx-down', limit: 5),
          throwsA(
            isA<GcTransportException>().having(
              (e) => e.stderr,
              'stderr',
              File('$fixtures/search-fx-down.fail').readAsStringSync(),
            ),
          ),
        );
      },
    );
  });

  group('writes', () {
    test('every write and mail is recorded in order, never applied', () async {
      await gc.updateMetadata('fx-step', {'example.b': '2', 'example.a': '1'});
      await gc.appendNotes('fx-work', 'a note');
      await gc.closeBead('fx-step', const Passed());
      await gc.closeBead(
        'fx-root',
        const Failed(FailureClass.hard, 'one\ntwo'),
      );
      await gc.release('fx-root', status: 'in_progress');
      await gc.mail('human', 'a subject', 'a body');
      expect(gc.mutations, [
        MetadataUpdated('fx-step', {'example.b': '2', 'example.a': '1'}),
        const NotesAppended('fx-work', 'a note'),
        const BeadClosed('fx-step', Passed()),
        const BeadClosed('fx-root', Failed(FailureClass.hard, 'one two')),
        const BeadReleased('fx-root', 'in_progress'),
        const MailSent('human', 'a subject', 'a body'),
      ]);
      expect((await gc.showBead('fx-step')).metadata, {
        'gc.root_bead_id': 'fx-root',
        'gc.attempt': '2',
        'gc.kind': 'ralph',
      });
    });

    test('metadata is recorded in the order it was set', () async {
      await gc.updateMetadata('fx-step', {'a': '1', 'b': '2'});
      expect(
        gc.mutations.single,
        isNot(MetadataUpdated('fx-step', {'b': '2', 'a': '1'})),
      );
    });

    test('a failure reason is recorded as the store receives it', () async {
      await gc.closeBead(
        'fx-step',
        Failed(FailureClass.transient, 'a\n${'x' * 500}'),
      );
      expect(gc.mutations, [
        BeadClosed('fx-step', Failed(FailureClass.transient, 'a ${'x' * 398}')),
      ]);
    });

    test('updateMetadata refuses an empty map or a bad key, recording '
        'nothing', () {
      for (final metadata in [
        <String, String>{},
        {'': 'v'},
        {'k=v': 'v'},
      ]) {
        expect(
          () => gc.updateMetadata('fx-step', metadata),
          throwsArgumentError,
        );
      }
      expect(gc.mutations, isEmpty);
    });

    test('a write to a refused id is recorded, then refused', () async {
      final refusing = FakeGcClient(fixtures, refuseWrites: {'fx-step'});
      final refused = isA<GcRefusal>().having(
        (e) => e.message,
        'message',
        'gc bd update fx-step exited 1',
      );
      await expectLater(
        refusing.updateMetadata('fx-step', {'k': 'v'}),
        throwsA(refused),
      );
      await expectLater(refusing.appendNotes('fx-step', 'n'), throwsA(refused));
      await expectLater(
        refusing.closeBead('fx-step', const Passed()),
        throwsA(refused),
      );
      await expectLater(
        refusing.release('fx-step', status: 'open'),
        throwsA(refused),
      );
      await refusing.updateMetadata('fx-work', {'k': 'v'});
      await refusing.mail('human', 's', 'b');
      expect(refusing.mutations, hasLength(6));
    });
  });

  group('claimHook', () {
    test('answers with the scripted claims, then drains', () async {
      const work = HookWork(beadId: 's-1', assignee: 'seat', reason: 'claimed');
      const down = GcTransportException('gc hook exited 4', exitCode: 4);
      final scripted = FakeGcClient(fixtures, claims: [work, down]);
      expect(await scripted.claimHook(), work);
      await expectLater(scripted.claimHook(), throwsA(same(down)));
      expect(await scripted.claimHook(), const HookDrain(reason: 'no_work'));
      expect(
        await scripted.claimHook(drainAck: true),
        const HookDrain(reason: 'no_work', drainAcknowledged: true),
      );
      expect(scripted.mutations, const [
        HookClaimed(),
        HookClaimed(),
        HookClaimed(),
        HookClaimed(drainAck: true),
      ]);
    });

    test('refuses a claim that is neither a HookClaim nor a GcException', () {
      expect(
        () => FakeGcClient(fixtures, claims: ['work']),
        throwsArgumentError,
      );
    });
  });

  group('sling', () {
    test('records the arguments in order and answers 0', () async {
      expect(await gc.sling(['t-1', 'b-1', '--on', 'code']), 0);
      expect(gc.mutations, [
        Slung(['t-1', 'b-1', '--on', 'code']),
      ]);
    });

    test('answers its slingExitCode, as FAKE_GC_SLING_RC sets the bash '
        "fake's", () async {
      final failing = FakeGcClient(fixtures, slingExitCode: 4);
      expect(await failing.sling(['b-1']), 4);
      expect(failing.mutations, [
        Slung(['b-1']),
      ]);
    });

    test('a sling equals another with the same arguments in the same order '
        'only', () {
      expect(Slung(['a', 'b']), Slung(['a', 'b']));
      expect(Slung(['a', 'b']).hashCode, Slung(['a', 'b']).hashCode);
      for (final other in [
        ['b', 'a'],
        ['a'],
        ['a\nb'],
      ]) {
        expect(Slung(['a', 'b']), isNot(Slung(other)));
      }
      expect(Slung(['a\nb', 'c']), isNot(Slung(['a', 'b\nc'])));
    });
  });
}
