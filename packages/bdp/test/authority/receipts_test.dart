import 'dart:convert';

import 'package:bdp/bdp.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../support/http.dart';
import '../support/scope.dart';

/// The `receipts` and `receipt-pagination` fixtures as oracles. Every
/// exchange is either run against a live authority or named here with the
/// reason this authority cannot produce its premise.
const _outOfSubset = {
  'receipts': {
    'receipt-7-after-erasure': 'version erasure is out of the subset',
    'receipt-7-after-grant-change': 'authorization views are out: one view',
    'receipt-pending-get':
        'a transaction executes inside its admitting SQLite transaction, '
        'so no receipt is ever pending',
  },
  'receipt-pagination': {
    'receipt-9-page-2':
        'receipts are never paged: the operation limit is bounded by the '
        'page bound, and one operation yields one entry',
    'receipt-9-page-after-expiry': 'no receipt-page URL is ever issued',
    'receipts-rcpt-9-page=2-minimum-foreign-view':
        'no receipt-page URL is ever issued; the receipt-level twin runs',
    'receipts-rcpt-9-page=2-minimum-cursor-expired':
        'no receipt-page URL is ever issued; the receipt-level twin runs',
  },
};

/// The exchanges the tests below run.
const _run = {
  'receipts': {
    'receipt-7-as-retained',
    'receipt-7-expired-retry',
    'receipts-root',
    'unknown-receipt',
    'receipt-8-forgotten',
    'forgotten-key-executes-as-new',
    'receipts-rcpt-7-minimum-foreign-view',
    'receipts-rcpt-7-minimum-cursor-expired',
  },
  'receipt-pagination': {'pagination-discovery', 'pagination-batch-original'},
};

Json _response(String fixtureName, String id) =>
    exchange(fixtureName, id)['response']! as Json;

Json _body(String fixtureName, String id) =>
    _response(fixtureName, id)['body']! as Json;

void main() {
  late TestClock clock;
  late ScopeAuthority authority;
  late Handler handler;

  setUp(() {
    clock = TestClock();
    authority = memoryAuthority(clock);
    handler = authorityHandler(authority, principalOf: principalFromHeader);
  });

  tearDown(() => authority.close());

  /// The batch fixture's first request, guarded by the Task's actual
  /// revision.
  Json firstBatch() {
    final task = createTask(authority, 'beads/task-42');
    final request = exchange('batch', 'batch-1-original')['request']! as Json;
    final body = jsonDecode(jsonEncode(request['body'])) as Json;
    for (final op in (body['operations']! as List).cast<Json>()) {
      if (op.containsKey('expectedRevision')) {
        op['expectedRevision'] = task['revision'];
      }
    }
    return body;
  }

  Map<String, String> post(String key) => {
    'content-type': 'application/json',
    'accept': 'application/json',
    'idempotency-key': key,
  };

  Future<Json> submit(Json body, String key) async => jsonOf(
    await sendTo(
      handler,
      'POST',
      'operations/batch',
      headers: post(key),
      body: body,
    ),
  );

  String tokenOf(Json receipt) => (receipt['id']! as String).split('/').last;

  /// Runs a GET exchange of [fixtureName] against receipt [token] and
  /// checks the status, fields and body against the fixture.
  Future<Json?> replay(
    String fixtureName,
    String id,
    String token, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final request = exchange(fixtureName, id)['request']! as Json;
    final expected = _response(fixtureName, id);
    final response = await sendTo(
      handler,
      'GET',
      'receipts/$token',
      headers: {
        ...localizeHeaders(request['headers']! as Json, authority),
        ...extraHeaders,
      },
    );
    expect(response.statusCode, expected['status'], reason: id);
    expectFixtureHeaders(response, expected['headers']! as Json, reason: id);
    final body = await jsonOf(response);
    if (expected['status'] != 200) {
      expectFixtureProblem(body, expected['body']! as Json, reason: id);
      return null;
    }
    return body;
  }

  test('every fixture exchange is run or named as out of the subset', () {
    for (final name in ['receipts', 'receipt-pagination']) {
      final ids = {
        for (final e in (fixture(name)['exchanges']! as List).cast<Json>())
          e['id'],
      };
      final skipped = _outOfSubset[name]!.keys.toSet();
      expect(_run[name]!.intersection(skipped), isEmpty, reason: name);
      expect({..._run[name]!, ...skipped}, ids, reason: name);
    }
  });

  group('receipts', () {
    test('receipt-7-as-retained: the receipt reads back as retained', () async {
      final submitted = await submit(firstBatch(), 'client-key-0001');
      final read = await replay(
        'receipts',
        'receipt-7-as-retained',
        tokenOf(submitted),
      );
      expectSchema(read, 'mutationReceipt');
      expect(read, submitted);
      final fixtureBody = _body('receipts', 'receipt-7-as-retained');
      expect(read!.keys.toSet(), fixtureBody.keys.toSet());
      expect(
        [
          for (final r in (read['results']! as List).cast<Json>())
            (r['operationIndex'], r['operationName'], r['outcome']),
        ],
        [
          for (final r in (fixtureBody['results']! as List).cast<Json>())
            (r['operationIndex'], r['operationName'], r['outcome']),
        ],
      );
    });

    test('receipt-7-expired-retry: an identical retry after expiry returns '
        'the compact receipt and executes nothing', () async {
      final body = firstBatch();
      final original = await submit(body, 'client-key-0001');
      final head = authority.observe().position;
      clock.now = clock.now.add(const Duration(days: 8));
      final ex = exchange('receipts', 'receipt-7-expired-retry');
      final response = await sendTo(
        handler,
        'POST',
        'operations/batch',
        headers: localizeHeaders(
          (ex['request']! as Json)['headers']! as Json,
          authority,
        ),
        body: body,
      );
      final expected = _response('receipts', 'receipt-7-expired-retry');
      expect(response.statusCode, expected['status']);
      expectFixtureHeaders(response, expected['headers']! as Json);
      final retry = await jsonOf(response);
      expectSchema(retry, 'mutationReceipt');
      final fixtureBody = expected['body']! as Json;
      expect(retry.keys.toSet(), fixtureBody.keys.toSet());
      expect(retry['detail'], 'expired');
      for (final member in ['id', 'transaction', 'effectPosition']) {
        expect(retry[member], original[member], reason: member);
      }
      expect(
        [
          for (final a in (retry['allocated']! as List).cast<Json>())
            (a['operationIndex'], a['operationName']),
        ],
        [
          for (final a in (fixtureBody['allocated']! as List).cast<Json>())
            (a['operationIndex'], a['operationName']),
        ],
      );
      expect(authority.observe().position, head);
    });

    test('receipts-root and unknown-receipt: the root and every '
        'undisclosable receipt answer the uniform 404', () async {
      final submitted = await submit(firstBatch(), 'client-key-0001');
      final root = await sendTo(
        handler,
        'GET',
        'receipts/',
        headers: {'accept': 'application/json'},
      );
      final rootExpected = _response('receipts', 'receipts-root');
      expect(root.statusCode, rootExpected['status']);
      expectFixtureHeaders(root, rootExpected['headers']! as Json);
      expectFixtureProblem(await jsonOf(root), rootExpected['body']! as Json);

      await replay('receipts', 'unknown-receipt', 'rcpt-0');
      await replay(
        'receipts',
        'unknown-receipt',
        tokenOf(submitted),
        extraHeaders: {'x-principal': 'someone-else'},
      );
    });

    test('receipt-8-forgotten and forgotten-key-executes-as-new', () async {
      final body = firstBatch();
      await submit(body, 'client-key-0001');
      final failed = await submit(body, 'client-key-0002');
      expect(failed['status'], 'failed');
      expect((failed['problem']! as Json)['code'], 'identity-taken');
      clock.now = clock.now.add(const Duration(days: 8));
      await replay('receipts', 'receipt-8-forgotten', tokenOf(failed));

      final head = authority.observe().position;
      final again = await submit(body, 'client-key-0002');
      expectSchema(again, 'mutationReceipt');
      final fixtureBody = _body('receipts', 'forgotten-key-executes-as-new');
      expect(again.keys.toSet(), fixtureBody.keys.toSet());
      expect(again['status'], fixtureBody['status']);
      expect(again['id'], isNot(failed['id']));
      expect(again['transaction'], isNot(failed['transaction']));
      expect(again['requiredPosition'], head);
      expect(authority.observe().position, head);
    });

    test(
      'the minimum-position context is decided after non-disclosure',
      () async {
        final token = tokenOf(await submit(firstBatch(), 'client-key-0001'));
        await replay('receipts', 'receipts-rcpt-7-minimum-foreign-view', token);
        await replay(
          'receipts',
          'receipts-rcpt-7-minimum-cursor-expired',
          token,
        );
        // A hidden receipt stays hidden whatever the context says.
        await replay(
          'receipts',
          'unknown-receipt',
          'rcpt-0',
          extraHeaders: localizeHeaders(
            (exchange(
                      'receipts',
                      'receipts-rcpt-7-minimum-foreign-view',
                    )['request']!
                    as Json)['headers']!
                as Json,
            authority,
          ),
        );
      },
    );
  });

  group('receipt-pagination', () {
    late ScopeAuthority bounded;
    late Handler boundedHandler;

    setUp(() {
      bounded = ScopeAuthority.memory(
        scope: scope,
        clock: clock.call,
        defaultPageItems: 3,
        maximumPageItems: 3,
        maximumOperations: 3,
      );
      installWorkTypes(bounded);
      boundedHandler = authorityHandler(bounded);
    });

    tearDown(() => bounded.close());

    test('pagination-discovery: the advertised page bound', () async {
      final response = await sendTo(
        boundedHandler,
        'GET',
        'bdp.json',
        headers: {'accept': 'application/json'},
      );
      final expected = _response('receipt-pagination', 'pagination-discovery');
      expect(response.statusCode, expected['status']);
      expectFixtureHeaders(response, expected['headers']! as Json);
      final body = await jsonOf(response);
      expectSchema(body, 'transactionalDiscovery');
      final limits = body['limits']! as Json;
      expect(
        limits['page'],
        ((expected['body']! as Json)['limits']! as Json)['page'],
      );
      expect((limits['transaction']! as Json)['operations'], 3);
    });

    test('a receipt at the bound carries every entry inline', () async {
      final receipt = bounded.batchJson([
        for (final n in [1, 2, 3])
          {
            'operation': 'createBead',
            'type': taskType,
            'properties': {'title': 'entry $n'},
          },
      ], idempotencyKey: 'at-bound');
      expectSchema(receipt.json, 'mutationReceipt');
      expect(receipt.results, hasLength(3));
      expect(receipt.json['next'], isNull);
      expect(
        () => bounded.batchJson([
          for (final n in [1, 2, 3, 4])
            {
              'operation': 'createBead',
              'type': taskType,
              'properties': {'title': 'entry $n'},
            },
        ], idempotencyKey: 'past-bound'),
        throwsA(
          isA<AuthorityProblem>().having(
            (p) => p.code,
            'code',
            'limit-exceeded',
          ),
        ),
      );
    });

    test('pagination-batch-original: its set deletion is refused before '
        'admission', () async {
      final ex = exchange('receipt-pagination', 'pagination-batch-original');
      final request = ex['request']! as Json;
      final head = bounded.observe().position;
      final response = await sendTo(
        boundedHandler,
        'POST',
        'operations/batch',
        headers: localizeHeaders(request['headers']! as Json, bounded),
        body: request['body'],
      );
      expect(response.statusCode, 403);
      expect((await jsonOf(response))['code'], 'forbidden');
      expect(bounded.observe().position, head);
    });
  });
}
