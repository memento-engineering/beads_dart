import 'package:gc_api/gc_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late List<http.Request> requests;

  /// A client whose server answers every request with [respond].
  GcApi api(http.Response Function(http.Request request) respond) {
    requests = [];
    return GcApi(
      httpClient: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
      headers: {'authorization': 'Bearer t'},
    );
  }

  test('health reads GET /health', () async {
    final health = await api((_) => jsonResponse('health.json')).health();
    expect(requests.single.method, 'GET');
    expect(requests.single.url, Uri.parse('http://127.0.0.1:8372/health'));
    expect(requests.single.headers['accept'], 'application/json');
    expect(requests.single.headers['authorization'], 'Bearer t');
    expect(health.status, 'ok');
    expect(health.version, '1.5.1');
    expect(health.uptime, const Duration(seconds: 710995));
    expect((health.citiesTotal, health.citiesRunning), (2, 1));
    expect(health.startup!.ready, isTrue);
    expect(health.startup!.phasesCompleted, hasLength(5));
  });

  test('cities reads GET /v0/cities, its optional fields included', () async {
    final cities = await api((_) => jsonResponse('cities.json')).cities();
    expect(requests.single.url.path, '/v0/cities');
    expect([for (final c in cities) c.name], ['demo', 'spare']);
    expect(cities.first.running, isTrue);
    expect(cities.first.error, isNull);
    expect(cities.last.status, 'stopped');
    expect(cities.last.error, 'city.toml: no such file');
  });

  test('a null items list is no cities', () async {
    final cities = await api(
      (_) => http.Response('{"items":null,"total":0}', 200),
    ).cities();
    expect(cities, isEmpty);
  });

  test('a base URI with a path prefix keeps it', () async {
    requests = [];
    final client = GcApi(
      baseUri: Uri.parse('https://gc.example.ts.net/supervisor/'),
      httpClient: MockClient((request) async {
        requests.add(request);
        return jsonResponse('health.json');
      }),
    );
    await client.health();
    expect(
      requests.single.url,
      Uri.parse('https://gc.example.ts.net/supervisor/health'),
    );
  });

  test('status reads GET /v0/city/{name}/status, a partial one '
      'included', () async {
    final status = await api(
      (_) => jsonResponse('status.json'),
    ).city('demo').status();
    expect(requests.single.url.path, '/v0/city/demo/status');
    expect(status.name, 'demo');
    expect(status.running, 4);
    expect(
      (status.agents.total, status.agents.running, status.agents.quarantined),
      (15, 4, 0),
    );
    expect((status.rigs.total, status.rigs.suspended), (1, 0));
    expect(
      (status.work.open, status.work.ready, status.work.inProgress),
      (100, 34, 4),
    );
    expect((status.mail.total, status.mail.unread), (7, 2));
    expect(status.partial, isTrue);
    expect(status.partialErrors.single, startsWith('store health:'));
    expect(status.json['agent_count'], 15);
  });

  test('a city name is one path segment, escaped', () async {
    await api((_) => jsonResponse('status.json')).city('a b/c').status();
    expect(requests.single.url.path, '/v0/city/a%20b%2Fc/status');
  });

  test('events reads a page, sends only the filters given, and reads the '
      'next cursor', () async {
    final page = await api(
      (_) => jsonResponse('events.json'),
    ).city('demo').events(limit: 2, type: 'bead.created');
    expect(requests.single.url.path, '/v0/city/demo/events');
    expect(requests.single.url.queryParameters, {
      'limit': '2',
      'type': 'bead.created',
    });
    expect([for (final e in page.events) e.seq], [239008, 239007]);
    expect(page.total, 239008);
    expect(page.nextCursor, 'v1:eyJrIjoic3EiLCJzIjoyMzkwMDd9');
    final created = page.events.first;
    expect(created.type, 'bead.created');
    expect(created.actor, 'cache-reconcile');
    expect(created.subject, 'demo-wisp-e7fdw90');
    expect(created.runId, 'demo-wisp-e7fdw90');
    expect(created.ts, DateTime.parse('2026-11-05T19:40:05.505527-06:00'));
    expect((created.payload['bead']! as Map)['status'], 'open');
    expect(page.events.last.payload, isEmpty);
  });

  test('an empty next cursor is the last page', () async {
    final page = await api(
      (_) => http.Response('{"items":[],"total":0,"next_cursor":""}', 200),
    ).city('demo').events();
    expect(page.nextCursor, isNull);
    expect(requests.single.url.hasQuery, isFalse);
  });

  test('a Problem Details refusal is a GcProblemException', () async {
    final failure = api(
      (_) => jsonResponse(
        'problem.json',
        status: 404,
        contentType: 'application/problem+json',
      ),
    ).city('nowhere').status();
    await expectLater(
      failure,
      throwsA(
        isA<GcProblemException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.problem.code, 'code', 'city-not-found')
            .having(
              (e) => e.problem.type,
              'type',
              'urn:gascity:error:city-not-found',
            )
            .having((e) => e.uri.path, 'uri', '/v0/city/nowhere/status'),
      ),
    );
  });

  test('a problem with only title, status and detail still reads, and a '
      'read_only detail says so', () async {
    final failure = api(
      (_) => http.Response(
        '{"title":"Forbidden","status":403,'
        '"detail":"read_only: mutations disabled"}',
        403,
        headers: {'content-type': 'application/problem+json'},
      ),
    ).health();
    await expectLater(
      failure,
      throwsA(
        isA<GcProblemException>()
            .having((e) => e.problem.code, 'code', isNull)
            .having((e) => e.problem.readOnly, 'readOnly', isTrue),
      ),
    );
  });

  test('a failure with no problem body is a GcHttpException', () async {
    final failure = api((_) => http.Response('upstream down', 502)).health();
    await expectLater(
      failure,
      throwsA(
        isA<GcHttpException>()
            .having((e) => e.status, 'status', 502)
            .having((e) => e.transient, 'transient', isTrue)
            .having((e) => e.body, 'body', 'upstream down'),
      ),
    );
  });

  test('a body of the wrong shape is a GcProtocolException naming the '
      'field', () async {
    final failure = api(
      (_) => http.Response('{"status":"ok","version":1}', 200),
    ).health();
    await expectLater(
      failure,
      throwsA(
        isA<GcProtocolException>().having(
          (e) => e.message,
          'message',
          'version is not a string',
        ),
      ),
    );
  });

  test('a body that is not JSON is a GcProtocolException', () async {
    final failure = api((_) => http.Response('<html>', 200)).health();
    await expectLater(failure, throwsA(isA<GcProtocolException>()));
  });
}
