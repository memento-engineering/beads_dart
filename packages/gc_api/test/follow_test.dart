import 'dart:async';
import 'dart:convert';

import 'package:gc_api/gc_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// One SSE `event` frame carrying an event of [seq].
String frame(int seq, {String type = 'order.fired'}) =>
    'id: $seq\nevent: event\ndata: {"seq":$seq,"type":"$type",'
    '"ts":"2026-11-05T19:46:40-06:00","actor":"controller","payload":{}}\n\n';

const heartbeat =
    'event: heartbeat\ndata: {"timestamp":"2026-11-06T01:46:42Z"}\n\n';

http.StreamedResponse sse(String body) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  200,
  headers: {'content-type': 'text/event-stream'},
);

void main() {
  late List<http.BaseRequest> requests;

  /// The city `demo` of a client whose server answers the n-th stream
  /// request with `answers[n]`.
  GcCity city(List<http.StreamedResponse Function()> answers) {
    requests = [];
    return GcApi(
      httpClient: MockClient.streaming((request, _) async {
        requests.add(request);
        return answers[requests.length - 1]();
      }),
      reconnectDelay: Duration.zero,
    ).city('demo');
  }

  test('it delivers each event in order and skips heartbeats', () async {
    final events = await city([
      () => sse(fixture('stream.txt')),
    ]).follow().take(2).toList();
    expect([for (final e in events) e.seq], [101, 102]);
    expect(events.first.subject, 'dolt-health');
    final first = requests.first;
    expect(first.url.path, '/v0/city/demo/events/stream');
    expect(first.url.hasQuery, isFalse);
    expect(first.headers['accept'], 'text/event-stream');
  });

  test('afterSeq starts after that event', () async {
    await city([() => sse(frame(8))]).follow(afterSeq: 7).first;
    expect(requests.single.url.queryParameters, {'after_seq': '7'});
  });

  test('a stream the server ends reconnects after the last event '
      'delivered', () async {
    final events = await city([
      () => sse(frame(1) + heartbeat + frame(2)),
      () => sse(frame(3)),
    ]).follow().take(3).toList();
    expect([for (final e in events) e.seq], [1, 2, 3]);
    expect(requests[1].url.queryParameters, {'after_seq': '2'});
  });

  test('a dropped connection, a 503 and a 5xx problem are retried', () async {
    final events = await city([
      () => throw http.ClientException('connection reset'),
      () => http.StreamedResponse(const Stream.empty(), 503),
      () => http.StreamedResponse(
        Stream.value(utf8.encode('{"title":"Down","status":500}')),
        500,
        headers: {'content-type': 'application/problem+json'},
      ),
      () => sse(frame(5)),
    ]).follow(afterSeq: 4).first;
    expect(events.seq, 5);
    expect(requests, hasLength(4));
    expect({for (final r in requests) r.url.query}, {'after_seq=4'});
  });

  test('a 4xx problem ends the stream with the problem', () async {
    final stream = city([
      () => http.StreamedResponse(
        Stream.value(utf8.encode(fixture('problem.json'))),
        404,
        headers: {'content-type': 'application/problem+json'},
      ),
    ]).follow();
    await expectLater(
      stream,
      emitsInOrder([
        emitsError(
          isA<GcProblemException>().having(
            (e) => e.problem.code,
            'code',
            'city-not-found',
          ),
        ),
        emitsDone,
      ]),
    );
    expect(requests, hasLength(1));
  });

  test('an event at or before the cursor ends the stream', () async {
    final stream = city([() => sse(frame(3) + frame(3))]).follow();
    await expectLater(
      stream,
      emitsInOrder([
        isA<GcEvent>(),
        emitsError(
          isA<GcProtocolException>().having(
            (e) => e.message,
            'message',
            'event 3 is not after 3',
          ),
        ),
        emitsDone,
      ]),
    );
  });

  test('a body that is not an event stream ends the stream', () async {
    final stream = city([
      () => http.StreamedResponse(
        Stream.value(utf8.encode('{}')),
        200,
        headers: {'content-type': 'application/json'},
      ),
    ]).follow();
    await expectLater(
      stream,
      emitsInOrder([emitsError(isA<GcProtocolException>()), emitsDone]),
    );
  });

  test('cancelling stops the follower even when the client ignores the '
      'abort: it reads no further event, sends no further request, and lets '
      'go of the body at the next frame', () async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    final stream = city([
      () => http.StreamedResponse(
        body.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    ]).follow();
    final seen = <int>[];
    final first = Completer<void>();
    final subscription = stream.listen((event) {
      seen.add(event.seq);
      if (!first.isCompleted) first.complete();
    });
    body.add(utf8.encode(frame(1)));
    await first.future;
    await subscription.cancel();
    // A heartbeat, as the server sends every 15 s: the decoder's
    // cancellation takes effect when it next yields.
    body.add(utf8.encode(heartbeat + frame(2)));
    await pumpEventQueue();
    expect(seen, [1]);
    expect(
      body.hasListener,
      isFalse,
      reason: 'the follower let go of the body',
    );
    expect(requests, hasLength(1));
    expect((requests.single as http.Abortable).abortTrigger, isNotNull);
  });
}
