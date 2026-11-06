import 'dart:convert';

import 'package:bdp/bdp.dart';
import 'package:bdp/src/http_response.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fake_http.dart';
import 'support/fixtures.dart';
import 'support/reference_scope.dart';

const acme = 'https://beads.example/acme/';

Matcher problem(String code, int status) => throwsA(
  isA<BdpProblemException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.status, 'status', status),
);

/// Serves a fixture exchange's response as the fake's answer.
FakeResponse answer(Map<String, Object?> exchange) {
  final response = responseOf(exchange);
  final headers = headersOf(response);
  final body = bodyOf(response);
  return FakeResponse(
    response['status']! as int,
    headers: headers,
    body: body == null ? '' : jsonEncode(body),
  );
}

/// A transactional client bound to the acme discovery fixture.
ScopeClient acmeClient(FakeHttpClient http) {
  final discovery = fixture('transactional/discovery.json');
  return ScopeClient(
    httpClient: http,
    discovery: ScopeDiscovery.fromJson(
      bodyOf(responseOf(exchange(discovery, 'discovery-document'))),
    ),
    operations: OperationDirectory.fromJson(
      bodyOf(responseOf(exchange(discovery, 'operation-directory'))),
    ),
    reconnectDelay: Duration.zero,
  );
}

void main() {
  group('the reference domain through a fake http.Client', () {
    const scope = 'https://beads.example/reference/';
    late ReferenceScope authority;
    late ScopeClient client;

    setUp(() async {
      authority = ReferenceScope(scope);
      client = await ScopeClient.discover(
        Uri.parse(scope),
        httpClient: authority.client,
      );
    });

    test('discovery follows service-desc and reads no directory', () {
      expect(client.discovery.profile, Profile.read);
      expect(client.discovery.scope, scope);
      expect(client.operations, isNull);
      expect(client.discovery.limits?.page?.maximumItems, 200);
      expect(authority.client.requests.map((r) => r.url.toString()), [
        scope,
        '${scope}bdp.json',
      ]);
      expect(
        authority.client.requests.last.headers['accept'],
        'application/json',
      );
    });

    test('the Type inventory walks every page to the fixture set', () async {
      final summaries = <TypeSummary>[];
      var page = await client.types(limit: 3);
      summaries.addAll(page.items);
      for (var next = page.next; next != null; next = page.next) {
        page = await client.nextTypes(next);
        summaries.addAll(page.items);
      }
      expect(summaries.map((s) => s.toJson()), authority.typeSummaries);
      expect(authority.client.requests.length, 2 + 5);
    });

    test(
      'every external-endpoint Link reads back as the fixture wrote it',
      () async {
        for (final entry in authority.externalLinks) {
          final link = await client.readLink(entry['localId']! as String);
          expect(link.id, '$scope${entry['localId']}');
          expect(link.type, entry['type']);
          expect(link.revision, Revision(entry['revision']! as String));
          expect(link.properties, equals(entry['properties']));
          expect(link.source.toJson(), authority.canonical(entry['source']!));
          expect(link.target.toJson(), authority.canonical(entry['target']!));
          expect(link.attribution?.toJson(), entry['attribution']);
        }
      },
    );

    test('incident Links are read through the Bead view', () async {
      final links = await client
          .allIncidentLinks('beads/demo-f', direction: LinkDirection.inbound)
          .toList();
      expect(links.map((l) => l.id), [
        '${scope}links/ZZ-collation',
        '${scope}links/external-source',
        '${scope}links/pinned-local',
      ]);
      expect(
        links.every((l) => l.target.uri == '${scope}beads/demo-f'),
        isTrue,
      );
      final request = authority.client.requests.last;
      expect(request.url.queryParameters, {
        'view': 'links',
        'direction': 'inbound',
      });
    });

    test('a Bead reads with its owned-Link plane', () async {
      final bead = await client.readBead('${scope}beads/demo-f');
      expect(bead.toJson(), authority.demoF);
      expect(bead.ownedLinks!.keys, hasLength(2));
    });

    test('a miss is a typed problem with its HTTP status', () async {
      await expectLater(
        client.readLink('links/missing'),
        problem('resource-not-found', 404),
      );
    });

    test('a reference outside the root is refused before any request', () {
      expect(
        () => client.readBead('links/external-target'),
        throwsArgumentError,
      );
    });
  });

  group('collection reads', () {
    test(
      'a Selector is percent-encoded and reaches the authority intact',
      () async {
        final selector = Selector(
          r'$[?@.source == "https://beads.example/acme/beads/task-42" || '
          r'@.properties.n >= 2]',
        );
        final fake = FakeHttpClient(
          (request) =>
              FakeResponse.json(200, {'items': <Object?>[], 'next': null}),
        );
        await acmeClient(fake).links(
          LinkQuery(
            type: 'https://work.example/types/blocks',
            selector: selector,
            limit: 10,
          ),
        );
        final url = fake.requests.single.url;
        expect(url.queryParameters['selector'], selector.expression);
        expect(url.query, isNot(contains('+')));
        expect(
          url.queryParameters['type'],
          'https://work.example/types/blocks',
        );
        expect(url.queryParameters['limit'], '10');
      },
    );

    test('an empty page with a continuation is not the end', () async {
      final link =
          bodyOf(
                responseOf(
                  exchange(
                    fixture('transactional/snapshots.json'),
                    'snapshot-at-pos-42',
                  ),
                ),
              )!
              as Map<String, Object?>;
      final links = (link['links']! as Map<String, Object?>)['items'];
      final fake = FakeHttpClient(
        (request) => request.url.queryParameters['cursor'] == 'two'
            ? FakeResponse.json(200, {'items': links, 'next': null})
            : FakeResponse.json(200, {
                'items': <Object?>[],
                'next': '${acme}links/?cursor=two',
              }),
      );
      final all = await acmeClient(fake).allLinks().toList();
      expect(all, hasLength(1));
      expect(fake.requests, hasLength(2));
    });
  });

  group('transactional mutations', () {
    final batch = fixture('transactional/batch.json');

    test('discovery reads the Operation Directory', () async {
      final discovery = fixture('transactional/discovery.json');
      final fake = FakeHttpClient(
        (request) => switch (request.url.path) {
          '/acme/' => FakeResponse(
            200,
            headers: {
              'content-type': 'text/html',
              'link':
                  '<https://beads.example/acme/docs>; rel="service-doc", '
                  '<bdp.json>; rel="service-desc"; type="application/json"',
            },
            body: '<p>acme</p>',
          ),
          '/acme/bdp.json' => answer(exchange(discovery, 'discovery-document')),
          '/acme/operations/' => answer(
            exchange(discovery, 'operation-directory'),
          ),
          _ => notFound,
        },
      );
      final client = await ScopeClient.discover(
        Uri.parse(acme),
        httpClient: fake,
      );
      expect(client.discovery.profile, Profile.transactional);
      expect(client.discovery.headPosition, ScopePosition('pos-42'));
      expect(client.operations!['batch'], 'batch');
      expect(client.discovery.limits?.transaction?.duration, 'PT30S');
    });

    test('a batch sends the fixture request and returns its receipt', () async {
      final original = exchange(batch, 'batch-1-original');
      final fake = FakeHttpClient((_) => answer(original));
      final request = requestOf(original);
      final receipt = await acmeClient(fake).batch(
        BatchRequest.fromJson(bodyOf(request)).operations,
        idempotencyKey: IdempotencyKey('client-key-0001'),
      );
      final sent = fake.requests.single;
      expect(sent.method, 'POST');
      expect(sent.url.toString(), '${acme}operations/batch');
      expect(sent.headers['idempotency-key'], 'client-key-0001');
      expect(sent.headers['content-type'], 'application/json');
      expect(sent.json, equals(bodyOf(request)));
      expect(receipt.toJson(), equals(bodyOf(responseOf(original))));
      expect(receipt.effectPosition, ScopePosition('pos-43'));
    });

    test('a pending duplicate answers 202 with the pending receipt', () async {
      final fake = FakeHttpClient(
        (_) => answer(exchange(batch, 'batch-1-duplicate-pending')),
      );
      final receipt = await acmeClient(fake).batch([
        CreateBead(type: 'https://work.example/types/task'),
      ], idempotencyKey: IdempotencyKey('client-key-0001'));
      expect(receipt.isPending, isTrue);
      expect(receipt.results, isNull);
    });

    test('a failed transaction is a receipt, not an exception', () async {
      final fake = FakeHttpClient(
        (_) => answer(exchange(batch, 'batch-1-new-key-fails-whole')),
      );
      final receipt = await acmeClient(fake).batch([
        CreateBead(type: 'https://work.example/types/task'),
      ], idempotencyKey: IdempotencyKey('client-key-0002'));
      expect(receipt.status, ReceiptStatus.failed);
      expect(receipt.problem?.code, ProblemCodes.identityTaken);
      expect(receipt.problem?.pointer, '/operations/0/id');
    });

    test(
      'direct problems surface their code, status and Retry-After',
      () async {
        final problems = fixture('transactional/direct-problems.json');
        for (final entry in exchangesOf(problems)) {
          final request = requestOf(entry);
          if (request['schema'] == null) continue;
          final BatchRequest body;
          try {
            body = BatchRequest.fromJson(bodyOf(request));
          } on UnsupportedOperation {
            continue;
          }
          final fake = FakeHttpClient((_) => answer(entry));
          final response = responseOf(entry);
          final expected = bodyOf(response)! as Map<String, Object?>;
          await expectLater(
            acmeClient(fake).batch(
              body.operations,
              idempotencyKey: IdempotencyKey('client-key-0009'),
            ),
            problem(expected['code']! as String, response['status']! as int),
            reason: '${entry['id']}',
          );
        }
        final abort = FakeHttpClient(
          (_) => answer(exchange(problems, 'transient-abort-after-admission')),
        );
        try {
          await acmeClient(abort).batch([
            DeleteBead(bead: 'beads/task-42'),
          ], idempotencyKey: IdempotencyKey('client-key-0005'));
          fail('expected a problem');
        } on BdpProblemException catch (e) {
          expect(e.retryAfter, const Duration(seconds: 2));
          expect(e.problem.retry, RetryDisposition.afterDelay);
        }
      },
    );

    test(
      'a singleton carries its key and guard and returns a receipt',
      () async {
        final retained = exchange(
          fixture('transactional/receipts.json'),
          'receipt-7-as-retained',
        );
        final fake = FakeHttpClient((_) => answer(retained));
        final response = await acmeClient(fake).updateBeadProperties(
          UpdateBeadProperties(
            bead: 'beads/task-42',
            expectedRevision: Revision('task-42-r7'),
            change: PropertyChange([PatchOp.replace('/status', 'cited')]),
          ),
          idempotencyKey: IdempotencyKey('k-1'),
        );
        expect(response, isA<ReceiptResponse>());
        final sent = fake.requests.single;
        expect(sent.url.toString(), '${acme}operations/update-bead-properties');
        expect(sent.headers['idempotency-key'], 'k-1');
        expect(sent.json, {
          'bead': 'beads/task-42',
          'expectedRevision': 'task-42-r7',
          'change': [
            {'op': 'replace', 'path': '/status', 'value': 'cited'},
          ],
        });
      },
    );

    test('a singleton refuses labels before sending', () {
      final client = acmeClient(FakeHttpClient((_) => notFound));
      expect(
        () => client.createBead(
          CreateBead(type: 'https://work.example/types/task', name: 'x'),
          idempotencyKey: IdempotencyKey('k'),
        ),
        throwsArgumentError,
      );
      expect(
        () => client.createLink(
          CreateLink(
            type: 'https://work.example/types/cites',
            source: const UriReference('@decision'),
            target: const UriReference('beads/task-42'),
          ),
          idempotencyKey: IdempotencyKey('k'),
        ),
        throwsArgumentError,
      );
    });

    test('a Read Scope offers no mutation targets', () async {
      final client = ScopeClient(
        httpClient: FakeHttpClient((_) => notFound),
        discovery: ScopeDiscovery.read(
          scope: acme,
          beads: '${acme}beads/',
          links: '${acme}links/',
          types: '${acme}types/',
        ),
      );
      expect(
        () => client.deleteBead(
          const DeleteBead(bead: 'beads/x'),
          idempotencyKey: IdempotencyKey('k'),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => client.changes(const ChangefeedStart.now()),
        throwsUnsupportedError,
      );
    });
  });

  group('Read+Update singletons', () {
    final singletons = fixture('read-update/singletons.json');
    final discovery = fixture('read-update/discovery.json');

    ScopeClient readUpdate(FakeHttpClient fake) => ScopeClient(
      httpClient: fake,
      discovery: ScopeDiscovery.fromJson(
        bodyOf(responseOf(exchange(discovery, 'discovery-document'))),
      ),
      operations: OperationDirectory.fromJson(
        bodyOf(responseOf(exchange(discovery, 'operation-directory'))),
      ),
    );

    Future<MutationResponse> submit(
      ScopeClient client,
      String target,
      MutationOperation operation,
      IdempotencyKey key,
    ) => switch (operation) {
      final CreateBead op => client.createBead(op, idempotencyKey: key),
      final UpdateBeadProperties op => client.updateBeadProperties(
        op,
        idempotencyKey: key,
      ),
      final DeleteBead op => client.deleteBead(op, idempotencyKey: key),
      final CreateLink op => client.createLink(op, idempotencyKey: key),
      final UpdateLinkProperties op => client.updateLinkProperties(
        op,
        idempotencyKey: key,
      ),
      final DeleteLink op => client.deleteLink(op, idempotencyKey: key),
    };

    const operationByTarget = {
      'operations/create-bead': CreateBead.operation,
      'operations/update-bead-properties': UpdateBeadProperties.operation,
      'operations/delete-bead': DeleteBead.operation,
      'operations/create-link': CreateLink.operation,
      'operations/update-link-properties': UpdateLinkProperties.operation,
      'operations/delete-link': DeleteLink.operation,
    };

    for (final entry in exchangesOf(singletons)) {
      final request = requestOf(entry);
      final headers = headersOf(request);
      final key = headers['idempotency-key'];
      if (request['schema'] == null ||
          key == null ||
          key.contains(',') ||
          headers['content-type'] != 'application/json') {
        continue;
      }
      if (!RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(key)) {
        test('${entry['id']} is refused before sending', () {
          expect(() => IdempotencyKey(key), throwsArgumentError);
        });
        continue;
      }
      test('${entry['id']}', () async {
        final fake = FakeHttpClient((_) => answer(entry));
        final operation = MutationOperation.fromRequestJson(
          operationByTarget[request['target']]!,
          bodyOf(request),
        );
        final response = responseOf(entry);
        final call = submit(
          readUpdate(fake),
          request['target']! as String,
          operation,
          IdempotencyKey(key),
        );
        if (response['status'] == 200) {
          final result = await call;
          expect(result, isA<ResultResponse>());
          expect(
            (result as ResultResponse).result.toJson(),
            equals(bodyOf(response)),
          );
        } else {
          final body = bodyOf(response)! as Map<String, Object?>;
          await expectLater(
            call,
            problem(body['code']! as String, response['status']! as int),
          );
        }
        final sent = fake.requests.single;
        expect(sent.json, equals(bodyOf(request)));
        expect(sent.headers['idempotency-key'], key);
        expect(
          sent.url.toString(),
          'https://beads.example/acme/${request['target']}',
        );
      });
    }
  });

  group('receipts', () {
    final receipts = fixture('transactional/receipts.json');
    for (final entry in exchangesOf(receipts)) {
      final request = requestOf(entry);
      if (request['method'] != 'GET' ||
          headersOf(request).containsKey('bdp-minimum-scope-position')) {
        continue;
      }
      test('${entry['id']} reads back', () async {
        final fake = FakeHttpClient((_) => answer(entry));
        final call = acmeClient(fake).readReceipt('$acme${request['target']}');
        final response = responseOf(entry);
        final body = bodyOf(response)! as Map<String, Object?>;
        if (response['status'] == 200) {
          expect((await call).toJson(), equals(body));
        } else {
          await expectLater(
            call,
            problem(body['code']! as String, response['status']! as int),
          );
        }
      });
    }
  });

  group('receipt result pages', () {
    final pagination = fixture('transactional/receipt-pagination.json');
    final base = pagination['scope']! as String;
    for (final id in ['receipt-9-page-2', 'receipt-9-page-after-expiry']) {
      final entry = exchange(pagination, id);
      test('$id is followed through LocalScope', () async {
        final fake = FakeHttpClient((_) => answer(entry));
        final LocalScope scope = acmeClient(fake);
        final next = '$base${requestOf(entry)['target']}';
        final call = scope.readReceiptPage(next);
        final response = responseOf(entry);
        final body = bodyOf(response)! as Map<String, Object?>;
        if (response['status'] == 200) {
          expect((await call).toJson(), equals(body));
        } else {
          await expectLater(
            call,
            problem(body['code']! as String, response['status']! as int),
          );
        }
        expect(fake.requests.single.url.toString(), next);
      });
    }
  });

  group('Type Descriptors', () {
    final domain = fixture('reference-domain/reference-domain.json');
    final descriptors = {
      for (final json
          in (domain['typeDescriptors']! as List<Object?>)
              .cast<Map<String, Object?>>())
        json['id']! as String: json,
    };

    test('read at the Type ID through LocalScope', () async {
      final fake = FakeHttpClient(
        (request) =>
            FakeResponse.json(200, descriptors[request.url.toString()]),
      );
      final LocalScope scope = acmeClient(fake);
      for (final MapEntry(key: id, value: json) in descriptors.entries) {
        final descriptor = await scope.readTypeDescriptor(id);
        expect(descriptor.toJson(), equals(json));
      }
      expect(fake.requests.map((r) => r.url.toString()), descriptors.keys);
    });
  });

  group('changefeed and snapshot reads', () {
    final changefeed = fixture('transactional/changefeed.json');

    test('each starting intent is one explicit query parameter', () async {
      final fake = FakeHttpClient(
        (_) => answer(exchange(changefeed, 'after-ckpt-42')),
      );
      final client = acmeClient(fake);
      final page = await client.changes(
        ChangefeedStart.after(Checkpoint('ckpt-42')),
      );
      await client.changes(ChangefeedStart.genesis());
      await client.changes(const ChangefeedStart.now());
      expect(fake.requests.map((r) => r.url.query), [
        'after=ckpt-42',
        'after=genesis',
        'start=now',
      ]);
      expect(page.lastCheckpoint, Checkpoint('ckpt-43'));
      expect(page.groups.single.eventCount, 6);
    });

    test('an expired cursor is a typed problem', () async {
      final fake = FakeHttpClient(
        (_) => answer(exchange(changefeed, 'after-ckpt-43-historical-erasure')),
      );
      await expectLater(
        acmeClient(fake).changes(ChangefeedStart.after(Checkpoint('ckpt-43'))),
        problem('cursor-expired', 410),
      );
    });

    test('bootstrap stages every snapshot page before installing', () async {
      final manifest =
          bodyOf(
                responseOf(
                  exchange(
                    fixture('transactional/snapshots.json'),
                    'snapshot-at-pos-42',
                  ),
                ),
              )!
              as Map<String, Object?>;
      final beads =
          (manifest['beads']! as Map<String, Object?>)['items']!
              as List<Object?>;
      final firstPage = {
        ...manifest,
        'beads': {
          'items': [beads.first],
          'next': '${acme}snapshot?snapshot=snapshot-42&stream=beads&page=2',
        },
      };
      final fake = FakeHttpClient(
        (request) => request.url.queryParameters['page'] == '2'
            ? FakeResponse.json(200, {'items': beads.sublist(1), 'next': null})
            : FakeResponse.json(200, firstPage),
      );
      final replica = await acmeClient(fake).bootstrap();
      expect(fake.requests.map((r) => r.url.toString()), [
        '${acme}snapshot',
        '${acme}snapshot?snapshot=snapshot-42&stream=beads&page=2',
      ]);
      expect(replica.beads, hasLength(2));
      expect(replica.links, hasLength(1));
      expect(replica.checkpoint, Checkpoint('ckpt-42'));
    });
  });

  group('HTTP contracts', () {
    final contracts = fixture('transactional/http-contracts.json');
    for (final entry in exchangesOf(contracts)) {
      final request = requestOf(entry);
      final response = responseOf(entry);
      final status = response['status']! as int;
      final headers = headersOf(response);
      final body = bodyOf(response);
      if (request['method'] == 'HEAD' ||
          headers['content-type'] == 'text/event-stream') {
        continue;
      }
      test('${entry['id']} is classified', () {
        final uri = Uri.parse('$acme${request['target']}');
        final http.Response wire = http.Response.bytes(
          body == null ? const [] : utf8.encode(jsonEncode(body)),
          status,
          headers: headers,
        );
        if (status == 200) {
          expect(readResponse(uri, wire, (json, path) => json), equals(body));
          return;
        }
        final failure = classifyFailure(uri, status, headers, wire.bodyBytes);
        if (body == null) {
          expect(
            failure,
            isA<BdpHttpException>().having((e) => e.status, 'status', status),
          );
        } else {
          expect(
            failure,
            isA<BdpProblemException>()
                .having((e) => e.status, 'status', status)
                .having(
                  (e) => e.code,
                  'code',
                  (body as Map<String, Object?>)['code'],
                ),
          );
        }
        expect(
          () => readResponse(uri, wire, (json, path) => json),
          throwsA(isA<BdpException>()),
        );
      });
    }
  });
}
