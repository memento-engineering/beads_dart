import 'dart:async';
import 'dart:convert';

import 'package:bdp/bdp.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../support/scope.dart';

/// The SSE messages of [response], one blank-line-terminated frame each.
StreamIterator<String> sseFrames(Response response) {
  var buffer = '';
  return StreamIterator(
    response.read().transform(utf8.decoder).expand((chunk) {
      buffer += chunk;
      final end = buffer.lastIndexOf('\n\n');
      if (end < 0) return const <String>[];
      final frames = buffer.substring(0, end).split('\n\n');
      buffer = buffer.substring(end + 2);
      return frames;
    }),
  );
}

void main() {
  late TestClock clock;
  late ScopeAuthority authority;
  late Handler handler;

  setUp(() {
    clock = TestClock();
    authority = memoryAuthority(clock);
    handler = authorityHandler(authority);
  });

  tearDown(() => authority.close());

  Future<Response> send(
    String method,
    String target, {
    Map<String, String> headers = const {},
    Object? body,
    String? bodyText,
  }) async => handler(
    Request(
      method,
      Uri.parse('$scope$target'),
      headers: headers,
      body: bodyText ?? (body == null ? null : jsonEncode(body)),
    ),
  );

  Future<Json> json(Response response) async =>
      jsonDecode(await response.readAsString()) as Json;

  Map<String, String> post(String key) => {
    'content-type': 'application/json',
    'accept': 'application/json',
    'idempotency-key': key,
  };

  Json firstBatchBody(String revision) {
    final request = exchange('batch', 'batch-1-original')['request']! as Json;
    final body = jsonDecode(jsonEncode(request['body'])) as Json;
    for (final op in (body['operations']! as List).cast<Json>()) {
      if (op.containsKey('expectedRevision')) op['expectedRevision'] = revision;
    }
    return body;
  }

  group('discovery', () {
    test('the Scope URL links its service description', () async {
      final response = await send('GET', '');
      expect(response.statusCode, 204);
      expect(
        response.headers['link'],
        '<bdp.json>; rel="service-desc"; type="application/json"',
      );
    });

    test('discovery and the Operation Directory validate as Transactional '
        'and carry the fixture members', () async {
      final response = await send('GET', 'bdp.json');
      expect(response.statusCode, 200);
      expect(response.headers['bdp-scope-epoch'], authority.epoch);
      expect(response.headers['bdp-scope-position'], 'p0');
      final body = await json(response);
      expectSchema(body, 'transactionalDiscovery');
      final fixtureBody =
          (exchange('discovery', 'discovery-document')['response']!
                  as Json)['body']!
              as Json;
      expect(
        fixtureBody.keys.toSet().difference(body.keys.toSet()),
        isEmpty,
        reason: 'every fixture member is served',
      );
      expect(body['aliases'], '${scope}alias/');
      expect(body['profile'], 'transactional');
      expect(body['bdpVersion'], '0');
      expect(body['headPosition'], 'p0');

      final directory = await json(await send('GET', 'operations/'));
      expectSchema(directory, 'transactionalOperationDirectory');
      expect(
        directory,
        (exchange('discovery', 'operation-directory')['response']!
            as Json)['body'],
      );
    });

    test('alias URLs resolve to nothing; unserved targets refuse with '
        'forbidden and bind no key', () async {
      createTask(authority, 'beads/task-42');
      final alias = await send('GET', 'alias/current');
      expect(alias.statusCode, 404);
      expect((await json(alias))['code'], 'resource-not-found');
      final position = authority.observe().position;
      for (final target in ScopeAuthority.unservedTargets.values) {
        final response = await send(
          'POST',
          'operations/$target',
          headers: post('unserved-$target'),
          body: {'alias': 'alias/current', 'bead': 'beads/task-42'},
        );
        expect(response.statusCode, 403, reason: target);
        final problem = await json(response);
        expectSchema(problem, 'transactionalProblem');
        expect(problem['code'], 'forbidden');
        expect(response.headers['bdp-scope-epoch'], authority.epoch);
      }
      for (final operation in ['putAlias', 'updateWhere', 'deleteWhere']) {
        final response = await send(
          'POST',
          'operations/batch',
          headers: post('unserved-batch-$operation'),
          body: {
            'operations': [
              {'operation': operation},
            ],
          },
        );
        expect(response.statusCode, 403, reason: operation);
      }
      expect(authority.observe().position, position);
      // The refused key was never bound: it now executes as new.
      final created = await send(
        'POST',
        'operations/create-bead',
        headers: post('unserved-put-alias'),
        body: {
          'type': taskType,
          'properties': {'title': 'after refusal'},
        },
      );
      expect((await json(created))['status'], 'completed');
    });
  });

  group('mutation targets', () {
    test('a body longer than the bound discovery advertises is refused as '
        'too large; one at the bound is read', () async {
      final bound = authority.discovery.limits!.request!.bodyBytes!;
      final over = await send(
        'POST',
        'operations/batch',
        headers: post('too-large'),
        bodyText: ' ' * (bound + 1),
      );
      expect((await json(over))['code'], 'request-too-large');
      final at = await send(
        'POST',
        'operations/batch',
        headers: post('at-bound'),
        bodyText: ' ' * bound,
      );
      expect((await json(at))['code'], isNot('request-too-large'));
    });

    test('the fixture batch commits and answers with its receipt', () async {
      final task = createTask(authority, 'beads/task-42');
      final response = await send(
        'POST',
        'operations/batch',
        headers: post('client-key-0001'),
        body: firstBatchBody(task['revision']! as String),
      );
      expect(response.statusCode, 200);
      final receipt = await json(response);
      expectSchema(receipt, 'mutationReceipt');
      final fixtureResponse =
          exchange('batch', 'batch-1-original')['response']! as Json;
      final fixtureReceipt = fixtureResponse['body']! as Json;
      expect(receipt.keys.toSet(), fixtureReceipt.keys.toSet());
      expect(
        (receipt['results']! as List).map(
          (r) => ((r as Json)['outcome'], r['operationName']),
        ),
        (fixtureReceipt['results']! as List).map(
          (r) => ((r as Json)['outcome'], r['operationName']),
        ),
      );
      expect(response.headers['content-type'], 'application/json');
      expect(response.headers['cache-control'], 'private, no-store');
      expect(response.headers['bdp-scope-position'], receipt['effectPosition']);
      expect(response.headers.containsKey('etag'), isFalse);

      final retry = await send(
        'POST',
        'operations/batch',
        headers: post('client-key-0001'),
        body: firstBatchBody(task['revision']! as String),
      );
      expect(await json(retry), receipt);

      final again = await send(
        'POST',
        'operations/batch',
        headers: post('client-key-0002'),
        body: firstBatchBody(task['revision']! as String),
      );
      final failed = await json(again);
      expectSchema(failed, 'mutationReceipt');
      final fixtureFailed =
          (exchange('batch', 'batch-1-new-key-fails-whole')['response']!
                  as Json)['body']!
              as Json;
      final problem = failed['problem']! as Json;
      final fixtureProblem = fixtureFailed['problem']! as Json;
      for (final key in [
        'type',
        'status',
        'code',
        'retry',
        'operationIndex',
        'operationName',
        'pointer',
      ]) {
        expect(problem[key], fixtureProblem[key], reason: key);
      }
      expect(again.statusCode, 200);
    });

    test(
      'the fixture direct problems bind no key and create no receipt',
      () async {
        final task = createTask(authority, 'beads/task-42');
        await send(
          'POST',
          'operations/batch',
          headers: post('client-key-0001'),
          body: firstBatchBody(task['revision']! as String),
        );
        // A transient abort after admission cannot happen here: admission,
        // execution and commit are one SQLite transaction.
        final cases = (fixture('direct-problems')['exchanges']! as List)
            .cast<Json>()
            .where((e) => e['id'] != 'transient-abort-after-admission');
        for (final c in cases) {
          final request = c['request']! as Json;
          final expected = c['response']! as Json;
          final response = await send(
            'POST',
            request['target']! as String,
            headers: (request['headers']! as Json).cast<String, String>(),
            body: request['body'],
            bodyText: request['bodyText'] as String?,
          );
          expect(
            response.statusCode,
            expected['status'],
            reason: c['id']! as String,
          );
          expect(response.headers['content-type'], 'application/problem+json');
          final problem = await json(response);
          expectSchema(problem, 'transactionalProblem');
          final fixtureProblem = expected['body']! as Json;
          for (final key in ['type', 'code', 'retry', 'pointer']) {
            expect(
              problem[key],
              fixtureProblem[key],
              reason: '${c['id']} $key',
            );
          }
          if (c['id'] == 'idempotency-conflict') {
            expect(problem['instance'], startsWith('${scope}receipts/'));
          }
        }
        expect(authority.discoveryDocument().position, 'p2');
      },
    );

    test('a number literal outside binary64 fails its operation', () async {
      final response = await send(
        'POST',
        'operations/create-bead',
        headers: post('k1'),
        bodyText:
            '{"type": "$taskType", "properties": '
            '{"title": "x", "weight": 1.2345678901234567890}}',
      );
      final receipt = await json(response);
      expectSchema(receipt, 'mutationReceipt');
      expect(receipt['status'], 'failed');
      expect(receipt['problem'], containsPair('code', 'validation-failed'));
      expect(receipt['problem'], containsPair('pointer', '/properties'));
      final fine = await send(
        'POST',
        'operations/create-bead',
        headers: post('k2'),
        bodyText:
            '{"type": "$taskType", "properties": '
            '{"title": "x", "weight": 1e300, "zero": -0.0, "n": 1.50}}',
      );
      expect((await json(fine))['status'], 'completed');
    });

    test('number admissibility is exact at the edges and linear in the '
        'literal', () async {
      Future<String> submit(String key, String literal) async {
        final response = await send(
          'POST',
          'operations/create-bead',
          headers: post(key),
          bodyText:
              '{"type": "$taskType", '
              '"properties": {"title": "x", "n": $literal}}',
        );
        return (await json(response))['status']! as String;
      }

      final zeros = '0' * 400000;
      final clock = Stopwatch()..start();
      expect(await submit('long', '1${zeros}e-400000'), 'completed');
      expect(
        await submit('long-fraction', '0.$zeros${'1'}e400001'),
        'completed',
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await submit('huge', '1e99999999999999999999'), 'failed');
      expect(await submit('tiny', '1e-99999999999999999999'), 'failed');
      expect(await submit('zero', '0e99999999999999999999'), 'completed');
      expect(await submit('negative', '-25e-1'), 'completed');
      expect(await submit('inexact', '9007199254740993'), 'failed');
    });

    test(
      'a retry spelling its numbers differently is the same request',
      () async {
        String body(String estimate, String offset) =>
            '{"id": "beads/n", "type": "$taskType", "properties": '
            '{"title": "t", "estimate": $estimate, "offset": $offset}}';
        Future<Response> create(String text) => send(
          'POST',
          'operations/create-bead',
          headers: post('n'),
          bodyText: text,
        );
        final first = await create(body('1', '0'));
        expect(first.statusCode, 200);
        final firstReceipt = await json(first);
        for (final (estimate, offset) in [('1.0', '-0.0'), ('1e0', '0.0')]) {
          final retry = await create(body(estimate, offset));
          expect(retry.statusCode, 200);
          expect(await json(retry), firstReceipt);
        }
        final other = await create(body('2', '0'));
        expect(other.statusCode, 409);
        expect((await json(other))['code'], 'idempotency-conflict');
      },
    );

    test('literals of different exact values are different requests, '
        'admissible or not', () async {
      Future<Response> create(String key, String literal) => send(
        'POST',
        'operations/create-bead',
        headers: post(key),
        bodyText:
            '{"type": "$taskType", '
            '"properties": {"title": "t", "n": $literal}}',
      );
      final big = await create('big', '9007199254740992');
      expect((await json(big))['status'], 'completed');
      final next = await create('big', '9007199254740993');
      expect(next.statusCode, 409);
      expect((await json(next))['code'], 'idempotency-conflict');
      final spelled = await create('big', '9.007199254740992e15');
      expect(spelled.statusCode, 200);

      // Both literals parse to the double 1.0; neither is admissible.
      final first = await create('fine', '1.00000000000000000001');
      final firstReceipt = await json(first);
      expect(firstReceipt['status'], 'failed');
      final again = await create('fine', '1.000000000000000000010');
      expect(await json(again), firstReceipt);
      final other = await create('fine', '1.00000000000000000002');
      expect(other.statusCode, 409);
      expect((await json(other))['code'], 'idempotency-conflict');
    });

    test('an internal fault is a bodyless 500 handed to onFault', () async {
      final faults = <Object>[];
      final reporting = authorityHandler(
        authority,
        onFault: (error, _) => faults.add(error),
      );
      authority.close();
      final response = await reporting(
        Request('GET', Uri.parse('${scope}beads/x')),
      );
      expect(response.statusCode, 500);
      expect(await response.readAsString(), isEmpty);
      expect(faults, hasLength(1));
      authority = memoryAuthority(clock);
    });

    test('singleton targets, media types, methods and negotiation', () async {
      final created = await send(
        'POST',
        'operations/create-bead',
        headers: post('k1'),
        body: {
          'id': 'beads/x',
          'type': taskType,
          'properties': {'title': 'x'},
        },
      );
      expect(created.statusCode, 200);
      expect((await json(created))['status'], 'completed');

      final textual = await send(
        'POST',
        'operations/create-bead',
        headers: {...post('k2'), 'content-type': 'text/plain'},
        body: {'type': taskType},
      );
      expect(textual.statusCode, 415);

      final repeated = await handler(
        Request(
          'POST',
          Uri.parse('${scope}operations/create-bead'),
          headers: {
            'content-type': 'application/json',
            'idempotency-key': ['a', 'b'],
          },
          body: '{}',
        ),
      );
      expect(repeated.statusCode, 400);

      final getTarget = await send('GET', 'operations/batch');
      expect(getTarget.statusCode, 405);
      expect(getTarget.headers['allow'], 'POST');
      expect(await getTarget.readAsString(), isEmpty);
      final postRead = await send('POST', 'beads/');
      expect(postRead.statusCode, 405);
      expect(postRead.headers['allow'], 'GET, HEAD');

      final unacceptable = await send(
        'POST',
        'operations/create-bead',
        headers: {...post('k3'), 'accept': 'image/png'},
        body: {
          'type': taskType,
          'properties': {'title': 'y'},
        },
      );
      expect(unacceptable.statusCode, 406);
      expect(await unacceptable.readAsString(), isEmpty);
      // Refused before admission: the key is still unbound.
      expect(authority.discoveryDocument().position, 'p1');
      final duplicateUnacceptable = await send(
        'POST',
        'operations/create-bead',
        headers: {...post('k1'), 'accept': 'image/png'},
        body: {
          'id': 'beads/x',
          'type': taskType,
          'properties': {'title': 'x'},
        },
      );
      expect(duplicateUnacceptable.statusCode, 406);
      expect(authority.discoveryDocument().position, 'p1');
    });
  });

  group('reads', () {
    test('Resource reads carry ETag and honour preconditions', () async {
      final task = createTask(authority, 'beads/task-42');
      final etag = '"${task['revision']}"';
      final read = await send('GET', 'beads/task-42');
      expect(read.statusCode, 200);
      expect(read.headers['etag'], etag);
      expect(read.headers['bdp-scope-position'], 'p1');
      expect(await json(read), task);
      expectSchema(task, 'beadRecord');

      final properties = await send('GET', 'beads/task-42?view=properties');
      expect(await json(properties), task['properties']);

      final notModified = await send(
        'GET',
        'beads/task-42',
        headers: {'if-none-match': etag},
      );
      expect(notModified.statusCode, 304);
      expect(await notModified.readAsString(), isEmpty);
      final precondition = await send(
        'GET',
        'beads/task-42',
        headers: {'if-match': '"other"'},
      );
      expect(precondition.statusCode, 412);
      final head = await send('HEAD', 'beads/task-42');
      expect(head.statusCode, 200);
      expect(await head.readAsString(), isEmpty);

      final unknownParameter = await send('GET', 'beads/task-42?include=links');
      expect(unknownParameter.statusCode, 400);
      expect((await json(unknownParameter))['code'], 'invalid-parameter');
      final missing = await send('GET', 'beads/nope');
      expect(missing.statusCode, 404);
      expectSchema(await json(missing), 'transactionalProblem');
      final notAcceptable = await send(
        'GET',
        'beads/task-42',
        headers: {'accept': 'image/png'},
      );
      expect(notAcceptable.statusCode, 406);
    });

    test(
      'collections page in canonical-uri order and filter structurally',
      () async {
        for (final id in ['c', 'a', 'b']) {
          createTask(authority, 'beads/$id');
        }
        authority.createBeadJson({
          'id': 'beads/d',
          'type': decisionType,
        }, idempotencyKey: 'd');
        authority.createLinkJson({
          'type': blocksType,
          'source': 'beads/a',
          'target': 'beads/b',
        }, idempotencyKey: 'l');

        final first = await json(await send('GET', 'beads/?limit=2'));
        expectSchema(first, 'beadCollection');
        expect((first['items']! as List).map((b) => (b as Json)['id']), [
          '${scope}beads/a',
          '${scope}beads/b',
        ]);
        final next = Uri.parse(first['next']! as String);
        final second = await json(await send('GET', 'beads/?${next.query}'));
        expect((second['items']! as List).map((b) => (b as Json)['id']), [
          '${scope}beads/c',
          '${scope}beads/d',
        ]);
        expect(second['next'], isNull);

        final tasks = await json(
          await send(
            'GET',
            'beads/?type=${Uri.encodeQueryComponent(taskType)}',
          ),
        );
        expect((tasks['items']! as List), hasLength(3));
        final links = await json(await send('GET', 'links/?endpoint=beads/b'));
        expectSchema(links, 'linkCollection');
        expect((links['items']! as List), hasLength(1));
        final incident = await json(
          await send('GET', 'beads/a?view=links&direction=inbound'),
        );
        expect(incident['items'], isEmpty);
        final outbound = await json(
          await send('GET', 'beads/a?view=links&direction=outbound'),
        );
        expect((outbound['items']! as List), hasLength(1));
        final inventory = await json(await send('GET', 'types/'));
        expectSchema(inventory, 'typesInventory');

        // A continuation across a commit fails rather than restarting.
        createTask(authority, 'beads/e');
        final stale = await send('GET', 'beads/?${next.query}');
        expect(stale.statusCode, 410);
        expect((await json(stale))['code'], 'cursor-expired');
        final repeated = await send('GET', 'beads/?limit=1&limit=2');
        expect(repeated.statusCode, 400);
      },
    );

    test(
      'receipts are principal-bound and the root is not a Resource',
      () async {
        final created = await json(
          await send(
            'POST',
            'operations/create-bead',
            headers: post('k1'),
            body: {
              'type': taskType,
              'properties': {'title': 'x'},
            },
          ),
        );
        final token = (created['id']! as String).substring(
          '${scope}receipts/'.length,
        );
        final read = await send('GET', 'receipts/$token');
        expect(await json(read), created);
        expect((await send('GET', 'receipts/')).statusCode, 404);
        final other = authorityHandler(
          authority,
          principalOf: (_) => 'agent:other',
        );
        final hidden = await other(
          Request('GET', Uri.parse('${scope}receipts/$token')),
        );
        expect(hidden.statusCode, 404);
      },
    );

    test(
      'minimum-position context is enforced before the representation',
      () async {
        createTask(authority, 'beads/a');
        Future<int> status(Map<String, String> headers) async =>
            (await send('GET', 'beads/a', headers: headers)).statusCode;
        final epoch = authority.epoch;
        expect(
          await status({
            'bdp-minimum-scope-position': 'p1',
            'bdp-scope-epoch': epoch,
            'bdp-authorization-view': 'v1',
          }),
          200,
        );
        expect(
          await status({
            'bdp-minimum-scope-position': 'p9',
            'bdp-scope-epoch': epoch,
            'bdp-authorization-view': 'v1',
          }),
          503,
        );
        expect(
          await status({
            'bdp-minimum-scope-position': 'p1',
            'bdp-scope-epoch': epoch,
            'bdp-authorization-view': 'other',
          }),
          409,
        );
        expect(
          await status({
            'bdp-minimum-scope-position': 'p1',
            'bdp-scope-epoch': 'old',
            'bdp-authorization-view': 'v1',
          }),
          410,
        );
      },
    );

    test('snapshot creation and handle refetch', () async {
      createTask(authority, 'beads/a');
      final manifest = await json(await send('GET', 'snapshot'));
      expectSchema(manifest, 'snapshotManifest');
      createTask(authority, 'beads/b');
      final refetch = await send(
        'GET',
        Uri.parse(manifest['id']! as String).toString().substring(scope.length),
      );
      expect(await json(refetch), manifest);
    });
  });

  group('changefeed over HTTP', () {
    test('finite JSON pages validate and require a starting intent', () async {
      createTask(authority, 'beads/a');
      final page = await send('GET', 'changes/?after=genesis');
      expect(page.statusCode, 200);
      expect(page.headers.containsKey('etag'), isFalse);
      expectSchema(await json(page), 'changefeedPage');
      expect((await send('GET', 'changes/')).statusCode, 400);
      final both = await send('GET', 'changes/?after=genesis&start=now');
      expect(both.statusCode, 400);
      expect((await json(both))['code'], 'invalid-parameter');
      final now = await json(await send('GET', 'changes/?start=now'));
      expect(now['groups'], isEmpty);
      expect((await send('GET', 'changes/?after=bogus')).statusCode, 410);
    });

    test(
      'SSE frames one complete group per message with the checkpoint as id',
      () async {
        createTask(authority, 'beads/a');
        createTask(authority, 'beads/b');
        final response = await send(
          'GET',
          'changes/?after=genesis',
          headers: {'accept': 'application/json;q=0, text/event-stream;q=0.7'},
        );
        expect(response.statusCode, 200);
        expect(response.headers['content-type'], 'text/event-stream');
        expect(response.headers['cache-control'], 'no-store, no-transform');
        final queue = sseFrames(response);
        Future<Json> nextGroup() async {
          expect(
            await queue.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          final lines = queue.current.split('\n');
          expect(lines, hasLength(3));
          expect(lines[1], 'event: change-group');
          final group = jsonDecode(lines[2].substring('data: '.length)) as Json;
          expect(lines[0], 'id: ${group['checkpoint']}');
          expectSchema(group, 'changeGroup');
          return group;
        }

        expect((await nextGroup())['position'], 'p1');
        expect((await nextGroup())['position'], 'p2');
        createTask(authority, 'beads/c');
        expect((await nextGroup())['position'], 'p3');
        await queue.cancel();

        final checkpoint =
            authority.changePage(after: 'genesis').body['groups'] as List;
        final resumed = await send(
          'GET',
          'changes/?after=genesis',
          headers: {
            'accept': 'text/event-stream',
            'last-event-id': (checkpoint[1] as Json)['checkpoint']! as String,
          },
        );
        final firstChunk = await resumed.read().transform(utf8.decoder).first;
        expect(firstChunk, contains('"position":"p3"'));

        final head = await send(
          'HEAD',
          'changes/?after=genesis',
          headers: {'accept': 'text/event-stream'},
        );
        expect(head.statusCode, 200);
        expect(await head.readAsString(), isEmpty);
      },
    );

    test('Event Sources serve JSON pages and SSE', () async {
      createTask(authority, 'beads/a');
      final page = await json(await send('GET', 'beads/a?view=events'));
      expectSchema(page, 'eventPage');
      expect((page['events']! as List).single, containsPair('type', 'created'));
      final stream = await send(
        'GET',
        'events/',
        headers: {'accept': 'text/event-stream'},
      );
      final frames = sseFrames(stream);
      Future<List<String>> next() async {
        expect(
          await frames.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        return frames.current.split('\n');
      }

      final lines = await next();
      expect(lines[0], 'id: ${authority.epoch}_1_0');
      expect(lines[1], 'event: created');
      expectSchema(jsonDecode(lines[2].substring('data: '.length)), 'event');
      createTask(authority, 'beads/b');
      expect((await next())[0], 'id: ${authority.epoch}_2_0');
      await frames.cancel();
    });
  });

  test(
    'concurrent submissions commit in one total order with no gaps',
    () async {
      final responses = await Future.wait([
        for (var i = 0; i < 40; i++)
          send(
            'POST',
            'operations/create-bead',
            headers: post('k$i'),
            body: {
              'type': taskType,
              'properties': {'title': '$i'},
            },
          ),
      ]);
      final positions = <String>{};
      for (final response in responses) {
        positions.add((await json(response))['effectPosition']! as String);
      }
      expect(positions, {for (var i = 1; i <= 40; i++) 'p$i'});
      final groups =
          (authority.changePage(after: 'genesis', limit: 100).body['groups']!
                  as List)
              .cast<Json>();
      for (var i = 0; i < groups.length; i++) {
        expect(groups[i]['position'], 'p${i + 1}');
        expect(groups[i]['previousPosition'], 'p$i');
      }
    },
  );
}
