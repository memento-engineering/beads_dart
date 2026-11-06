import 'dart:async';
import 'dart:convert';

import 'package:bdp/bdp.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fake_http.dart';
import 'support/fixtures.dart';

const acme = 'https://beads.example/acme/';

void main() {
  final changefeed = fixture('transactional/changefeed.json');

  Map<String, Object?> groupAt(String checkpoint) {
    if (checkpoint == 'ckpt-43') {
      final page =
          bodyOf(responseOf(exchange(changefeed, 'after-ckpt-42')))!
              as Map<String, Object?>;
      return (page['groups']! as List<Object?>).single! as Map<String, Object?>;
    }
    return (changefeed['groupExamples']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((example) => example['body']! as Map<String, Object?>)
        .singleWhere((body) => body['checkpoint'] == checkpoint);
  }

  String frame(String checkpoint) =>
      'id: $checkpoint\nevent: change-group\n'
      'data: ${jsonEncode(groupAt(checkpoint))}\n\n';

  ScopeClient client(http.Client http) {
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

  /// A stream that sends [text] and then stays open until aborted.
  Stream<List<int>> open(String text) {
    final controller = StreamController<List<int>>()..add(utf8.encode(text));
    return controller.stream;
  }

  /// A stream that sends [text] and then drops the connection.
  Stream<List<int>> dropping(String text) async* {
    yield utf8.encode(text);
    throw http.ClientException('connection reset');
  }

  List<String?> afters(FakeHttpClient fake) => [
    for (final request in fake.requests) request.url.queryParameters['after'],
  ];

  test('reconnects from the durable checkpoint, never Last-Event-ID', () async {
    final fake = FakeHttpClient(
      (request) => switch (request.url.queryParameters['after']) {
        'ckpt-42' => FakeResponse.stream(
          200,
          Stream.value(utf8.encode(frame('ckpt-43') + frame('ckpt-44'))),
        ),
        _ => FakeResponse.stream(200, open(frame('ckpt-45'))),
      },
    );
    final applied = <String>[];
    final reached = Completer<void>();
    final subscription = client(fake).follow(
      ChangefeedStart.after(Checkpoint('ckpt-42')),
      (group) async {
        applied.add(group.checkpoint.value);
        if (applied.length == 3) reached.complete();
      },
    );
    await reached.future;
    await subscription.cancel();
    await subscription.done;

    expect(applied, ['ckpt-43', 'ckpt-44', 'ckpt-45']);
    expect(afters(fake), ['ckpt-42', 'ckpt-44']);
    for (final request in fake.requests) {
      expect(request.headers, isNot(contains('last-event-id')));
      expect(request.headers['accept'], 'text/event-stream');
    }
  });

  test(
    'a message the transport saw but never completed is not durable',
    () async {
      // The connection drops after `id: ckpt-44` arrived but before the
      // message ended: the transport's last event ID is ckpt-44, the
      // durable checkpoint is ckpt-43.
      final partial = frame('ckpt-44').substring(0, 120);
      expect(partial, startsWith('id: ckpt-44'));
      final fake = FakeHttpClient(
        (request) => switch (request.url.queryParameters['after']) {
          'ckpt-42' => FakeResponse.stream(
            200,
            dropping(frame('ckpt-43') + partial),
          ),
          _ => FakeResponse.stream(200, open(frame('ckpt-44'))),
        },
      );
      final applied = <String>[];
      final reached = Completer<void>();
      final subscription = client(fake).follow(
        ChangefeedStart.after(Checkpoint('ckpt-42')),
        (group) async {
          applied.add(group.checkpoint.value);
          if (applied.length == 2) reached.complete();
        },
      );
      await reached.future;
      await subscription.cancel();

      expect(applied, ['ckpt-43', 'ckpt-44']);
      expect(afters(fake), ['ckpt-42', 'ckpt-43']);
      expect(
        fake.requests.every((r) => !r.headers.containsKey('last-event-id')),
        isTrue,
      );
    },
  );

  test(
    'a failed apply ends the subscription at the last durable group',
    () async {
      final fake = FakeHttpClient(
        (_) =>
            FakeResponse.stream(200, open(frame('ckpt-43') + frame('ckpt-44'))),
      );
      final applied = <String>[];
      final subscription = client(fake).follow(
        ChangefeedStart.after(Checkpoint('ckpt-42')),
        (group) async {
          if (group.checkpoint.value == 'ckpt-44') {
            throw StateError('disk full');
          }
          applied.add(group.checkpoint.value);
        },
      );
      await expectLater(subscription.done, throwsStateError);
      expect(applied, ['ckpt-43']);
      expect(fake.requests, hasLength(1));

      // The consumer resumes from its own durable checkpoint.
      final resumed = client(
        fake,
      ).follow(ChangefeedStart.after(Checkpoint(applied.last)), (_) async {});
      final resumedRequest = await fake.received(2);
      await resumed.cancel();
      expect(resumedRequest.url.queryParameters['after'], 'ckpt-43');
    },
  );

  test('an expired cursor ends the subscription with the problem', () async {
    final fake = FakeHttpClient((_) {
      final expired = exchange(changefeed, 'after-ckpt-43-historical-erasure');
      final response = responseOf(expired);
      return FakeResponse(
        response['status']! as int,
        headers: headersOf(response),
        body: jsonEncode(bodyOf(response)),
      );
    });
    final subscription = client(
      fake,
    ).follow(ChangefeedStart.after(Checkpoint('ckpt-43')), (_) async {});
    await expectLater(
      subscription.done,
      throwsA(
        isA<BdpProblemException>()
            .having((e) => e.code, 'code', 'cursor-expired')
            .having((e) => e.status, 'status', 410),
      ),
    );
    expect(fake.requests, hasLength(1));
  });

  test('an after-delay problem is retried', () async {
    var calls = 0;
    final fake = FakeHttpClient((_) {
      calls++;
      if (calls == 1) {
        return FakeResponse.json(503, {
          'type': '${problemTypePrefix}unavailable',
          'code': 'temporarily-unavailable',
          'retry': 'after-delay',
          'status': 503,
        });
      }
      return FakeResponse.stream(200, open(frame('ckpt-43')));
    });
    final reached = Completer<void>();
    final subscription = client(fake).follow(
      ChangefeedStart.after(Checkpoint('ckpt-42')),
      (_) async => reached.complete(),
    );
    await reached.future;
    await subscription.cancel();
    expect(afters(fake), ['ckpt-42', 'ckpt-42']);
  });

  test('start=now resolves the head with a finite read first', () async {
    final fake = FakeHttpClient(
      (request) => request.url.queryParameters['start'] == 'now'
          ? FakeResponse.json(200, {
              'scope': acme,
              'scopeEpoch': 'epoch-1',
              'authorizationView': 'view-a',
              'after': 'ckpt-44',
              'observedHeadPosition': 'pos-44',
              'groups': <Object?>[],
              'next': null,
            })
          : FakeResponse.stream(200, open(frame('ckpt-45'))),
    );
    final reached = Completer<void>();
    final subscription = client(
      fake,
    ).follow(const ChangefeedStart.now(), (_) async => reached.complete());
    await reached.future;
    await subscription.cancel();
    expect(fake.requests.first.url.query, 'start=now');
    expect(fake.requests.first.headers['accept'], 'application/json');
    expect(afters(fake).last, 'ckpt-44');
  });

  Map<String, Object?> headPage({
    required String after,
    List<String> groups = const [],
    String? next,
  }) => {
    'scope': acme,
    'scopeEpoch': 'epoch-1',
    'authorizationView': 'view-a',
    'after': after,
    'observedHeadPosition': 'pos-44',
    'groups': [for (final checkpoint in groups) groupAt(checkpoint)],
    'next': next,
  };

  group('the start=now head read', () {
    test('cancel aborts a head read the authority never answers', () async {
      final fake = FakeHttpClient((_) => Completer<FakeResponse>().future);
      final subscription = client(
        fake,
      ).follow(const ChangefeedStart.now(), (_) async {});
      final head = await fake.received(1);
      expect(head.url.queryParameters['start'], 'now');
      await subscription.cancel().timeout(const Duration(seconds: 1));
      await subscription.done;
    });

    test('cancel returns even when the client ignores the abort', () async {
      final unanswerable = _UnanswerableClient();
      final subscription = client(
        unanswerable,
      ).follow(const ChangefeedStart.now(), (_) async {});
      await unanswerable.sent.future.timeout(const Duration(seconds: 5));
      await subscription.cancel().timeout(const Duration(seconds: 1));
      await subscription.done;
    });

    test(
      'a dropped connection and an after-delay problem are retried',
      () async {
        var heads = 0;
        final fake = FakeHttpClient((request) {
          if (request.url.queryParameters['start'] != 'now') {
            return FakeResponse.stream(200, open(frame('ckpt-45')));
          }
          return switch (++heads) {
            1 => throw http.ClientException('connection reset'),
            2 => FakeResponse.json(503, {
              'type': '${problemTypePrefix}unavailable',
              'code': 'temporarily-unavailable',
              'retry': 'after-delay',
              'status': 503,
            }),
            _ => FakeResponse.json(200, headPage(after: 'ckpt-44')),
          };
        });
        final reached = Completer<void>();
        final subscription = client(
          fake,
        ).follow(const ChangefeedStart.now(), (_) async => reached.complete());
        await reached.future;
        await subscription.cancel();
        expect(heads, 3);
        expect(afters(fake), [null, null, null, 'ckpt-44']);
      },
    );

    test('a dropped continuation resumes at that page, not the head', () async {
      const continuation = '${acme}changes/?after=ckpt-43&page=2';
      var continuations = 0;
      final fake = FakeHttpClient((request) {
        if (request.url.queryParameters['start'] == 'now') {
          return FakeResponse.json(
            200,
            headPage(after: 'ckpt-42', groups: ['ckpt-43'], next: continuation),
          );
        }
        if (request.url.toString() == continuation) {
          if (++continuations == 1) {
            throw http.ClientException('connection reset');
          }
          return FakeResponse.json(200, headPage(after: 'ckpt-43'));
        }
        return FakeResponse.stream(200, open(frame('ckpt-44')));
      });
      final applied = <String>[];
      final reached = Completer<void>();
      final subscription = client(fake).follow(const ChangefeedStart.now(), (
        group,
      ) async {
        applied.add(group.checkpoint.value);
        if (applied.length == 2) reached.complete();
      });
      await reached.future;
      await subscription.cancel();
      expect(applied, ['ckpt-43', 'ckpt-44']);
      expect(continuations, 2);
      expect(
        fake.requests.where((r) => r.url.queryParameters['start'] == 'now'),
        hasLength(1),
      );
      expect(afters(fake).last, 'ckpt-43');
    });
  });

  test('a bodyless transient status is retried', () async {
    var calls = 0;
    final fake = FakeHttpClient((_) {
      calls++;
      if (calls == 1) {
        return FakeResponse(503, headers: const {'retry-after': '0'});
      }
      return FakeResponse.stream(200, open(frame('ckpt-43')));
    });
    final reached = Completer<void>();
    final subscription = client(fake).follow(
      ChangefeedStart.after(Checkpoint('ckpt-42')),
      (_) async => reached.complete(),
    );
    await reached.future;
    await subscription.cancel();
    expect(afters(fake), ['ckpt-42', 'ckpt-42']);
  });

  test('a bodyless permanent status ends the subscription', () async {
    final fake = FakeHttpClient((_) => FakeResponse(404));
    final subscription = client(
      fake,
    ).follow(ChangefeedStart.after(Checkpoint('ckpt-42')), (_) async {});
    await expectLater(
      subscription.done,
      throwsA(isA<BdpHttpException>().having((e) => e.status, 'status', 404)),
    );
    expect(fake.requests, hasLength(1));
  });

  test(
    'an SSE id that is not the group checkpoint is a protocol fault',
    () async {
      final forged = frame(
        'ckpt-43',
      ).replaceFirst('id: ckpt-43', 'id: ckpt-99');
      final fake = FakeHttpClient(
        (_) => FakeResponse.stream(200, open(forged)),
      );
      final subscription = client(
        fake,
      ).follow(ChangefeedStart.after(Checkpoint('ckpt-42')), (_) async {});
      await expectLater(
        subscription.done,
        throwsA(isA<BdpProtocolException>()),
      );
    },
  );

  test('cancel returns while an abort-ignoring client holds an idle SSE '
      'body', () async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    body.add(utf8.encode(frame('ckpt-43')));
    final applied = Completer<String>();
    final subscription = client(_AbortIgnoringClient(body.stream)).follow(
      ChangefeedStart.after(Checkpoint('ckpt-42')),
      (group) async {
        applied.complete(group.checkpoint.value);
      },
    );
    expect(await applied.future, 'ckpt-43');
    // The body stays open and silent, and the client never aborts it.
    await subscription.cancel().timeout(const Duration(seconds: 1));
    await subscription.done;
  });

  test('cancel stops before the next group is applied', () async {
    final released = Completer<void>();
    final controller = StreamController<List<int>>(onCancel: released.complete);
    final fake = FakeHttpClient(
      (_) => FakeResponse.stream(200, controller.stream),
    );
    final applied = <String>[];
    final first = Completer<void>();
    final subscription = client(fake).follow(
      ChangefeedStart.after(Checkpoint('ckpt-42')),
      (group) async {
        applied.add(group.checkpoint.value);
        first.complete();
      },
    );
    controller.add(utf8.encode(frame('ckpt-43')));
    await first.future.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    await subscription.done;
    // Cancelling let go of the body, so nothing written to it after can
    // reach apply.
    await released.future.timeout(const Duration(seconds: 5));
    controller.add(utf8.encode(frame('ckpt-44')));
    expect(controller.hasListener, isFalse);
    expect(applied, ['ckpt-43']);
  });
}

/// A client that never answers and ignores every abort trigger.
final class _UnanswerableClient extends http.BaseClient {
  /// Completes once a request has been sent.
  final Completer<void> sent = Completer();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!sent.isCompleted) sent.complete();
    return Completer<http.StreamedResponse>().future;
  }
}

/// A client that answers with an SSE [body] it never aborts.
final class _AbortIgnoringClient extends http.BaseClient {
  _AbortIgnoringClient(this.body);

  final Stream<List<int>> body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        body,
        200,
        headers: {'content-type': 'text/event-stream'},
        request: request,
      );
}
