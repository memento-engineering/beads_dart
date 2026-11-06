// The bd authority over a bd that answers from memory: no bd runs, so every
// read, refusal and argv here holds on a host without bd.
import 'dart:convert';

import 'package:bdp/bd.dart';
import 'package:bdp/bdp.dart';
import 'package:bdp/src/authority/bd/bd_rows.dart';
import 'package:test/test.dart';

import '../support/fake_bd.dart';
import '../support/scope.dart';

/// An authority over [bd] that reads only when a test asks it to.
Future<BdScopeAuthority> _open(
  FakeBd bd, {
  int changes = 65536,
  Duration interval = const Duration(hours: 1),
  Duration within = const Duration(seconds: 10),
  TestClock? clock,
}) => BdScopeAuthority.open(
  bd: bd,
  scope: scope,
  interval: interval,
  within: within,
  changes: changes,
  clock: (clock ?? TestClock()).call,
);

String _bead(String id) => '${scope}beads/$id';

TypeMatcher<AuthorityProblem> _problem(String code) =>
    isA<AuthorityProblem>().having((problem) => problem.code, 'code', code);

/// The change groups committed after [checkpoint].
List<Json> _groupsAfter(BdScopeAuthority authority, String checkpoint) =>
    groupsOf(authority.changePage(after: checkpoint));

String _head(BdScopeAuthority authority) =>
    authority.changePage(startNow: true).body['after']! as String;

void main() {
  group('bd explains a failure', () {
    test('from the envelope on stdout first, then one on stderr, then '
        'stderr text, then stdout text', () {
      expect(
        bdExplain(
          BdOutput(
            exitCode: 1,
            stdout: jsonEncode({
              'error': '1 of 1 issues failed to update',
              'failed': [
                {'id': 't-1', 'error': 'issue not found'},
              ],
            }),
            stderr: 'noise',
          ),
        ),
        '1 of 1 issues failed to update: issue not found',
      );
      expect(
        bdExplain(
          BdOutput(
            exitCode: 1,
            stdout: 'plain',
            stderr: 'Issue t-1 not found\n${jsonEncode({'error': 'boom'})}',
          ),
        ),
        'boom',
      );
      expect(
        bdExplain(const BdOutput(exitCode: 1, stdout: 'out', stderr: ' err ')),
        'err',
      );
      expect(bdExplain(const BdOutput(exitCode: 1, stdout: ' out ')), 'out');
      expect(
        bdExplain(const BdOutput(exitCode: 3)),
        'bd exited 3 and printed nothing',
      );
    });

    test('an argument holding NUL is refused before anything runs', () {
      final cli = BdProcessCli(
        executable: '/nonexistent/bd',
        workspace: '/nonexistent',
        actor: 'test',
      );
      expect(
        () => cli.run(['update', '--notes=a\u0000b', '--', 't-1']),
        throwsArgumentError,
      );
    });

    test('the process environment holds the store, the actor and the '
        'allowlist, and nothing else', () {
      final cli = BdProcessCli(
        executable: 'bd',
        workspace: '/store',
        actor: 'someone',
      );
      expect(cli.environment['BEADS_DIR'], '/store/.beads');
      expect(cli.environment['BEADS_ACTOR'], 'someone');
      expect(cli.environment['BD_NON_INTERACTIVE'], '1');
      expect(
        cli.environment.keys.toSet().difference({
          ...BdProcessCli.environmentAllowlist,
          'BEADS_DIR',
          'BEADS_ACTOR',
          'BD_NON_INTERACTIVE',
          'NO_COLOR',
        }),
        isEmpty,
      );
    });
  });

  group('a read is projected', () {
    test('a field bd omits when empty is carried only when some row of the '
        'same read holds a value for it', () {
      final read = projectBdRows([
        {'id': 't-1', 'title': 'one', 'notes': 'kept', 'dependency_count': 0},
        {'id': 't-2', 'title': 'two'},
      ]);
      expect(read.beads['t-2']!['notes'], '');
      expect(read.beads['t-2']!.containsKey('description'), isFalse);
      expect(read.beads['t-2']!.containsKey('metadata'), isFalse);
      final evidenced = projectBdRows([
        {
          'id': 't-1',
          'metadata': {'k': 1},
        },
        {'id': 't-2'},
      ]);
      expect(evidenced.beads['t-2']!['metadata'], isEmpty);
    });

    test('dependencies are carried as none only when bd counts none, and '
        'each one is a dependency of its holder', () {
      final read = projectBdRows([
        {'id': 't-1', 'dependency_count': 0},
        {'id': 't-2', 'dependency_count': 2},
        {
          'id': 't-3',
          'dependencies': [
            {'issue_id': 't-3', 'depends_on_id': 't-1', 'type': 'blocks'},
          ],
        },
      ]);
      expect(read.beads['t-1']!['dependencies'], isEmpty);
      expect(read.beads['t-2']!.containsKey('dependencies'), isFalse);
      expect(read.beads['t-3']!['dependencies'], [
        {'depends_on_id': 't-1', 'type': 'blocks'},
      ]);
      expect(read.dependencies, [
        (holder: 't-3', type: 'blocks', target: 't-1'),
      ]);
    });

    test('a row that is no object or names no bead refuses the whole read, '
        'naming its index', () {
      expect(
        () => projectBdRows([
          {'id': 't-1'},
          {'title': 'nameless'},
        ]),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'bd list row 1 names no bead',
          ),
        ),
      );
      expect(() => projectBdRows(['t-1']), throwsFormatException);
    });
  });

  group('the bd authority reads', () {
    late FakeBd bd;
    late BdScopeAuthority authority;

    setUp(() async {
      bd = FakeBd()
        ..add('t-1', title: 'first')
        ..add(
          't-2',
          title: 'second',
          also: {
            'dependency_count': 1,
            'dependencies': [
              {'issue_id': 't-2', 'depends_on_id': 't-1', 'type': 'blocks'},
              {
                'issue_id': 't-2',
                'depends_on_id': 'external:proj:cap',
                'type': 'related',
              },
            ],
          },
        );
      authority = await _open(bd);
    });

    tearDown(() => authority.close());

    test('reads the store only by whole lists, and never runs bd version', () {
      expect(bd.calls, isNotEmpty);
      expect(bd.calls, everyElement(bdListArguments));
      expect(bd.calls.where((call) => call.first == 'version'), isEmpty);
    });

    test('opens and serves the store over a bd whose version fails', () async {
      final versionless = FakeBd()
        ..add('t-1', title: 'first')
        ..intercept = (arguments) => arguments.first == 'version'
            ? const BdOutput(
                exitCode: 1,
                stdout: '{"error": "no version here"}',
              )
            : null;
      final served = await _open(versionless);
      addTearDown(served.close);
      final properties =
          served.resource(_bead('t-1')).body['properties']! as Json;
      expect(properties['title'], 'first');
      expect(
        versionless.calls.where((call) => call.first == 'version'),
        isEmpty,
      );
    });

    test('serves each bead under the bead Type, its issue type a property, '
        'and each dependency as a Link', () {
      final record = authority.resource(_bead('t-2')).body;
      expect(record['type'], '${scope}types/bead');
      expect((record['properties']! as Json)['issue_type'], 'task');
      final links =
          authority.collection(AuthorityResourceKind.link).body['items']!
              as List<Object?>;
      expect(links.cast<Json>().map((link) => link['target']), [
        _bead('t-1'),
        'urn:bd:external%3Aproj%3Acap',
      ]);
      expect((links.first! as Json)['id'], '${scope}links/t-2/blocks/t-1');
      expect(
        (authority.typeInventory().body['items']! as List<Object?>)
            .cast<Json>()
            .map((type) => type['id']),
        containsAll([
          '${scope}types/bead',
          '${scope}types/dependency/blocks',
          '${scope}types/dependency/related',
        ]),
      );
    });

    test('discovery validates as Transactional and advertises one '
        'operation per transaction', () {
      final discovery = authority.discoveryDocument().body;
      expectSchema(discovery, 'transactionalDiscovery');
      final limits = discovery['limits']! as Json;
      expect(limits['transaction'], {'operations': 1});
      expect(limits['page'], {'defaultItems': 50, 'maximumItems': 200});
    });

    test('keeps a snapshot\'s handle for the lifetime it was opened with, '
        'and advertises it', () async {
      Object? lifetimeOf(BdScopeAuthority opened) =>
          ((opened.discoveryDocument().body['limits']! as Json)['retention']!
              as Json)['maximumSnapshotLifetime'];
      final brief = await BdScopeAuthority.open(
        bd: bd,
        scope: scope,
        interval: const Duration(hours: 1),
        snapshotLifetime: const Duration(seconds: 1),
      );
      addTearDown(brief.close);
      expect(lifetimeOf(brief), 'PT1S');
      expect(lifetimeOf(authority), 'PT300S');
    });

    test('an edit between polls arrives as exactly one change group, and an '
        'unchanged poll commits none', () async {
      final mark = _head(authority);
      await authority.refresh();
      expect(_groupsAfter(authority, mark), isEmpty);
      bd.row('t-1')['title'] = 'edited';
      bd.add('t-3');
      await authority.refresh();
      final groups = _groupsAfter(authority, mark);
      expect(groups, hasLength(1));
      expect(
        (groups.single['changes']! as List<Object?>).cast<Json>().map(
          (change) => (change['resource']! as Json)['id'],
        ),
        unorderedEquals([_bead('t-1'), _bead('t-3')]),
      );
      await authority.refresh();
      expect(_groupsAfter(authority, mark), hasLength(1));
    });

    test('a group is dated by the instant its read returned', () async {
      final clock = TestClock();
      final dated = await _open(bd, clock: clock);
      addTearDown(dated.close);
      final mark = _head(dated);
      clock.now = DateTime.utc(2026, 10, 26, 9, 30);
      bd.row('t-1')['title'] = 'later';
      await dated.refresh();
      final group = _groupsAfter(dated, mark).single;
      expect(
        (group['events']! as List<Object?>).cast<Json>().first['time'],
        '2026-10-26T09:30:00Z',
      );
    });

    test('a bead that leaves a read is tombstoned, and withheld if bd '
        'serves its id again', () async {
      final row = bd.row('t-1');
      bd.rows.remove(row);
      bd.row('t-2')
        ..remove('dependencies')
        ..['dependency_count'] = 0;
      await authority.refresh();
      expect(
        () => authority.resource(_bead('t-1')),
        throwsA(_problem('resource-not-found')),
      );
      bd.rows.add(row);
      await authority.refresh();
      expect(
        () => authority.resource(_bead('t-1')),
        throwsA(_problem('resource-not-found')),
      );
      expect(authority.resource(_bead('t-2')).body, isNotNull);
    });

    for (final (name, refuse) in <(String, void Function(FakeBd))>[
      (
        'a bd list that fails',
        (bd) => bd.intercept = (arguments) => arguments.first == 'list'
            ? BdOutput(exitCode: 1, stdout: jsonEncode({'error': 'down'}))
            : null,
      ),
      ('a row naming no bead', (bd) => bd.rows.add({'title': 'nameless'})),
      (
        'more changes than the bound',
        (bd) {
          for (var i = 0; i < 7; i++) {
            bd.add('t-9$i');
          }
        },
      ),
    ]) {
      test('$name applies nothing, and every Resource, collection, '
          'incident-link, snapshot, Event Source and changefeed read is '
          'temporarily unavailable until the next whole read', () async {
        final bounded = await _open(bd, changes: 6);
        addTearDown(bounded.close);
        final mark = _head(bounded);
        final before = bounded.resource(_bead('t-1')).body;
        refuse(bd);
        bd.row('t-1')['title'] = 'unseen';
        await bounded.refresh();
        final reads = <Object? Function()>[
          () => bounded.resource(_bead('t-1')),
          () => bounded.collection(AuthorityResourceKind.bead),
          () => bounded.incidentLinkPage(_bead('t-1')),
          () => bounded.snapshotDocument(),
          () => bounded.events(),
          () => bounded.events(resource: _bead('t-1')),
          () => bounded.changePage(after: mark),
        ];
        for (final read in reads) {
          expect(read, throwsA(_problem('temporarily-unavailable')));
        }
        await expectLater(
          bounded.readBead(_bead('t-1')),
          throwsA(
            isA<BdpProblemException>().having(
              (e) => e.problem.code,
              'code',
              'temporarily-unavailable',
            ),
          ),
        );
        expect(bounded.discoveryDocument().body, isNotNull);
        expect(bounded.typeInventory().body, isNotNull);
        bd
          ..intercept = null
          ..rows.removeWhere((row) => row['id'] == null)
          ..rows.removeWhere((row) => (row['id']! as String).startsWith('t-9'));
        bd.row('t-1')['title'] = 'first';
        await bounded.refresh();
        expect(bounded.resource(_bead('t-1')).body, before);
        expect(_groupsAfter(bounded, mark), isEmpty);
      });
    }

    test('an empty list is an empty Scope only when the control query '
        'returns rows', () async {
      final empty = FakeBd();
      final served = await _open(empty);
      addTearDown(served.close);
      expect(
        served.collection(AuthorityResourceKind.bead).body['items'],
        isEmpty,
      );
      expect(empty.calls.last, bdControlArguments);
      final unread = FakeBd()..config = {};
      final refused = await _open(unread);
      addTearDown(refused.close);
      expect(
        () => refused.collection(AuthorityResourceKind.bead),
        throwsA(_problem('temporarily-unavailable')),
      );
    });

    test('a live follow stays open while a read is refused and delivers '
        'the next whole read', () async {
      final groups = <ChangeGroup>[];
      final follow = authority.follow(
        ChangefeedStart.now(),
        (group) async => groups.add(group),
      );
      addTearDown(follow.cancel);
      bd.intercept = (arguments) =>
          arguments.first == 'list' ? const BdOutput(exitCode: 1) : null;
      await authority.refresh();
      bd
        ..intercept = null
        ..row('t-1')['title'] = 'after';
      await authority.refresh();
      await pumpEventQueue();
      expect(groups, hasLength(1));
    });
  });

  group('the bd authority writes', () {
    late FakeBd bd;
    late BdScopeAuthority authority;

    setUp(() async {
      bd = FakeBd()
        ..add(
          't-1',
          title: 'first',
          also: {
            'notes': 'theirs',
            'metadata': {'other': 'kept'},
          },
        );
      authority = await _open(bd);
    });

    tearDown(() => authority.close());

    Future<AuthorityReceipt> update(
      List<Json> change, {
      String key = 'k1',
      String? expectedRevision,
      String bead = 't-1',
    }) => authority.mutate('update-bead-properties', {
      'bead': _bead(bead),
      'change': change,
      'expectedRevision': ?expectedRevision,
    }, idempotencyKey: key);

    test(
      'a metadata change merges per key and a notes change appends, in '
      'one update, a flag value joined to its flag and the id after --',
      () async {
        final receipt = await update([
          {'op': 'add', 'path': '/metadata/mine', 'value': 'v'},
          {'op': 'add', 'path': '/metadata/count', 'value': 3},
          {'op': 'replace', 'path': '/notes', 'value': 'theirs\nmine'},
        ]);
        expect(receipt.status, 'completed', reason: '${receipt.json}');
        expectSchema(receipt.json, 'mutationReceipt');
        expect(bd.writes, [
          [
            'update',
            '--set-metadata=count=3',
            '--set-metadata=mine=v',
            '--append-notes=mine',
            '--json',
            '--',
            't-1',
          ],
        ]);
        expect(bd.row('t-1')['metadata'], {
          'other': 'kept',
          'mine': 'v',
          'count': 3,
        });
        final result = receipt.results.single;
        expect(result['outcome'], 'updated');
        expect(
          (result['resource']! as Json)['revision'],
          authority.resource(_bead('t-1')).body['revision'],
        );
        expect(receipt.json['effectPosition'], isNotNull);
      },
    );

    test('a removed metadata key is unset, and a status change goes through '
        'bd close or bd update --status', () async {
      await update([
        {'op': 'remove', 'path': '/metadata/other'},
        {'op': 'replace', 'path': '/status', 'value': 'in_progress'},
      ]);
      await update([
        {'op': 'replace', 'path': '/status', 'value': 'closed'},
        {'op': 'add', 'path': '/close_reason', 'value': 'done'},
      ], key: 'k2');
      expect(bd.writes, [
        ['update', '--unset-metadata=other', '--json', '--', 't-1'],
        ['update', '--status=in_progress', '--json', '--', 't-1'],
        ['close', '--reason=done', '--json', '--', 't-1'],
      ]);
      expect(bd.row('t-1')['status'], 'closed');
    });

    for (final (name, change) in <(String, List<Json>)>[
      (
        'a notes change that does not extend the notes',
        [
          {'op': 'replace', 'path': '/notes', 'value': 'mine'},
        ],
      ),
      (
        'a change of the whole metadata map',
        [
          {
            'op': 'replace',
            'path': '/metadata',
            'value': {'mine': 'v'},
          },
        ],
      ),
      (
        'a removal of the metadata map',
        [
          {'op': 'remove', 'path': '/metadata'},
        ],
      ),
      (
        'a change of the whole properties',
        [
          {
            'op': 'replace',
            'path': '',
            'value': {'title': 'x'},
          },
        ],
      ),
      (
        'a whole free-text field',
        [
          {'op': 'replace', 'path': '/description', 'value': 'replaced'},
        ],
      ),
      (
        'a property bd has no write verb for',
        [
          {'op': 'replace', 'path': '/updated_at', 'value': 'now'},
        ],
      ),
      (
        'a metadata text bd would read as a number',
        [
          {'op': 'add', 'path': '/metadata/n', 'value': '5'},
        ],
      ),
      (
        'a metadata key holding =',
        [
          {'op': 'add', 'path': '/metadata/a=b', 'value': 'v'},
        ],
      ),
      (
        'an argument holding NUL',
        [
          {'op': 'add', 'path': '/metadata/k', 'value': 'a\u0000b'},
        ],
      ),
    ]) {
      test('$name answers a failed receipt with validation-failed before any '
          'bd write', () async {
        final receipt = await update(change);
        expect(receipt.status, 'failed');
        expect(receipt.problem!['code'], 'validation-failed');
        expectSchema(receipt.json, 'mutationReceipt');
        expect(bd.writes, isEmpty);
      });
    }

    test('a stale expectedRevision is revision-mismatch, and a missing bead '
        'resource-not-found, before any bd write', () async {
      final stale = await update([
        {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
      ], expectedRevision: 'stale');
      expect(stale.problem!['code'], 'revision-mismatch');
      expect(stale.problem!['pointer'], '/expectedRevision');
      final missing = await authority.mutate('update-bead-properties', {
        'bead': _bead('t-404'),
        'change': [
          {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
        ],
      }, idempotencyKey: 'k2');
      expect(missing.problem!['code'], 'resource-not-found');
      expect(bd.writes, isEmpty);
    });

    test('an update whose patch changes nothing makes no bd call and carries '
        'no effectPosition', () async {
      final receipt = await update([
        {'op': 'replace', 'path': '/status', 'value': 'open'},
      ]);
      expect(receipt.status, 'completed');
      expect(receipt.json.containsKey('effectPosition'), isFalse);
      expect(bd.writes, isEmpty);
    });

    test('a metadata key a change names is merged by bd even when the read '
        'before already holds it', () async {
      final receipt = await update([
        {'op': 'add', 'path': '/metadata/other', 'value': 'kept'},
      ]);
      expect(receipt.status, 'completed', reason: '${receipt.json}');
      expect(bd.writes, [
        ['update', '--set-metadata=other=kept', '--json', '--', 't-1'],
      ]);
    });

    /// The revision the authority serves [id] at now.
    String revisionOf(String id) =>
        authority.resource(_bead(id)).body['revision']! as String;

    test(
      'the guarded text update is one bd update naming description, '
      'design and acceptance in that order, all three even when one is '
      'unchanged, at an expected revision, confirmed by whole reads',
      () async {
        bd.row('t-1')['design'] = 'kept design';
        await authority.refresh();
        final receipt = await update([
          {'op': 'add', 'path': '/acceptance_criteria', 'value': 'AC1: holds.'},
          {'op': 'replace', 'path': '/design', 'value': 'kept design'},
          {'op': 'add', 'path': '/description', 'value': 'decided'},
        ], expectedRevision: revisionOf('t-1'));
        expect(receipt.status, 'completed', reason: '${receipt.json}');
        expectSchema(receipt.json, 'mutationReceipt');
        expect(bd.writes, [
          [
            'update',
            '--description=decided',
            '--design=kept design',
            '--acceptance=AC1: holds.',
            '--json',
            '--',
            't-1',
          ],
        ]);
        expect(bd.row('t-1'), containsPair('description', 'decided'));
        expect(bd.row('t-1'), containsPair('design', 'kept design'));
        expect(
          bd.row('t-1'),
          containsPair('acceptance_criteria', 'AC1: holds.'),
        );
        expect(bd.row('t-1'), containsPair('notes', 'theirs'));
        final served =
            authority.resource(_bead('t-1')).body['properties']! as Json;
        expect(served['description'], 'decided');
      },
    );

    const texts = [
      {'op': 'add', 'path': '/description', 'value': 'd'},
      {'op': 'add', 'path': '/design', 'value': 'g'},
      {'op': 'add', 'path': '/acceptance_criteria', 'value': 'a'},
    ];

    for (final (name, change, atRevision) in <(String, List<Json>, bool)>[
      ('the three texts with no expected revision', texts, false),
      (
        'the description alone',
        [
          {'op': 'replace', 'path': '/description', 'value': 'd'},
        ],
        true,
      ),
      ('two of the three', texts.take(2).toList(), true),
      (
        'the three beside a metadata key',
        [
          ...texts,
          {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
        ],
        true,
      ),
      (
        'the three beside the title',
        [
          ...texts,
          {'op': 'replace', 'path': '/title', 'value': 't'},
        ],
        true,
      ),
      (
        'the three beside the notes',
        [
          ...texts,
          {'op': 'replace', 'path': '/notes', 'value': 'theirs\nmine'},
        ],
        true,
      ),
      (
        'the title at a revision',
        [
          {'op': 'replace', 'path': '/title', 'value': 'retitled'},
        ],
        true,
      ),
      (
        'the title at no revision',
        [
          {'op': 'replace', 'path': '/title', 'value': 'retitled'},
        ],
        false,
      ),
      (
        'the three, one of them not a text',
        [
          texts[0],
          {'op': 'add', 'path': '/design', 'value': 3},
          texts[2],
        ],
        true,
      ),
      (
        'the three, one of them removed',
        [
          texts[0],
          {'op': 'remove', 'path': '/design'},
          texts[2],
        ],
        true,
      ),
    ]) {
      test('$name is a whole-text replace the guarded update is not, '
          'answered validation-failed before any bd write', () async {
        final receipt = await update(
          change,
          expectedRevision: atRevision ? revisionOf('t-1') : null,
        );
        expect(receipt.status, 'failed');
        expect(receipt.problem!['code'], 'validation-failed');
        expectSchema(receipt.json, 'mutationReceipt');
        expect(bd.writes, isEmpty);
      });
    }

    test('the guarded text update at a stale revision is revision-mismatch, '
        'and an edit another actor made after the client read the revision '
        'is kept', () async {
      final stale = await update(texts, expectedRevision: 'stale');
      expect(stale.problem!['code'], 'revision-mismatch');
      expect(stale.problem!['pointer'], '/expectedRevision');
      final observed = revisionOf('t-1');
      bd.row('t-1')['description'] = 'theirs';
      final moved = await update(texts, expectedRevision: observed, key: 'k2');
      expect(moved.problem!['code'], 'revision-mismatch');
      expect(moved.problem!['pointer'], '/expectedRevision');
      expectSchema(moved.json, 'mutationReceipt');
      expect(bd.writes, isEmpty);
      expect(bd.row('t-1')['description'], 'theirs');
    });

    test(
      'a close carrying no close_reason is bd update --status=closed',
      () async {
        final receipt = await update([
          {'op': 'replace', 'path': '/status', 'value': 'closed'},
        ]);
        expect(receipt.status, 'completed', reason: '${receipt.json}');
        expect(bd.writes, [
          ['update', '--status=closed', '--json', '--', 't-1'],
        ]);
        expect(bd.row('t-1')['status'], 'closed');
      },
    );

    test('a gate is closed through bd gate resolve, carrying its reason, and '
        'confirmed by its status alone', () async {
      bd.add(
        't-g',
        title: 'Gate',
        also: {'issue_type': 'gate', 'await_id': 'k'},
      );
      await authority.refresh();
      final receipt = await update([
        {'op': 'replace', 'path': '/status', 'value': 'closed'},
        {'op': 'add', 'path': '/close_reason', 'value': 'r'},
      ], bead: 't-g');
      expect(receipt.status, 'completed', reason: '${receipt.json}');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(bd.writes, [
        ['gate', 'resolve', '--reason=r', '--', 't-g'],
      ]);
      expect(bd.row('t-g')['status'], 'closed');
    });

    Future<AuthorityReceipt> openGate(Json properties, {String key = 'g1'}) =>
        authority.mutate('create-bead', {
          'type': '${scope}types/bead',
          'properties': properties,
        }, idempotencyKey: key);

    const gate = {
      'issue_type': 'gate',
      'await_id': 'https://station.test/execution/beads/a-1/gate',
      'blocks': 't-1',
      'reason': 'the breaker tripped',
    };

    test('a gate create is one bd gate create blocking the bead, its receipt '
        "naming the gate, and the bead's dependencies name it", () async {
      final receipt = await openGate(gate);
      expect(receipt.status, 'completed', reason: '${receipt.json}');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(bd.writes, [
        [
          'gate',
          'create',
          '--blocks=t-1',
          '--type=human',
          '--reason=the breaker tripped',
          '--await-id=${gate['await_id']}',
          '--json',
        ],
      ]);
      final result = receipt.results.single;
      expect(result['outcome'], 'created');
      expect((result['resource']! as Json)['id'], _bead('t-000'));
      expect(bd.row('t-1')['dependencies'], [
        {'issue_id': 't-1', 'depends_on_id': 't-000', 'type': 'blocks'},
      ]);
    });

    test('a gate create under a key bd holds a gate under, open or closed, '
        'runs no gate call and answers that gate', () async {
      await openGate(gate);
      final again = await openGate(gate, key: 'g2');
      expect(again.status, 'completed', reason: '${again.json}');
      expectSchema(again.json, 'mutationReceipt');
      expect((again.results.single['resource']! as Json)['id'], _bead('t-000'));
      bd.row('t-000')['status'] = 'closed';
      final closed = await openGate(gate, key: 'g3');
      expect(closed.status, 'completed', reason: '${closed.json}');
      expect(
        (closed.results.single['resource']! as Json)['id'],
        _bead('t-000'),
      );
      expect(bd.writes.where((call) => call.first == 'gate'), hasLength(1));
    });

    test('two gates under one key are identity-taken, and a bead the read '
        'does not serve is resource-not-found, before any bd write', () async {
      for (final id in ['t-g1', 't-g2']) {
        bd.add(id, also: {'issue_type': 'gate', 'await_id': gate['await_id']});
      }
      final taken = await openGate(gate);
      expect(taken.problem!['code'], 'identity-taken');
      expect(
        taken.problem!['detail'],
        allOf(contains('t-g1'), contains('t-g2')),
      );
      expectSchema(taken.json, 'mutationReceipt');
      final missing = await openGate({
        ...gate,
        'await_id': 'another key',
        'blocks': 't-404',
      }, key: 'g2');
      expect(missing.problem!['code'], 'resource-not-found');
      expect(missing.problem!['pointer'], '/properties/blocks');
      expectSchema(missing.json, 'mutationReceipt');
      expect(bd.writes, isEmpty);
    });

    for (final (name, properties) in <(String, Json)>[
      ('a gate create missing its key', {...gate}..remove('await_id')),
      ('a gate create missing the bead it blocks', {...gate}..remove('blocks')),
      ('a gate create missing its reason', {...gate}..remove('reason')),
      ('a gate create with an empty reason', {...gate, 'reason': ''}),
      ('a gate create carrying a title', {...gate, 'title': 'Gate'}),
      (
        'a gate create carrying metadata',
        {
          ...gate,
          'metadata': {'k': 'v'},
        },
      ),
      (
        'a create that is not a gate carrying blocks',
        {'title': 'not a gate', 'blocks': 't-1'},
      ),
      (
        'a create that is not a gate carrying a key',
        {'title': 'not a gate', 'await_id': 'k'},
      ),
    ]) {
      test('$name is validation-failed before any bd write', () async {
        final receipt = await openGate(properties);
        expect(receipt.status, 'failed');
        expect(receipt.problem!['code'], 'validation-failed');
        expectSchema(receipt.json, 'mutationReceipt');
        expect(bd.writes, isEmpty);
      });
    }

    test('a gate opened through the Scope is closed through it with bd gate '
        'resolve', () async {
      final opened = await openGate(gate);
      final url = (opened.results.single['resource']! as Json)['id']! as String;
      final receipt = await authority.mutate('update-bead-properties', {
        'bead': url,
        'change': [
          {'op': 'replace', 'path': '/status', 'value': 'closed'},
          {'op': 'add', 'path': '/close_reason', 'value': 'resolved'},
        ],
      }, idempotencyKey: 'resolve');
      expect(receipt.status, 'completed', reason: '${receipt.json}');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(bd.writes.last, [
        'gate',
        'resolve',
        '--reason=resolved',
        '--',
        't-000',
      ]);
      expect(bd.row('t-000')['status'], 'closed');
      expect(bd.row('t-000')['close_reason'], 'resolved');
    });

    test('delete-bead and every Link mutation are forbidden before '
        'admission', () async {
      for (final (target, body) in <(String, Json)>[
        ('delete-bead', {'bead': _bead('t-1')}),
        ('create-link', <String, Object?>{}),
        ('update-link-properties', <String, Object?>{}),
        ('delete-link', <String, Object?>{}),
        ('put-alias', <String, Object?>{}),
      ]) {
        await expectLater(
          authority.mutate(target, body, idempotencyKey: 'k-$target'),
          throwsA(_problem('forbidden')),
        );
      }
      await expectLater(
        authority.mutate('batch', {
          'operations': [
            {'operation': 'deleteBead', 'bead': _bead('t-1')},
          ],
        }, idempotencyKey: 'k3'),
        throwsA(_problem('forbidden')),
      );
      expect(bd.writes, isEmpty);
    });

    test(
      'a batch of two is limit-exceeded before admission, binding no key',
      () async {
        final two = {
          'operations': [
            for (final title in ['a', 'b'])
              {
                'operation': 'createBead',
                'type': '${scope}types/bead',
                'properties': {'title': title},
              },
          ],
        };
        await expectLater(
          authority.mutate('batch', two, idempotencyKey: 'same'),
          throwsA(
            _problem('limit-exceeded').having(
              (AuthorityProblem p) => p.limit,
              'limit',
              'transaction.operations',
            ),
          ),
        );
        expect(bd.writes, isEmpty);
        final one = await authority.mutate('batch', {
          'operations': [(two['operations']! as List<Object?>).first],
        }, idempotencyKey: 'same');
        expect(one.status, 'completed');
      },
    );

    test('a create with no metadata is one bd create carrying its external '
        'ref', () async {
      final receipt = await authority.mutate('create-bead', {
        'type': '${scope}types/bead',
        'properties': {'title': 'made', 'description': 'why'},
      }, idempotencyKey: 'c1');
      expect(receipt.status, 'completed', reason: '${receipt.json}');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(bd.writes, [
        [
          'create',
          '--title=made',
          '--type=task',
          '--priority=2',
          '--description=why',
          '--external-ref=bdp:c1:0',
          '--json',
        ],
      ]);
      expect(receipt.results.single['outcome'], 'created');
    });

    test('a create carrying metadata is the create, then one update merging '
        'it, and a retry finds the bead by its ref', () async {
      final body = {
        'operations': [
          {
            'operation': 'createBead',
            'name': 'made',
            'type': '${scope}types/bead',
            'properties': {
              'title': 'made',
              'metadata': {'k': 'v'},
            },
          },
        ],
      };
      final receipt = await authority.mutate(
        'batch',
        body,
        idempotencyKey: 'c2',
      );
      expect(receipt.status, 'completed', reason: '${receipt.json}');
      expect(bd.writes, [
        [
          'create',
          '--title=made',
          '--type=task',
          '--priority=2',
          '--external-ref=bdp:c2:made',
          '--json',
        ],
        ['update', '--set-metadata=k=v', '--json', '--', 't-000'],
      ]);
      final again = await authority.mutate('batch', body, idempotencyKey: 'c2');
      expect(again.json, receipt.json);
      expect(bd.writes, hasLength(2));
    });

    test(
      'a create whose merge fails answers a failed receipt naming the '
      'bead and its ref, and a retry merges instead of creating again',
      () async {
        var failing = true;
        bd.intercept = (arguments) {
          if (failing &&
              arguments.first == 'update' &&
              arguments.any((a) => a.startsWith('--set-metadata='))) {
            failing = false;
            return BdOutput(
              exitCode: 1,
              stdout: jsonEncode({'error': 'injected merge failure'}),
            );
          }
          return null;
        };
        final body = {
          'type': '${scope}types/bead',
          'properties': {
            'title': 'made',
            'metadata': {'k': 'v'},
          },
        };
        final failed = await authority.mutate(
          'create-bead',
          body,
          idempotencyKey: 'c3',
        );
        expect(failed.status, 'failed');
        expectSchema(failed.json, 'mutationReceipt');
        final problem = failed.problem!;
        expect(problem['operationIndex'], 0);
        expect(problem['instance'], _bead('t-000'));
        expect(
          problem['detail'],
          allOf(
            contains('bdp:c3:0'),
            contains('stood and the merge of its metadata did not'),
            contains('injected merge failure'),
          ),
        );
        final retried = await authority.mutate(
          'create-bead',
          body,
          idempotencyKey: 'c3',
        );
        expect(retried.status, 'completed', reason: '${retried.json}');
        expect(retried.results.single['outcome'], 'created');
        expect(
          (retried.results.single['resource']! as Json)['id'],
          _bead('t-000'),
        );
        expect(bd.writes.where((call) => call.first == 'create'), hasLength(1));
        expect(bd.row('t-000')['metadata'], {'k': 'v'});
        final first = await authority.readReceipt(failed.json['id']! as String);
        expect(first.status, ReceiptStatus.failed);
      },
    );

    test('a create names the bead Type and supplies no id', () async {
      final untyped = await authority.mutate('create-bead', {
        'type': 'https://elsewhere.example/types/x',
        'properties': {'title': 'x'},
      }, idempotencyKey: 'c4');
      expect(untyped.problem!['code'], 'type-not-installed');
      final named = await authority.mutate('create-bead', {
        'id': _bead('t-mine'),
        'type': '${scope}types/bead',
        'properties': {'title': 'x'},
      }, idempotencyKey: 'c5');
      expect(named.problem!['code'], 'validation-failed');
      expect(named.problem!['pointer'], '/id');
      expect(bd.writes, isEmpty);
    });

    test('a write bd never serves back is failed revision-mismatch, '
        'naming the field', () async {
      final slow = await _open(
        bd,
        interval: const Duration(milliseconds: 5),
        within: const Duration(milliseconds: 30),
      );
      addTearDown(slow.close);
      bd.intercept = (arguments) => arguments.first == 'update'
          ? const BdOutput(exitCode: 0, stdout: '[]')
          : null;
      final receipt = await slow.mutate('update-bead-properties', {
        'bead': _bead('t-1'),
        'change': [
          {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
        ],
      }, idempotencyKey: 'u1');
      expect(receipt.problem!['code'], 'revision-mismatch');
      expect(receipt.problem!['detail'], contains('metadata.k'));
    });

    test('the reads that confirm a write wait their own interval, not the '
        "store's poll", () async {
      final seldom = await BdScopeAuthority.open(
        bd: bd,
        scope: scope,
        interval: const Duration(hours: 1),
        confirmInterval: const Duration(milliseconds: 5),
        within: const Duration(milliseconds: 30),
      );
      addTearDown(seldom.close);
      expect(seldom.confirmInterval, const Duration(milliseconds: 5));
      expect(authority.confirmInterval, authority.interval);
      bd.intercept = (arguments) => arguments.first == 'update'
          ? const BdOutput(exitCode: 0, stdout: '[]')
          : null;
      final receipt = await seldom
          .mutate('update-bead-properties', {
            'bead': _bead('t-1'),
            'change': [
              {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
            ],
          }, idempotencyKey: 'u1')
          .timeout(const Duration(seconds: 5));
      expect(receipt.problem!['code'], 'revision-mismatch');
      expect(
        bd.calls.where((call) => call.first == 'list').length,
        greaterThan(3),
        reason: 'the confirming reads ran every few milliseconds',
      );
    });

    /// What [receipt]'s problem was, as a client reads it.
    ({BdWriteFailure kind, String message, String? instance}) failureOf(
      AuthorityReceipt receipt,
    ) {
      expect(receipt.status, 'failed', reason: '${receipt.json}');
      expectSchema(receipt.json, 'mutationReceipt');
      return bdWriteFailureOf(ProblemDetails.fromJson(receipt.problem));
    }

    test('a reasonless close bd refuses for its blockers is rejected, carrying '
        "bd 1.3.2's own words whole", () async {
      bd.intercept = (arguments) => arguments.first == 'update'
          ? BdOutput(
              exitCode: 1,
              stdout: jsonEncode({
                'error': '1 of 1 issues failed to update',
                'failed': [
                  {
                    'id': 't-1',
                    'error':
                        'updating issue: cannot close blocked issue: t-1 is '
                        'blocked by [t-2 t-3]',
                  },
                ],
              }),
            )
          : null;
      final receipt = await update([
        {'op': 'replace', 'path': '/status', 'value': 'closed'},
      ]);
      expect(bd.writes, [
        ['update', '--status=closed', '--json', '--', 't-1'],
      ]);
      const words =
          '1 of 1 issues failed to update: updating issue: cannot close '
          'blocked issue: t-1 is blocked by [t-2 t-3]';
      expect(receipt.problem!['code'], 'validation-failed');
      expect(receipt.problem!['detail'], words);
      final failure = failureOf(receipt);
      expect(failure.kind, BdWriteFailure.rejected);
      expect(failure.message, words);
    });

    test('every failed write is read back as its kind', () async {
      final refused = failureOf(
        await update([
          {'op': 'replace', 'path': '/notes', 'value': 'mine'},
        ], key: 'refused'),
      );
      expect(refused.kind, BdWriteFailure.refused);
      expect(refused.message, contains('appends'));

      final moved = failureOf(
        await update(
          [
            {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
          ],
          expectedRevision: 'stale',
          key: 'moved',
        ),
      );
      expect(moved.kind, BdWriteFailure.moved);

      final missing = failureOf(
        await authority.mutate('update-bead-properties', {
          'bead': _bead('t-404'),
          'change': [
            {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
          ],
        }, idempotencyKey: 'missing'),
      );
      expect(missing.kind, BdWriteFailure.failed);

      final untyped = failureOf(
        await authority.mutate('create-bead', {
          'type': 'https://elsewhere.example/types/x',
          'properties': {'title': 'x'},
        }, idempotencyKey: 'untyped'),
      );
      expect(untyped.kind, BdWriteFailure.failed);

      for (final id in ['t-g1', 't-g2']) {
        bd.add(id, also: {'issue_type': 'gate', 'await_id': 'k'});
      }
      final taken = failureOf(
        await openGate({
          'issue_type': 'gate',
          'await_id': 'k',
          'blocks': 't-1',
          'reason': 'r',
        }, key: 'taken'),
      );
      expect(taken.kind, BdWriteFailure.failed);
      expect(taken.message, contains('t-g2'));

      bd.intercept = (arguments) => arguments.first == 'update'
          ? BdOutput(
              exitCode: 1,
              stdout: jsonEncode({'error': 'injected merge failure'}),
            )
          : null;
      final stood = failureOf(
        await authority.mutate('create-bead', {
          'type': '${scope}types/bead',
          'properties': {
            'title': 'made',
            'metadata': {'k': 'v'},
          },
        }, idempotencyKey: 'stood'),
      );
      expect(stood.kind, BdWriteFailure.stood);
      expect(stood.instance, _bead('t-000'));
      expect(stood.message, contains('injected merge failure'));

      final rejected = failureOf(
        await update([
          {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
        ], key: 'rejected'),
      );
      expect(rejected.kind, BdWriteFailure.rejected);
      expect(rejected.message, 'injected merge failure');

      final slow = await _open(
        bd,
        interval: const Duration(milliseconds: 5),
        within: const Duration(milliseconds: 30),
      );
      addTearDown(slow.close);
      bd.intercept = (arguments) => arguments.first == 'update'
          ? const BdOutput(exitCode: 0, stdout: '[]')
          : null;
      final unconfirmed = failureOf(
        await slow.mutate('update-bead-properties', {
          'bead': _bead('t-1'),
          'change': [
            {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
          ],
        }, idempotencyKey: 'unconfirmed'),
      );
      expect(unconfirmed.kind, BdWriteFailure.unconfirmed);
      expect(unconfirmed.instance, _bead('t-1'));
      expect(unconfirmed.message, contains('metadata.k'));

      bd.intercept = (arguments) => arguments.first == 'update'
          ? throw const BdFailure('update', 'gone')
          : null;
      final unrun = failureOf(
        await slow.mutate('update-bead-properties', {
          'bead': _bead('t-1'),
          'change': [
            {'op': 'add', 'path': '/metadata/k', 'value': 'w'},
          ],
        }, idempotencyKey: 'unrun'),
      );
      expect(unrun.kind, BdWriteFailure.failed);
      expect(unrun.message, 'gone');
    });

    test('a bd that cannot be read before a write is a direct problem that '
        'binds no key', () async {
      bd.intercept = (arguments) =>
          arguments.first == 'list' ? const BdOutput(exitCode: 1) : null;
      await expectLater(
        update([
          {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
        ]),
        throwsA(_problem('temporarily-unavailable')),
      );
      bd.intercept = null;
      final receipt = await update([
        {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
      ]);
      expect(receipt.status, 'completed');
    });
  });
}
