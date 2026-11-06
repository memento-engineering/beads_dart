import 'dart:async';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

/// An [http.Client] that answers every request by calling a shelf [Handler]
/// in process: no socket, no port, no network.
///
/// It lets a `ScopeClient` talk to `authorityHandler` exactly as it would
/// over HTTP, streamed bodies (the SSE changefeed) included. It honours
/// [http.Abortable.abortTrigger] as a real client does: before the handler
/// answers, the request fails with [http.RequestAbortedException]; after,
/// the body stream fails with it and the handler's stream is cancelled.
final class HandlerClient extends http.BaseClient {
  /// A client whose every request is answered by [handler].
  HandlerClient(this._handler);

  final Handler _handler;

  /// Delivers [request] to the handler, which acts on it as it would over
  /// HTTP: a mutation sent through here is committed.
  @effect
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final abortTrigger = switch (request) {
      http.Abortable(:final abortTrigger?) => abortTrigger,
      _ => null,
    };
    final answer = Future.sync(
      () => _handler(
        Request(
          request.method,
          request.url,
          headers: request.headers,
          body: body,
        ),
      ),
    );
    final Response response;
    if (abortTrigger == null) {
      response = await answer;
    } else {
      response = await Future.any([answer, _aborted(abortTrigger, request)]);
    }
    final out = StreamController<List<int>>();
    final subscription = response.read().listen(
      out.add,
      onError: out.addError,
      onDone: out.close,
    );
    out.onCancel = subscription.cancel;
    if (abortTrigger != null) {
      unawaited(_abortBody(abortTrigger, request, subscription, out));
    }
    return http.StreamedResponse(
      out.stream,
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }

  static Future<Response> _aborted(
    Future<void> trigger,
    http.BaseRequest request,
  ) async {
    await trigger;
    throw http.RequestAbortedException(request.url);
  }

  static Future<void> _abortBody(
    Future<void> trigger,
    http.BaseRequest request,
    StreamSubscription<List<int>> body,
    StreamController<List<int>> out,
  ) async {
    await trigger;
    if (out.isClosed) return;
    await body.cancel();
    out.addError(http.RequestAbortedException(request.url));
    await out.close();
  }
}
