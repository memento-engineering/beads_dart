import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One request the fake received.
final class RecordedRequest {
  RecordedRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;

  Object? get json => body.isEmpty ? null : jsonDecode(body);
}

/// One canned response: a whole body, or a stream of chunks for SSE.
final class FakeResponse {
  FakeResponse(
    this.status, {
    Map<String, String> headers = const {},
    String body = '',
  }) : headers = {
         for (final e in headers.entries) e.key.toLowerCase(): e.value,
       },
       chunks = Stream.value(utf8.encode(body));

  FakeResponse.json(this.status, Object? json, {Map<String, String>? headers})
    : headers = {
        'content-type': status < 300
            ? 'application/json'
            : 'application/problem+json',
        ...?headers,
      },
      chunks = Stream.value(utf8.encode(jsonEncode(json)));

  FakeResponse.stream(
    this.status,
    this.chunks, {
    this.headers = const {'content-type': 'text/event-stream'},
  });

  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> chunks;
}

typedef FakeHandler = FutureOr<FakeResponse> Function(RecordedRequest request);

/// An offline [http.Client] that answers from [handler] and records every
/// request. It honours [http.Abortable.abortTrigger] as a real client does:
/// before the handler answers, the request fails with
/// [http.RequestAbortedException]; after, the body stream fails with it.
final class FakeHttpClient extends http.BaseClient {
  FakeHttpClient(this.handler);

  final FakeHandler handler;
  final List<RecordedRequest> requests = [];
  final Map<int, Completer<RecordedRequest>> _awaited = {};

  /// Completes with the [count]th request once it has arrived, or fails
  /// with a [TimeoutException] naming it if it never does.
  Future<RecordedRequest> received(int count) {
    if (requests.length >= count) return Future.value(requests[count - 1]);
    return _awaited
        .putIfAbsent(count, Completer.new)
        .future
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('request $count never sent'),
        );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = utf8.decode(await request.finalize().toBytes());
    final recorded = RecordedRequest(request.method, request.url, {
      for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
    }, body);
    requests.add(recorded);
    _awaited.remove(requests.length)?.complete(recorded);
    final abortTrigger = switch (request) {
      http.Abortable(:final abortTrigger?) => abortTrigger,
      _ => null,
    };
    final answer = Future.value(handler(recorded));
    final response = abortTrigger == null
        ? await answer
        : await Future.any([
            answer,
            abortTrigger.then<FakeResponse>(
              (_) => throw http.RequestAbortedException(request.url),
            ),
          ]);
    final controller = StreamController<List<int>>();
    final subscription = response.chunks.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then((_) async {
          if (controller.isClosed) return;
          await subscription.cancel();
          controller.addError(http.RequestAbortedException(request.url));
          await controller.close();
        }),
      );
    }
    return http.StreamedResponse(
      controller.stream,
      response.status,
      headers: response.headers,
      request: request,
    );
  }
}
