import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bdp/bdp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/scope.dart';

/// The fixture timeline's first batch, guarded by the Task's actual
/// revision.
List<Json> firstBatch(String taskRevision) {
  final request = exchange('batch', 'batch-1-original')['request']! as Json;
  final operations = ((request['body']! as Json)['operations']! as List)
      .cast<Json>();
  return [
    for (final op in operations)
      op.containsKey('expectedRevision')
          ? {...op, 'expectedRevision': taskRevision}
          : op,
  ];
}

void main() {
  late TestClock clock;
  late ScopeAuthority authority;

  setUp(() {
    clock = TestClock();
    authority = memoryAuthority(clock);
  });

  tearDown(() => authority.close());

  test('a Resource created and deleted in one batch leaves no change but '
      'keeps its identity', () {
    final receipt = authority.batchJson([
      {
        'operation': 'createBead',
        'name': 'z',
        'type': taskType,
        'properties': {'title': 'transient'},
      },
      {'operation': 'deleteBead', 'bead': '@z'},
    ], idempotencyKey: 'create-delete');
    expect(receipt.status, 'completed');
    final id = (receipt.results.first['resource']! as Json)['id']! as String;
    final group = groupsOf(authority.changePage(after: 'genesis')).single;
    expectSchema(group, 'changeGroup');
    expect(group['changes'], isEmpty);
    expect(
      [for (final e in group['events'] as List) (e as Json)['type']],
      ['created', 'deleted'],
    );
    final reuse = authority.createBeadJson({
      'id': id,
      'type': taskType,
      'properties': {'title': 'again'},
    }, idempotencyKey: 'reuse');
    expect(reuse.problem!['code'], 'identity-taken');
  });

  group('change groups match the fixture timeline', () {
    test('one group, five facts in operation order, three postimages', () {
      final task = createTask(authority, 'beads/task-42');
      final receipt = authority.batchJson(
        firstBatch(task['revision']! as String),
        idempotencyKey: 'client-key-0001',
      );
      expect(receipt.status, 'completed', reason: '${receipt.json}');

      final afterTask = groupsOf(authority.changePage(after: 'genesis')).first;
      final page = authority.changePage(
        after: afterTask['checkpoint']! as String,
      );
      expectSchema(page.body, 'changefeedPage');
      final group = groupsOf(page).single;

      final fixtureGroup =
          ((((exchange('changefeed', 'after-ckpt-42')['response']!
                              as Json)['body']!
                          as Json)['groups']!
                      as List)
                  .single
              as Json);
      // The fixture's cites Link is owned by its source; here it is not, so
      // the source's owned-Link `updated` fact (ordinal 4) has no
      // counterpart and every other fact keeps its relative order.
      final expected = (fixtureGroup['events']! as List)
          .cast<Json>()
          .where((e) => !((e['data']! as Json).containsKey('ownedLink')))
          .toList();
      final actual = (group['events']! as List).cast<Json>();
      expect(actual, hasLength(expected.length));
      expect(group['eventCount'], actual.length);
      expect(group['transaction'], receipt.json['transaction']);
      expect(group['position'], receipt.json['effectPosition']);
      expect(group['previousPosition'], 'p1');

      final linkId = (receipt.results[1]['resource']! as Json)['id'];
      String mapped(Object? uri) =>
          uri == 'https://beads.example/acme/links/9c1e'
          ? linkId! as String
          : uri! as String;
      for (var i = 0; i < actual.length; i++) {
        final a = actual[i];
        final e = expected[i];
        expect(a['ordinal'], i);
        expect(a['id'], '${group['checkpoint']}_$i');
        expect(a['type'], e['type']);
        expect(a['source'], e['source']);
        expect(a['subject'], mapped(e['subject']));
        expect(a['subjectType'], e['subjectType']);
        expect(a['transaction'], group['transaction']);
        expect(a['time'], '2026-09-07T18:04:12Z');
        final ad = a['data']! as Json;
        final ed = e['data']! as Json;
        expect(
          ad.keys.toSet(),
          ed.keys.toSet(),
          reason: 'event $i data members',
        );
        for (final key in [
          'properties',
          'attribution',
          'source',
          'target',
          'endpoint',
          'change',
        ]) {
          if (ed.containsKey(key)) {
            expect(ad[key], ed[key], reason: 'event $i $key');
          }
        }
        if (ed['link'] case final Json link) {
          expect(ad['link'], {'id': mapped(link['id']), 'type': link['type']});
        }
      }
      final updated = actual.last['data']! as Json;
      expect(updated['previousRevision'], task['revision']);
      expect(
        updated['revision'],
        (receipt.results[2]['resource']! as Json)['revision'],
      );

      final changes = (group['changes']! as List).cast<Json>();
      final fixtureChanges = (fixtureGroup['changes']! as List).cast<Json>();
      expect(
        changes.map((c) => c['operation']),
        fixtureChanges.map((c) => c['operation']),
      );
      expect(
        changes.map((c) => c['resourceKind']),
        fixtureChanges.map((c) => c['resourceKind']),
      );
      for (var i = 0; i < changes.length; i++) {
        final resource = changes[i]['resource']! as Json;
        final fixtureResource = fixtureChanges[i]['resource']! as Json;
        expect(resource['properties'], fixtureResource['properties']);
        expect(resource['id'], mapped(fixtureResource['id']));
      }
    });

    test('a deletion yields a tombstone with the final live revision', () {
      final task = createTask(authority, 'beads/task-42');
      authority.deleteBeadJson({'bead': 'beads/task-42'}, idempotencyKey: 'k1');
      final group = groupsOf(authority.changePage(after: 'genesis')).last;
      expectSchema(group, 'changeGroup');
      expect(group['changes'], [
        {
          'operation': 'tombstone',
          'resourceKind': 'bead',
          'resource': {
            'id': task['id'],
            'type': taskType,
            'revision': task['revision'],
          },
        },
      ]);
    });
  });

  group('finite changefeed', () {
    test('requires exactly one starting intent', () {
      expect(
        () => authority.changePage(),
        throwsA(
          isA<AuthorityProblem>().having(
            (p) => p.code,
            'code',
            'invalid-parameter',
          ),
        ),
      );
      expect(
        () => authority.changePage(after: 'genesis', startNow: true),
        throwsA(
          isA<AuthorityProblem>().having(
            (p) => p.code,
            'code',
            'invalid-parameter',
          ),
        ),
      );
    });

    test(
      'start=now anchors at the head; unknown checkpoints fail explicitly',
      () {
        createTask(authority, 'beads/a');
        final now = authority.changePage(startNow: true).body;
        expect(now['groups'], isEmpty);
        expect(now['observedHeadPosition'], 'p1');
        expect(
          authority.changePage(after: now['after']! as String).body['groups'],
          isEmpty,
        );
        for (final bad in ['nope', '${authority.epoch}_9', 'otherepoch_1']) {
          expect(
            () => authority.changePage(after: bad),
            throwsA(
              isA<AuthorityProblem>().having(
                (p) => p.code,
                'code',
                'cursor-expired',
              ),
            ),
          );
        }
      },
    );

    test('pages never split a group and continue through next', () {
      for (var i = 0; i < 5; i++) {
        createTask(authority, 'beads/t$i');
      }
      final first = authority.changePage(after: 'genesis', limit: 2).body;
      expect((first['groups']! as List), hasLength(2));
      final next = Uri.parse(
        first['next']! as String,
      ).queryParameters['after']!;
      final second = authority.changePage(after: next, limit: 10).body;
      expect((second['groups']! as List).map((g) => (g as Json)['position']), [
        'p3',
        'p4',
        'p5',
      ]);
      expect(second['next'], isNull);
    });
  });

  group('catch-up reproduces state byte for byte', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('bdp-fold-'));
    tearDown(() => dir.deleteSync(recursive: true));

    void workload(ScopeAuthority a, int round) {
      final t1 = createTask(a, 'beads/r$round-a', title: 'first $round');
      createTask(a, 'beads/r$round-b');
      a.batchJson([
        {
          'name': 'd',
          'operation': 'createBead',
          'type': decisionType,
          'properties': {'n': round, 'x': 1.5},
        },
        {
          'operation': 'createLink',
          'type': citesType,
          'source': '@d',
          'target': 'beads/r$round-a',
        },
        {
          'operation': 'updateBeadProperties',
          'bead': 'beads/r$round-a',
          'expectedRevision': t1['revision'],
          'change': [
            {
              'op': 'add',
              'path': '/tags',
              'value': ['a', 'b'],
            },
          ],
        },
      ], idempotencyKey: 'batch-$round');
      final link = a.createLinkJson({
        'type': blocksType,
        'source': 'beads/r$round-b',
        'target': {'uri': 'beads/r$round-a', 'revision': 'pin'},
      }, idempotencyKey: 'link-$round');
      a.deleteLinkJson({
        'link': (link.results.single['resource']! as Json)['id'],
      }, idempotencyKey: 'unlink-$round');
      a.deleteBeadJson({
        'bead': 'beads/r$round-b',
      }, idempotencyKey: 'delete-$round');
    }

    /// A consumer's replica: a fresh SQLite database holding each live
    /// record's JSON text by id, written only by folding change groups.
    Database replica(String path) => sqlite3.open(path)
      ..execute(
        'CREATE TABLE beads (id TEXT PRIMARY KEY, record TEXT NOT NULL);'
        'CREATE TABLE links (id TEXT PRIMARY KEY, record TEXT NOT NULL);',
      );

    /// Folds change groups into [replica], as a consumer applies them.
    void fold(Database replica, List<Json> groups) {
      for (final group in groups) {
        for (final change in (group['changes']! as List).cast<Json>()) {
          final table = change['resourceKind'] == 'bead' ? 'beads' : 'links';
          final resource = change['resource']! as Json;
          if (change['operation'] == 'upsert') {
            replica.execute(
              'INSERT OR REPLACE INTO $table (id, record) VALUES (?, ?)',
              [resource['id'], jsonEncode(resource)],
            );
          } else {
            replica.execute('DELETE FROM $table WHERE id = ?', [
              resource['id'],
            ]);
          }
        }
      }
    }

    /// Every live (id, record text) pair of the database at [path].
    List<List<Object?>> dump(String path) {
      final db = sqlite3.open(path);
      try {
        return [
          for (final table in ['beads', 'links'])
            for (final row in db.select(
              'SELECT id, record FROM $table ORDER BY id',
            ))
              row.values,
        ];
      } finally {
        db.close();
      }
    }

    test('from genesis and from a mid-history checkpoint', () {
      final primaryPath = '${dir.path}/primary.db';
      final primary = ScopeAuthority.file(
        primaryPath,
        scope: scope,
        clock: clock.call,
      );
      installWorkTypes(primary);
      workload(primary, 1);

      // Replica A replays from genesis through JSON text, as over HTTP.
      final fromGenesis = replica('${dir.path}/a.db');
      List<Json> overWire(AuthorityRead page) =>
          ((jsonDecode(jsonEncode(page.body)) as Json)['groups']! as List)
              .cast<Json>();
      final genesisGroups = overWire(primary.changePage(after: 'genesis'));
      fold(fromGenesis, genesisGroups);

      // Replica B takes the first two groups, then resumes later.
      final fromCheckpoint = replica('${dir.path}/b.db');
      final early = primary.changePage(after: 'genesis', limit: 2).body;
      fold(fromCheckpoint, (early['groups']! as List).cast<Json>());
      final checkpoint =
          (early['groups']! as List).cast<Json>().last['checkpoint']! as String;

      workload(primary, 2);
      fold(
        fromGenesis,
        overWire(
          primary.changePage(
            after: genesisGroups.last['checkpoint']! as String,
          ),
        ),
      );
      var cursor = checkpoint;
      while (true) {
        final page = primary.changePage(after: cursor, limit: 3).body;
        final groups = (page['groups']! as List).cast<Json>();
        fold(fromCheckpoint, groups);
        if (page['next'] == null) break;
        cursor = groups.last['checkpoint']! as String;
      }

      final expected = dump(primaryPath);
      expect(expected, isNotEmpty);
      expect(dump('${dir.path}/a.db'), expected);
      expect(dump('${dir.path}/b.db'), expected);
      primary.close();
      fromGenesis.close();
      fromCheckpoint.close();
    });
  });

  group('epoch-qualified continuations', () {
    final expired = throwsA(
      isA<AuthorityProblem>().having((p) => p.code, 'code', 'cursor-expired'),
    );

    test('an empty Scope\'s snapshot and start=now checkpoints name their '
        'epoch and expire with it', () {
      final snapshot = authority.snapshotDocument().body;
      final checkpoint = snapshot['checkpoint']! as String;
      expect(checkpoint, isNot('genesis'));
      expectSchema(snapshot, 'snapshotManifest');
      final now = authority.changePage(startNow: true).body['after']! as String;
      expect(now, checkpoint);
      expect(groupsOf(authority.changePage(after: checkpoint)), isEmpty);
      authority.reinitialize();
      expect(() => authority.changePage(after: checkpoint), expired);
      expect(
        authority.watch(after: checkpoint).first,
        throwsA(
          isA<AuthorityProblem>().having(
            (p) => p.code,
            'code',
            'cursor-expired',
          ),
        ),
      );
      // genesis asks for the current epoch's whole history and names none.
      expect(groupsOf(authority.changePage(after: 'genesis')), isEmpty);
    });

    test('a collection cursor does not survive an epoch change at the same '
        'head', () {
      for (final id in ['a', 'b', 'c']) {
        createTask(authority, 'beads/$id');
      }
      String cursorOf(AuthorityRead page) =>
          Uri.parse(page.body['next']! as String).queryParameters['cursor']!;
      final beads = cursorOf(
        authority.collection(AuthorityResourceKind.bead, limit: 1),
      );
      authority.reinitialize();
      for (final id in ['x', 'y', 'z']) {
        createTask(authority, 'beads/$id');
      }
      expect(
        () => authority.collection(
          AuthorityResourceKind.bead,
          limit: 1,
          cursor: beads,
        ),
        expired,
      );
      // The same cursor in this epoch still continues.
      final fresh = cursorOf(
        authority.collection(AuthorityResourceKind.bead, limit: 1),
      );
      expect(
        authority
            .collection(AuthorityResourceKind.bead, limit: 1, cursor: fresh)
            .body['items'],
        [isA<Json>().having((b) => b['id'], 'id', '${scope}beads/y')],
      );
    });

    test('a Type inventory cursor does not survive an epoch change, though '
        'the Types do', () {
      String cursorOf(AuthorityRead page) =>
          Uri.parse(page.body['next']! as String).queryParameters['cursor']!;
      final types = cursorOf(authority.typeInventory(limit: 1));
      // The same cursor continues in its own epoch.
      expect(
        authority.typeInventory(limit: 1, cursor: types).body['items'],
        hasLength(1),
      );
      authority.reinitialize();
      expect(() => authority.typeInventory(limit: 1, cursor: types), expired);
      expect(authority.typeInventory().body['items'], hasLength(4));
      // A cursor from one collection does not continue another.
      final beads = authority.typeInventory(limit: 1);
      expect(
        () => authority.collection(
          AuthorityResourceKind.bead,
          cursor: cursorOf(beads),
        ),
        expired,
      );
    });
  });

  group('live delivery', () {
    test(
      'watch joins the backlog and the live tail without gap or duplicate',
      () async {
        createTask(authority, 'beads/a');
        createTask(authority, 'beads/b');
        final seen = <String>[];
        final done = Completer<void>();
        final subscription = authority.watch(after: 'genesis').listen((g) {
          seen.add(g['position']! as String);
          if (seen.length == 4) done.complete();
        });
        createTask(authority, 'beads/c');
        createTask(authority, 'beads/d');
        await done.future.timeout(const Duration(seconds: 5));
        await subscription.cancel();
        expect(seen, ['p1', 'p2', 'p3', 'p4']);
      },
    );

    test(
      'watch from now sees only later groups; reinitialize ends it',
      () async {
        createTask(authority, 'beads/a');
        final events = <Object>[];
        final finished = Completer<void>();
        authority.watch().listen(
          events.add,
          onError: events.add,
          onDone: finished.complete,
        );
        createTask(authority, 'beads/b');
        authority.reinitialize();
        await finished.future.timeout(const Duration(seconds: 5));
        expect(events, hasLength(2));
        expect((events.first as Json)['position'], 'p2');
        expect(
          events.last,
          isA<AuthorityProblem>().having(
            (p) => p.code,
            'code',
            'cursor-expired',
          ),
        );
      },
    );
  });

  group('Event Sources', () {
    test('the Scope source and a Bead source keep group ordinals', () {
      final task = createTask(authority, 'beads/task-42');
      final receipt = authority.batchJson(
        firstBatch(task['revision']! as String),
        idempotencyKey: 'k',
      );
      final scopeEvents = authority.events().body;
      expectSchema(scopeEvents, 'eventPage');
      expect((scopeEvents['events']! as List), hasLength(6));

      final decision = authority.events(resource: 'beads/dec-9').body;
      expectSchema(decision, 'eventPage');
      expect(decision['source'], '${scope}beads/dec-9?view=events');
      final fixtureEvents =
          (((exchange('events', 'dec-9-after-owned-link-created')['response']!
                          as Json)['body']!
                      as Json)['events']!
                  as List)
              .cast<Json>()
              .where((e) => !((e['data']! as Json).containsKey('ownedLink')));
      final events = (decision['events']! as List).cast<Json>();
      expect(events.map((e) => e['type']), fixtureEvents.map((e) => e['type']));
      expect(
        events.map((e) => e['ordinal']),
        fixtureEvents.map((e) => e['ordinal']),
      );
      expect(events.every((e) => e['source'] == decision['source']), isTrue);

      final taskEvents =
          (authority.events(resource: task['id']! as String).body['events']!
                  as List)
              .cast<Json>();
      expect(taskEvents.map((e) => e['type']), [
        'created',
        'linked',
        'updated',
      ]);
      expect((taskEvents[1]['data']! as Json)['endpoint'], 'target');

      final linkId = (receipt.results[1]['resource']! as Json)['id']! as String;
      final linkEvents =
          (authority.events(resource: linkId).body['events']! as List)
              .cast<Json>();
      expect(linkEvents.map((e) => e['type']), ['created']);
    });

    test('pages continue after the last returned Event', () {
      for (var i = 0; i < 3; i++) {
        createTask(authority, 'beads/t$i');
      }
      final first = authority.events(limit: 2).body;
      final after = Uri.parse(
        first['next']! as String,
      ).queryParameters['after'];
      final rest = authority.events(after: after).body;
      expect(
        (rest['events']! as List).single,
        containsPair('subject', '${scope}beads/t2'),
      );
      expect(rest['next'], isNull);
      expect(
        () => authority.events(resource: 'beads/never'),
        throwsA(isA<AuthorityProblem>()),
      );
    });
  });

  group('snapshots', () {
    test(
      'a manifest anchors both streams at one position and refetches unchanged',
      () {
        final task = createTask(authority, 'beads/task-42');
        authority.batchJson(
          firstBatch(task['revision']! as String),
          idempotencyKey: 'k',
        );
        final manifest = authority.snapshotDocument().body;
        expectSchema(manifest, 'snapshotManifest');
        expect(manifest['scopePosition'], 'p2');
        expect((manifest['beads']! as Json)['items'], hasLength(2));
        expect((manifest['links']! as Json)['items'], hasLength(1));

        createTask(authority, 'beads/later');
        authority.deleteLinkJson({
          'link': ((manifest['links']! as Json)['items']! as List)
              .cast<Json>()
              .single['id'],
        }, idempotencyKey: 'k2');
        final token = Uri.parse(
          manifest['id']! as String,
        ).queryParameters['snapshot']!;
        expect(authority.snapshotHandle(token).body, manifest);

        // The checkpoint resumes the changefeed exactly after the anchor.
        final resumed = groupsOf(
          authority.changePage(after: manifest['checkpoint']! as String),
        );
        expect(resumed.map((g) => g['position']), ['p3', 'p4']);

        clock.now = clock.now.add(const Duration(minutes: 6));
        expect(
          () => authority.snapshotHandle(token),
          throwsA(
            isA<AuthorityProblem>().having(
              (p) => p.code,
              'code',
              'cursor-expired',
            ),
          ),
        );
      },
    );
  });
}
