import 'package:bdp/bdp.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final snapshots = fixture('transactional/snapshots.json');
  final changefeed = fixture('transactional/changefeed.json');

  SnapshotManifest manifest(String id) =>
      SnapshotManifest.fromJson(bodyOf(responseOf(exchange(snapshots, id))));

  ChangefeedPage page(String id) =>
      ChangefeedPage.fromJson(bodyOf(responseOf(exchange(changefeed, id))));

  Map<String, Object?> groupJson(String id) => {
    ...((changefeed['groupExamples']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .singleWhere((example) => example['id'] == id)['body'])!
        as Map<String, Object?>,
  };

  ChangeGroup committed(String id) => ChangeGroup.fromJson(groupJson(id));

  Replica install(SnapshotManifest manifest) => Replica.fromSnapshot(
    manifest,
    beads: manifest.beads.items,
    links: manifest.links.items,
  );

  Matcher refusedFor(ReplicationFault fault) => throwsA(
    isA<ReplicationException>().having((e) => e.fault, 'fault', fault),
  );

  const acme = 'https://beads.example/acme/';

  group('snapshot install', () {
    test('anchors the replica at the snapshot checkpoint', () {
      final replica = install(manifest('snapshot-at-pos-42'));
      expect(replica.checkpoint, Checkpoint('ckpt-42'));
      expect(replica.position, ScopePosition('pos-42'));
      expect(replica.beads.keys, {
        '${acme}beads/task-41',
        '${acme}beads/task-42',
      });
      expect(replica.links.keys, {'${acme}links/blocks-3'});
    });

    test('installs a snapshot carrying an erasure ledger', () {
      final replica = install(manifest('snapshot-at-pos-47'));
      expect(replica.checkpoint, Checkpoint('ckpt-47'));
      expect(replica.beads, isNot(contains('${acme}beads/task-42')));
    });

    test('refuses a snapshot whose Link names an absent endpoint', () {
      final snapshot = manifest('snapshot-at-pos-42');
      expect(
        () => Replica.fromSnapshot(
          snapshot,
          beads: [
            for (final bead in snapshot.beads.items)
              if (!bead.id.endsWith('task-41')) bead,
          ],
          links: snapshot.links.items,
        ),
        refusedFor(ReplicationFault.missingEndpoint),
      );
    });
  });

  group('changefeed page application', () {
    test('applies the group atomically and advances the checkpoint', () {
      final before = install(manifest('snapshot-at-pos-42'));
      final after = before.applyPage(page('after-ckpt-42'));

      expect(after.checkpoint, Checkpoint('ckpt-43'));
      expect(after.position, ScopePosition('pos-43'));
      final decision = after.beads['${acme}beads/dec-9']!;
      expect(decision.revision, Revision('dec-9-r2'));
      final cites = decision.ownedLinks!['https://work.example/types/cites']!;
      expect(cites.single, after.links['${acme}links/9c1e']);
      expect(
        after.beads['${acme}beads/task-42']!.revision,
        Revision('task-42-r8'),
      );
      expect(
        after.beads['${acme}beads/task-41'],
        before.beads['${acme}beads/task-41'],
      );

      // The replica is a value: the previous one is untouched.
      expect(before.checkpoint, Checkpoint('ckpt-42'));
      expect(
        before.beads['${acme}beads/task-42']!.revision,
        Revision('task-42-r7'),
      );
    });

    test('walks the committed groups and their erasures in order', () {
      var replica = install(
        manifest('snapshot-at-pos-42'),
      ).applyPage(page('after-ckpt-42'));
      replica = replica.apply(
        committed('after-ckpt-43-historical-erasure-committed-group'),
      );
      expect(replica.checkpoint, Checkpoint('ckpt-44'));
      expect(
        replica.beads['${acme}beads/task-42']!.revision,
        Revision('task-42-r8'),
      );

      replica = replica.apply(
        committed('after-ckpt-44-correction-committed-group'),
      );
      expect(replica.checkpoint, Checkpoint('ckpt-45'));
      final task = replica.beads['${acme}beads/task-42']!;
      expect(task.revision, Revision('task-42-r9'));
      expect(task.properties['title'], 'Specify BDP mutation receipts');

      // pos-46 is not in the fixture: the next group is a gap.
      final atPos45 = replica;
      expect(
        () =>
            atPos45.apply(committed('after-ckpt-46-tombstone-committed-group')),
        refusedFor(ReplicationFault.positionMismatch),
      );
      expect(atPos45.checkpoint, Checkpoint('ckpt-45'));
    });

    test('a replayed group is a duplicate, not a second application', () {
      final replica = install(
        manifest('snapshot-at-pos-42'),
      ).applyPage(page('after-ckpt-42'));
      expect(
        () => replica.applyPage(page('after-ckpt-42')),
        refusedFor(ReplicationFault.positionMismatch),
      );
    });

    Replica at46WithRel5() => Replica.fromSnapshot(
      SnapshotManifest(
        id: '${acme}snapshot?snapshot=at-46',
        scope: acme,
        scopeEpoch: ScopeEpoch('epoch-1'),
        authorizationView: AuthorizationView('view-a'),
        scopePosition: ScopePosition('pos-46'),
        checkpoint: Checkpoint('ckpt-46'),
        expiresAt: '2026-09-07T19:40:00Z',
        erasures: const [],
        beads: Page(items: const [], next: null),
        links: Page(items: const [], next: null),
      ),
      beads: [
        for (final id in ['task-43', 'task-44'])
          BeadRecord(
            id: '${acme}beads/$id',
            type: 'https://work.example/types/task',
            revision: Revision('$id-r1'),
            properties: const {},
          ),
      ],
      links: [
        LinkRecord(
          id: '${acme}links/rel-5',
          type: 'https://work.example/types/relates',
          revision: Revision('rel-5-r1'),
          source: const UriReference('${acme}beads/task-43'),
          target: const UriReference('${acme}beads/task-44'),
          properties: const {},
        ),
      ],
    );

    Map<String, Object?> beadTombstone(String id) => {
      'operation': 'tombstone',
      'resourceKind': 'bead',
      'resource': {
        'id': '${acme}beads/$id',
        'type': 'https://work.example/types/task',
        'revision': '$id-r1',
      },
    };

    test('a tombstone removes the Resource', () {
      final after = at46WithRel5().apply(
        committed('after-ckpt-46-tombstone-committed-group'),
      );
      expect(after.links, isEmpty);
      expect(after.checkpoint, Checkpoint('ckpt-47'));
    });

    test('a Bead tombstone that leaves a live Link dangling is refused', () {
      final before = at46WithRel5();
      final json = groupJson('after-ckpt-46-tombstone-committed-group')
        ..['changes'] = [beadTombstone('task-44')]
        ..['erasures'] = <Object?>[];
      expect(
        () => before.apply(ChangeGroup.fromJson(json)),
        refusedFor(ReplicationFault.missingEndpoint),
      );
      expect(before.beads, contains('${acme}beads/task-44'));
    });

    test('a Bead tombstone that also tombstones its Links applies', () {
      final json = groupJson('after-ckpt-46-tombstone-committed-group');
      json['changes'] = [
        ...json['changes']! as List<Object?>,
        beadTombstone('task-44'),
      ];
      final after = at46WithRel5().apply(ChangeGroup.fromJson(json));
      expect(after.links, isEmpty);
      expect(after.beads.keys, {'${acme}beads/task-43'});
    });

    test('a projection advance moves the checkpoint and nothing else', () {
      final viewB = Replica.fromSnapshot(
        SnapshotManifest(
          id: '${acme}snapshot?snapshot=view-b-43',
          scope: acme,
          scopeEpoch: ScopeEpoch('epoch-1'),
          authorizationView: AuthorizationView('view-b'),
          scopePosition: ScopePosition('pos-43'),
          checkpoint: Checkpoint('ckpt-b-43'),
          expiresAt: '2026-09-07T19:22:00Z',
          erasures: const [],
          beads: Page(items: const [], next: null),
          links: Page(items: const [], next: null),
        ),
        beads: const [],
        links: const [],
      );
      final advanced = viewB.applyPage(page('view-b-projection-advance'));
      expect(advanced.checkpoint, Checkpoint('ckpt-b-44'));
      expect(advanced.position, ScopePosition('pos-44'));
      expect(advanced.beads, isEmpty);
      expect(advanced.links, isEmpty);
    });

    test('a page for another view is refused', () {
      final replica = install(manifest('snapshot-at-pos-42'));
      expect(
        () => replica.applyPage(page('view-b-projection-advance')),
        refusedFor(ReplicationFault.foreignView),
      );
    });

    test('a group from another epoch is refused', () {
      final replica = install(
        manifest('snapshot-at-pos-42'),
      ).applyPage(page('after-ckpt-42'));
      final json = groupJson('after-ckpt-43-historical-erasure-committed-group')
        ..['scopeEpoch'] = 'epoch-2';
      expect(
        () => replica.apply(ChangeGroup.fromJson(json)),
        refusedFor(ReplicationFault.foreignEpoch),
      );
    });

    test('an inline owned Link that disagrees refuses the whole group', () {
      final before = install(manifest('snapshot-at-pos-42'));
      final json = page('after-ckpt-42').groups.single.toJson();
      final changes = json['changes']! as List<Object?>;
      final decision = changes.first! as Map<String, Object?>;
      final resource = {...decision['resource']! as Map<String, Object?>};
      final owned = resource['ownedLinks']! as Map<String, Object?>;
      final inline = {
        ...(owned.values.single! as List<Object?>).single!
            as Map<String, Object?>,
        'properties': {'role': 'tampered'},
      };
      resource['ownedLinks'] = {
        owned.keys.single: [inline],
      };
      changes[0] = {...decision, 'resource': resource};
      expect(
        () => before.apply(ChangeGroup.fromJson(json)),
        refusedFor(ReplicationFault.ownedLinkDisagreement),
      );
      expect(before.checkpoint, Checkpoint('ckpt-42'));
    });

    test('an erased version still held live is refused', () {
      final replica = install(manifest('snapshot-at-pos-42'));
      final json = groupJson('after-ckpt-43-historical-erasure-committed-group')
        ..['previousPosition'] = 'pos-42';
      expect(
        () => replica.apply(ChangeGroup.fromJson(json)),
        refusedFor(ReplicationFault.erasedStateRetained),
      );
    });
  });

  group('change group shape', () {
    test('eventCount must equal the Events served', () {
      final json = groupJson('after-ckpt-44-correction-committed-group')
        ..['eventCount'] = 2;
      expect(() => ChangeGroup.fromJson(json), throwsFormatException);
    });

    test('a projection advance carries no transaction', () {
      final json = page('view-b-projection-advance').groups.single.toJson()
        ..['transaction'] = 'txn-1';
      expect(() => ChangeGroup.fromJson(json), throwsFormatException);
    });
  });
}
