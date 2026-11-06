import 'dart:convert';

import 'package:bdp/bdp.dart';
import 'package:test/test.dart';

import '../support/scope.dart';

void main() {
  late TestClock clock;
  late ScopeAuthority authority;

  setUp(() {
    clock = TestClock();
    authority = memoryAuthority(clock);
  });

  tearDown(() => authority.close());

  int head() => int.parse(authority.discoveryDocument().position.substring(1));

  group('singleton mutations', () {
    test('createBead returns a completed receipt with the postimage', () {
      final receipt = authority.createBeadJson({
        'id': 'beads/task-42',
        'type': taskType,
        'properties': {'title': 'Specify BDP mutation', 'status': 'open'},
        'attribution': {'principal': 'agent:planner', 'status': 'claimed'},
      }, idempotencyKey: 'k1');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(receipt.status, 'completed');
      expect(receipt.json['effectPosition'], 'p1');
      final resource = results(receipt).single['resource']! as Json;
      expect(resource['id'], '${scope}beads/task-42');
      expect(resource.keys, [
        'id',
        'type',
        'revision',
        'attribution',
        'properties',
      ]);
      expect(authority.resource('beads/task-42').body, resource);
    });

    test('an omitted id is allocated as one opaque segment', () {
      final receipt = authority.createBeadJson({
        'type': taskType,
        'properties': {'title': 'x'},
      }, idempotencyKey: 'k1');
      final id = results(receipt).single['resource']! as Json;
      expect(
        id['id'],
        matches(RegExp(r'^https://beads\.example/acme/beads/[0-9a-f]{16}$')),
      );
    });

    test('updateBeadProperties applies the patch and mints a revision', () {
      final before = createTask(authority, 'beads/task-42');
      final receipt = authority.updateBeadPropertiesJson({
        'bead': '${scope}beads/task-42',
        'expectedRevision': before['revision'],
        'change': [
          {'op': 'replace', 'path': '/status', 'value': 'closed'},
          {'op': 'add', 'path': '/resolution', 'value': null},
        ],
      }, idempotencyKey: 'k2');
      final after = results(receipt).single['resource']! as Json;
      expect(after['properties'], {
        'title': 'Specify BDP mutation',
        'status': 'closed',
        'resolution': null,
      });
      expect(after['revision'], isNot(before['revision']));
    });

    test(
      'a semantic no-op update keeps the revision and produces no group',
      () {
        final before = createTask(authority, 'beads/task-42');
        final receipt = authority.updateBeadPropertiesJson({
          'bead': 'beads/task-42',
          'change': [
            {'op': 'replace', 'path': '/status', 'value': 'open'},
          ],
        }, idempotencyKey: 'k2');
        expectSchema(receipt.json, 'mutationReceipt');
        expect(receipt.status, 'completed');
        expect(receipt.json.containsKey('effectPosition'), isFalse);
        expect(receipt.json['requiredPosition'], 'p1');
        expect(
          (results(receipt).single['resource']! as Json)['revision'],
          before['revision'],
        );
        expect(head(), 1);
      },
    );

    test('deleteBead removes the Bead; its identity is never reused', () {
      final before = createTask(authority, 'beads/task-42');
      final receipt = authority.deleteBeadJson({
        'bead': 'beads/task-42',
        'expectedRevision': before['revision'],
      }, idempotencyKey: 'k2');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(results(receipt).single['deleted'], {
        'resourceKind': 'bead',
        'resource': {
          'id': '${scope}beads/task-42',
          'type': taskType,
          'revision': before['revision'],
        },
      });
      expect(
        () => authority.resource('beads/task-42'),
        throwsA(
          isA<AuthorityProblem>().having(
            (p) => p.code,
            'code',
            'resource-not-found',
          ),
        ),
      );
      final again = authority.createBeadJson({
        'id': 'beads/task-42',
        'type': taskType,
        'properties': {'title': 'again'},
      }, idempotencyKey: 'k3');
      expect(again.status, 'failed');
      expect(again.problem!['code'], 'identity-taken');
      expect(again.problem!['pointer'], '/id');
    });

    test('createLink, updateLinkProperties and deleteLink', () {
      createTask(authority, 'beads/task-41');
      createTask(authority, 'beads/task-42');
      final created = authority.createLinkJson({
        'id': 'links/blocks-3',
        'type': blocksType,
        'source': 'beads/task-42',
        'target': {'uri': '${scope}beads/task-41', 'revision': 'pinned-r1'},
      }, idempotencyKey: 'k3');
      expectSchema(created.json, 'mutationReceipt');
      final link = results(created).single['resource']! as Json;
      expect(link['source'], '${scope}beads/task-42');
      expect(link['target'], {
        'uri': '${scope}beads/task-41',
        'revision': 'pinned-r1',
      });

      final updated = authority.updateLinkPropertiesJson({
        'link': 'links/blocks-3',
        'expectedRevision': link['revision'],
        'change': [
          {'op': 'add', 'path': '/reason', 'value': 'order'},
        ],
      }, idempotencyKey: 'k4');
      final newLink = results(updated).single['resource']! as Json;
      expect(newLink['properties'], {'reason': 'order'});

      final blocked = authority.deleteBeadJson({
        'bead': 'beads/task-41',
      }, idempotencyKey: 'k5');
      expect(blocked.problem!['code'], 'incident-links-exist');

      final deleted = authority.deleteLinkJson({
        'link': 'links/blocks-3',
        'expectedRevision': newLink['revision'],
      }, idempotencyKey: 'k6');
      expect(
        (results(deleted).single['deleted']! as Json)['resourceKind'],
        'link',
      );
      expect(
        authority.deleteBeadJson({
          'bead': 'beads/task-41',
        }, idempotencyKey: 'k7').status,
        'completed',
      );
    });
  });

  group('validation', () {
    test('an uninstalled Type is type-not-installed', () {
      final receipt = authority.createBeadJson({
        'type': 'https://work.example/types/nope',
      }, idempotencyKey: 'k1');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(receipt.problem!['code'], 'type-not-installed');
    });

    test('a schema violation carries located diagnostics', () {
      final receipt = authority.createBeadJson({
        'type': taskType,
        'properties': {'status': 'blocked'},
      }, idempotencyKey: 'k1');
      expectSchema(receipt.json, 'mutationReceipt');
      final problem = receipt.problem!;
      expect(problem['code'], 'validation-failed');
      expect(problem['status'], 422);
      final locations = [
        for (final d in (problem['diagnostics']! as List).cast<Json>())
          d['schemaLocation'],
      ];
      expect(
        locations,
        containsAll([
          'https://work.example/schemas/task#/required',
          'https://work.example/schemas/task#/properties/status/enum',
        ]),
      );
    });

    test('endpoint constraints and external policies are enforced', () {
      createTask(authority, 'beads/task-42');
      final wrongSource = authority.createLinkJson({
        'type': citesType,
        'source': 'beads/task-42',
        'target': 'beads/task-42',
      }, idempotencyKey: 'k1');
      expect(wrongSource.problem!['code'], 'validation-failed');
      expect(wrongSource.problem!['pointer'], '/source');

      final noExternal = authority.createLinkJson({
        'type': blocksType,
        'source': 'https://elsewhere.example/beads/x',
        'target': 'beads/task-42',
      }, idempotencyKey: 'k2');
      expect(noExternal.problem!['code'], 'validation-failed');

      final beadShaped = authority.createLinkJson({
        'type': blocksType,
        'source': 'beads/task-42',
        'target': 'https://elsewhere.example/acme/beads/x',
      }, idempotencyKey: 'k3');
      expect(beadShaped.status, 'completed');
      final notBeadShaped = authority.createLinkJson({
        'type': blocksType,
        'source': 'beads/task-42',
        'target': 'https://github.example/issues/1',
      }, idempotencyKey: 'k4');
      expect(notBeadShaped.problem!['code'], 'validation-failed');

      final missing = authority.createLinkJson({
        'type': blocksType,
        'source': 'beads/nope',
        'target': 'beads/task-42',
      }, idempotencyKey: 'k5');
      expect(missing.problem!['code'], 'resource-not-found');
    });

    test('an integer that does not round-trip through binary64 is refused', () {
      final receipt = authority.createBeadJson({
        'type': taskType,
        'properties': {'title': 'x', 'count': 9007199254740993},
      }, idempotencyKey: 'k1');
      expect(receipt.problem!['code'], 'validation-failed');
    });

    test('malformed records are direct problems that bind no key', () {
      void malformed(Object? body, String pointer, {String target = 'batch'}) {
        expect(
          () => authority.mutate(target, body, idempotencyKey: 'same-key'),
          throwsA(
            isA<AuthorityProblem>()
                .having((p) => p.code, 'code', 'malformed-request')
                .having((p) => p.pointer, 'pointer', pointer),
          ),
        );
      }

      malformed({'operations': <Object?>[]}, '/operations');
      malformed({
        'operations': [
          {'operation': 'createBead', 'type': taskType, 'extra': 1},
        ],
      }, '/operations/0/extra');
      malformed({
        'operations': [
          {'operation': 'createBead', 'name': 'a', 'type': taskType},
          {'operation': 'deleteLink', 'link': '@a'},
        ],
      }, '/operations/1/link');
      malformed(
        {'type': taskType, 'id': 'links/x'},
        '/id',
        target: 'create-bead',
      );
      malformed(
        {'type': taskType, 'id': 'beads/a//b'},
        '/id',
        target: 'create-bead',
      );
      malformed(
        {'bead': 'beads/a', 'change': <Object?>[]},
        '/change',
        target: 'update-bead-properties',
      );
      malformed({'bead': '@a'}, '/bead', target: 'delete-bead');
      // The key stayed unbound: it now executes.
      final ok = authority.mutate('create-bead', {
        'type': taskType,
        'properties': {'title': 'x'},
      }, idempotencyKey: 'same-key');
      expect(ok.status, 'completed');
    });
  });

  group('batch', () {
    test('labels bind staged identities and results map to them', () {
      createTask(authority, 'beads/task-42');
      final receipt = authority.batchJson([
        {'name': 'decision', 'operation': 'createBead', 'type': decisionType},
        {
          'name': 'cite',
          'operation': 'createLink',
          'type': citesType,
          'source': '@decision',
          'target': {'uri': 'beads/task-42', 'revision': 'r'},
        },
        {
          'operation': 'updateLinkProperties',
          'link': '@cite',
          'change': [
            {'op': 'add', 'path': '/role', 'value': 'evidence'},
          ],
        },
      ], idempotencyKey: 'k1');
      expectSchema(receipt.json, 'mutationReceipt');
      final entries = results(receipt);
      final decision = (entries[0]['resource']! as Json)['id'];
      final link = entries[1]['resource']! as Json;
      expect(link['source'], decision);
      expect(entries[2]['resource'], containsPair('id', link['id']));
      expect(entries.map((e) => e['operationName']), [
        'decision',
        'cite',
        null,
      ]);
    });

    test('a CAS mismatch fails the whole batch and commits nothing', () {
      final task = createTask(authority, 'beads/task-42');
      final receipt = authority.batchJson([
        {'operation': 'createBead', 'id': 'beads/dec-9', 'type': decisionType},
        {
          'operation': 'updateBeadProperties',
          'bead': 'beads/task-42',
          'expectedRevision': 'not-${task['revision']}',
          'change': [
            {'op': 'replace', 'path': '/status', 'value': 'closed'},
          ],
        },
      ], idempotencyKey: 'k1');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(receipt.status, 'failed');
      expect(receipt.problem, containsPair('code', 'revision-mismatch'));
      expect(receipt.problem, containsPair('operationIndex', 1));
      expect(
        receipt.problem,
        containsPair('pointer', '/operations/1/expectedRevision'),
      );
      expect(receipt.json.containsKey('effectPosition'), isFalse);
      expect(head(), 1);
      expect(
        () => authority.resource('beads/dec-9'),
        throwsA(isA<AuthorityProblem>()),
      );
      // The failed identity was never committed, so it stays available.
      expect(
        authority.createBeadJson({
          'id': 'beads/dec-9',
          'type': decisionType,
        }, idempotencyKey: 'k2').status,
        'completed',
      );
    });

    test('an update then its reverse are two transitions in one group', () {
      final task = createTask(authority, 'beads/task-42');
      final receipt = authority.batchJson([
        {
          'operation': 'updateBeadProperties',
          'bead': 'beads/task-42',
          'change': [
            {'op': 'replace', 'path': '/status', 'value': 'closed'},
          ],
        },
        {
          'operation': 'updateBeadProperties',
          'bead': 'beads/task-42',
          'change': [
            {'op': 'replace', 'path': '/status', 'value': 'open'},
          ],
        },
      ], idempotencyKey: 'k1');
      final group =
          (authority.changePage(after: 'genesis').body['groups']! as List)
              .cast<Json>()
              .last;
      final events = (group['events']! as List).cast<Json>();
      expect(events.map((e) => e['type']), ['updated', 'updated']);
      expect(events.map((e) => e['ordinal']), [0, 1]);
      expect((events[1]['data']! as Json)['revision'], task['revision']);
      expect(receipt.json['effectPosition'], 'p2');
    });
  });

  group('idempotency', () {
    Json body() => {
      'id': 'beads/task-42',
      'type': taskType,
      'properties': {'title': 'Specify BDP mutation'},
    };

    test(
      'an identical retry returns the retained receipt without executing',
      () {
        final first = authority.createBeadJson(body(), idempotencyKey: 'k1');
        final retry = authority.createBeadJson(body(), idempotencyKey: 'k1');
        expect(retry.json, first.json);
        expect(head(), 1);
        // The one-operation batch is the same semantic request.
        final asBatch = authority.batchJson([
          {'operation': 'createBead', 'name': 'renamed', ...body()},
        ], idempotencyKey: 'k1');
        expect(asBatch.json, first.json);
        // Local and absolute spellings normalize to one identity.
        final absolute = authority.createBeadJson({
          ...body(),
          'id': '${scope}beads/task-42',
        }, idempotencyKey: 'k1');
        expect(absolute.json, first.json);
      },
    );

    test('the same key with different semantics is idempotency-conflict', () {
      final first = authority.createBeadJson(body(), idempotencyKey: 'k1');
      expect(
        () => authority.createBeadJson({
          ...body(),
          'properties': {'title': 'other'},
        }, idempotencyKey: 'k1'),
        throwsA(
          isA<AuthorityProblem>()
              .having((p) => p.code, 'code', 'idempotency-conflict')
              .having((p) => p.status, 'status', 409)
              .having((p) => p.instance, 'instance', first.json['id']),
        ),
      );
    });

    test('numbers compare by value: 1 and 1.0, 0 and -0.0 retry as one '
        'request', () {
      Json withNumbers(num estimate, num offset) => {
        ...body(),
        'properties': {
          'title': 'Specify BDP mutation',
          'estimate': estimate,
          'offset': offset,
        },
      };
      final first = authority.createBeadJson(
        withNumbers(1, 0),
        idempotencyKey: 'n1',
      );
      expect(first.status, 'completed', reason: '${first.json}');
      final retry = authority.createBeadJson(
        withNumbers(1.0, -0.0),
        idempotencyKey: 'n1',
      );
      expect(retry.json, first.json);
      expect(head(), 1);
      expect(
        () =>
            authority.createBeadJson(withNumbers(1.5, 0), idempotencyKey: 'n1'),
        throwsA(
          isA<AuthorityProblem>().having(
            (p) => p.code,
            'code',
            'idempotency-conflict',
          ),
        ),
      );
    });

    test('numbers compare as exact decimals: 2^53 and 2^53 + 1 are two '
        'requests', () {
      Json counting(int count) => {
        ...body(),
        'properties': {'title': 'Specify BDP mutation', 'count': count},
      };
      final first = authority.createBeadJson(
        counting(9007199254740992),
        idempotencyKey: 'big',
      );
      expect(first.status, 'completed', reason: '${first.json}');
      expect(
        () => authority.createBeadJson(
          counting(9007199254740993),
          idempotencyKey: 'big',
        ),
        throwsA(
          isA<AuthorityProblem>()
              .having((p) => p.code, 'code', 'idempotency-conflict')
              .having((p) => p.instance, 'instance', first.json['id']),
        ),
      );
      expect(head(), 1);
    });

    test('a large admissible integer is stored and read back exactly; an '
        'inadmissible one fails under a fresh key', () {
      for (final (key, count) in [
        ('k-2p53', 9007199254740992),
        ('k-2p53-plus-2', 9007199254740994),
      ]) {
        final receipt = authority.createBeadJson({
          'type': taskType,
          'properties': {'title': key, 'count': count},
        }, idempotencyKey: key);
        expect(receipt.status, 'completed', reason: '${receipt.json}');
        final id = (results(receipt).single['resource']! as Json)['id']!;
        final read = authority.resource(id as String).body;
        final stored = (read['properties']! as Json)['count'];
        expect(stored, isA<int>());
        expect(stored, count);
        expect(jsonEncode(read), contains('"count":$count'));
      }
      // 2^53 + 1, 2^62 and 2^63 - 1 have no shortest binary64 literal that
      // spells them, whatever Dart's int-to-double rounding makes of them.
      for (final (key, count) in [
        ('k-2p53-plus-1', 9007199254740993),
        ('k-2p62', 4611686018427387904),
        ('k-int64-max', 9223372036854775807),
      ]) {
        final receipt = authority.createBeadJson({
          'type': taskType,
          'properties': {'title': key, 'count': count},
        }, idempotencyKey: key);
        expect(receipt.status, 'failed', reason: key);
        expect(receipt.problem!['code'], 'validation-failed');
        expect(receipt.problem!['pointer'], '/properties');
      }
      expect(head(), 2);
    });

    test('a non-finite number is refused as inadmissible, not thrown', () {
      for (final (key, value) in [
        ('nan', double.nan),
        ('inf', double.infinity),
        ('neg-inf', double.negativeInfinity),
      ]) {
        final receipt = authority.createBeadJson({
          'type': taskType,
          'properties': {'title': key, 'weight': value},
        }, idempotencyKey: key);
        expect(receipt.problem!['code'], 'validation-failed', reason: key);
      }
      expect(head(), 0);
    });

    test('a schema constant compares numbers as exact decimals', () {
      const exact = 'https://work.example/types/exact';
      authority.installType(
        {
          'id': exact,
          'name': 'Exact',
          'describes': 'bead',
          'conformsTo': <String>[],
          'propertiesSchema': 'https://work.example/schemas/exact',
        },
        schema: {
          'type': 'object',
          'properties': {
            'count': {'const': 9007199254740993},
          },
        },
      );
      // Dart's == finds the int and this double equal; their values differ.
      final receipt = authority.createBeadJson({
        'type': exact,
        'properties': {'count': 9007199254740992.0},
      }, idempotencyKey: 'const');
      expect(receipt.problem!['code'], 'validation-failed');
      expect(head(), 0);
    });

    test('keys are scoped to the principal', () {
      authority.createBeadJson(
        body(),
        idempotencyKey: 'k1',
        principal: 'agent:a',
      );
      final other = authority.createBeadJson(
        body(),
        idempotencyKey: 'k1',
        principal: 'agent:b',
      );
      expect(other.problem!['code'], 'identity-taken');
      expect(
        () => authority.receipt(
          other.json['id'].toString().split('/').last,
          principal: 'agent:a',
        ),
        throwsA(
          isA<AuthorityProblem>().having(
            (p) => p.code,
            'code',
            'resource-not-found',
          ),
        ),
      );
    });

    test(
      'a failed receipt is retained, then forgotten and its key executes anew',
      () {
        createTask(authority, 'beads/task-42');
        final failed = authority.createBeadJson(body(), idempotencyKey: 'k1');
        expect(failed.problem!['code'], 'identity-taken');
        expect(
          authority.createBeadJson(body(), idempotencyKey: 'k1').json,
          failed.json,
        );
        final token = failed.json['id'].toString().split('/').last;
        clock.now = clock.now.add(const Duration(days: 8));
        expect(
          () => authority.receipt(token),
          throwsA(
            isA<AuthorityProblem>().having(
              (p) => p.code,
              'code',
              'resource-not-found',
            ),
          ),
        );
        final fresh = authority.createBeadJson(body(), idempotencyKey: 'k1');
        expect(fresh.json['id'], isNot(failed.json['id']));
        expect(fresh.json['transaction'], isNot(failed.json['transaction']));
      },
    );

    test(
      'a completed receipt expires to its compact form and never re-executes',
      () {
        final first = authority.createBeadJson(body(), idempotencyKey: 'k1');
        clock.now = clock.now.add(const Duration(days: 8));
        final retry = authority.createBeadJson(body(), idempotencyKey: 'k1');
        expectSchema(retry.json, 'mutationReceipt');
        expect(retry.json['detail'], 'expired');
        expect(retry.json['allocated'], [
          {
            'operationIndex': 0,
            'id': '${scope}beads/task-42',
            'type': taskType,
          },
        ]);
        expect(retry.json['transaction'], first.json['transaction']);
        expect(head(), 1);
      },
    );

    test('an epoch change unbinds every key', () {
      final first = authority.createBeadJson(body(), idempotencyKey: 'k1');
      final oldEpoch = authority.epoch;
      authority.reinitialize();
      expect(authority.epoch, isNot(oldEpoch));
      expect(head(), 0);
      final token = first.json['id'].toString().split('/').last;
      expect(() => authority.receipt(token), throwsA(isA<AuthorityProblem>()));
      // Identity non-reuse survives the epoch, so the same request now
      // executes anew and fails on the committed identity.
      final again = authority.createBeadJson(body(), idempotencyKey: 'k1');
      expect(again.json['scopeEpoch'], authority.epoch);
      expect(again.problem!['code'], 'identity-taken');
      final fresh = authority.createBeadJson({
        ...body(),
        'id': 'beads/task-43',
      }, idempotencyKey: 'k2');
      expect(fresh.json['effectPosition'], 'p1');
    });
  });

  test('receipts are readable by their token', () {
    final first = authority.createBeadJson({
      'type': taskType,
      'properties': {'title': 'x'},
    }, idempotencyKey: 'k1');
    final token = first.json['id'].toString().split('/').last;
    expect(authority.receipt(token).body, first.json);
    expect(() => authority.receipt('nope'), throwsA(isA<AuthorityProblem>()));
  });
}
