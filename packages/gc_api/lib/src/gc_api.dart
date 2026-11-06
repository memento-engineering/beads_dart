import 'dart:async';
import 'dart:convert';

import 'package:bdp/client.dart' show SseMessage, SseRetry, decodeSse;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'problem.dart';

/// A client for the Gas City supervisor's HTTP API at [baseUri], by default
/// `http://127.0.0.1:8372`.
///
/// Per-city routes are reached through [city]. Every read is a GET; nothing
/// here mutates the city, so a read-only supervisor (one bound beyond
/// loopback without `allow_mutations`) serves all of it.
final class GcApi {
  GcApi({
    required http.Client httpClient,
    Uri? baseUri,
    Map<String, String> headers = const {},
    this.reconnectDelay = const Duration(seconds: 1),
  }) : baseUri = baseUri ?? Uri.parse('http://127.0.0.1:8372'),
       _http = httpClient,
       _headers = Map.unmodifiable(headers);

  /// The supervisor's root.
  final Uri baseUri;

  /// The wait before a dropped event stream reconnects, until the server's
  /// SSE `retry` field replaces it.
  final Duration reconnectDelay;

  final http.Client _http;

  /// Sent on every request.
  final Map<String, String> _headers;

  /// `GET /health`.
  Future<SupervisorHealth> health() =>
      _get(_uri(['health']), SupervisorHealth.fromJson);

  /// `GET /v0/cities`: every city the supervisor manages.
  Future<List<CityInfo>> cities() => _get(_uri(['v0', 'cities']), (json) {
    final items = switch (json) {
      {'items': final List<Object?> items} => items,
      {'items': null} => const <Object?>[],
      _ => throw const FormatException('items is not an array'),
    };
    return [for (final item in items) CityInfo.fromJson(item)];
  });

  /// The routes of the city called [name].
  GcCity city(String name) => GcCity._(this, name);

  Uri _uri(List<String> segments, [Map<String, String> query = const {}]) =>
      baseUri.replace(
        pathSegments: [
          ...baseUri.pathSegments.where((s) => s.isNotEmpty),
          ...segments,
        ],
        queryParameters: query.isEmpty ? null : query,
      );

  Future<T> _get<T>(Uri uri, T Function(Object? json) decode) async {
    final response = await _http.get(
      uri,
      headers: {..._headers, 'accept': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw _failure(uri, response.statusCode, response.headers, response.body);
    }
    return _decode(uri, response.body, decode);
  }
}

/// The routes of one city, under `/v0/city/{name}`.
final class GcCity {
  GcCity._(this._api, this.name);

  final GcApi _api;

  final String name;

  /// `GET /v0/city/{name}/status`.
  Future<CityStatus> status() =>
      _api._get(_uri(['status']), CityStatus.fromJson);

  /// `GET /v0/city/{name}/events`: one page of the event log, newest first.
  ///
  /// [cursor] is a page's [EventPage.nextCursor]; [type] and [actor] filter
  /// by exact match; [since] is a Go duration such as `1h`.
  Future<EventPage> events({
    String? cursor,
    int? limit,
    String? type,
    String? actor,
    String? since,
  }) => _api._get(
    _uri(
      ['events'],
      {
        'cursor': ?cursor,
        'limit': ?limit?.toString(),
        'type': ?type,
        'actor': ?actor,
        'since': ?since,
      },
    ),
    EventPage.fromJson,
  );

  /// `GET /v0/city/{name}/events/stream`: the city's events as they happen,
  /// oldest first.
  ///
  /// It starts after [afterSeq] when given, replaying every later event the
  /// log still holds, and at the log's head otherwise. A dropped connection,
  /// or a timeout, rate limit or server error, reconnects after the last
  /// event delivered, so no event is delivered twice or skipped. A Problem
  /// Details refusal, a 4xx, or a body that is not the API's ends the stream
  /// with a [GcApiException]. Cancelling the subscription closes the
  /// connection.
  Stream<GcEvent> follow({int? afterSeq}) {
    late final _Follower follower;
    final controller = StreamController<GcEvent>(
      onListen: () => unawaited(follower.run()),
      onCancel: () => follower.stop(),
    );
    follower = _Follower(this, afterSeq, controller);
    return controller.stream;
  }

  Uri _uri(List<String> segments, [Map<String, String> query = const {}]) =>
      _api._uri(['v0', 'city', name, ...segments], query);
}

final class _Follower {
  _Follower(this._city, this._afterSeq, this._out)
    : _delay = _city._api.reconnectDelay;

  final GcCity _city;
  final StreamController<GcEvent> _out;
  final Completer<void> _stop = Completer();

  /// The seq of the last event delivered: the reconnect cursor.
  int? _afterSeq;

  Duration _delay;

  bool get _stopped => _stop.isCompleted;

  Future<void> stop() async {
    if (!_stop.isCompleted) _stop.complete();
  }

  Future<void> run() async {
    while (!_stopped) {
      try {
        await _stream();
      } on Object catch (error, stackTrace) {
        if (_stopped) break;
        if (!_transient(error)) {
          _out.addError(error, stackTrace);
          break;
        }
      }
      await _pause();
    }
    await _out.close();
  }

  Future<void> _stream() async {
    final uri = _city._uri(
      ['events', 'stream'],
      {'after_seq': ?_afterSeq?.toString()},
    );
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: _stop.future,
    )..headers.addAll({..._city._api._headers, 'accept': 'text/event-stream'});
    final response = await _orStop(_city._api._http.send(request));
    if (response.statusCode != 200) {
      throw _failure(
        uri,
        response.statusCode,
        response.headers,
        await _orStop(response.stream.bytesToString()),
      );
    }
    final type = response.headers['content-type'] ?? '';
    if (!type.startsWith('text/event-stream')) {
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      throw GcProtocolException(uri, 'expected text/event-stream, got $type');
    }
    // Each read is raced against [stop], so a client that ignores the abort
    // cannot hold a cancelled stream open.
    final frames = StreamIterator(decodeSse(response.stream));
    try {
      while (await _orStop(frames.moveNext())) {
        switch (frames.current) {
          case SseRetry(:final delay):
            _delay = delay;
          case SseMessage(event: 'event', :final data):
            final event = _decode(uri, data, GcEvent.fromJson);
            if (_afterSeq case final after? when event.seq <= after) {
              throw GcProtocolException(
                uri,
                'event ${event.seq} is not after $after',
              );
            }
            _out.add(event);
            _afterSeq = event.seq;
          case SseMessage():
            // Heartbeats keep the connection open and carry nothing.
            break;
        }
      }
    } finally {
      // Not awaited: a body that ignores the abort may never finish
      // cancelling.
      unawaited(frames.cancel().catchError((Object _) {}));
    }
  }

  /// Completes with [work], or fails with [_Stopped] once [stop] is called.
  Future<T> _orStop<T>(Future<T> work) =>
      Future.any([work, _stop.future.then<T>((_) => throw const _Stopped())]);

  bool _transient(Object error) => switch (error) {
    http.ClientException() => true,
    GcHttpException(:final transient) => transient,
    GcProblemException(:final status) => status >= 500 || status == 429,
    _ => false,
  };

  Future<void> _pause() async {
    if (_stopped) return;
    await Future.any([Future<void>.delayed(_delay), _stop.future]);
  }
}

/// The follower was stopped while it waited.
final class _Stopped implements Exception {
  const _Stopped();
}

/// The exception for a response of [status] whose body is [body].
GcApiException _failure(
  Uri uri,
  int status,
  Map<String, String> headers,
  String body,
) {
  final type = headers['content-type'] ?? '';
  if (type.startsWith('application/problem+json')) {
    try {
      return GcProblemException(
        uri,
        status: status,
        problem: GcProblem.fromJson(jsonDecode(body)),
      );
    } on FormatException {
      // A malformed problem is reported as the bare status below.
    }
  }
  return GcHttpException(uri, status: status, body: body);
}

/// [body] decoded as JSON and read by [decode]; a body that is not JSON, or
/// is not the shape [decode] reads, is a [GcProtocolException].
T _decode<T>(Uri uri, String body, T Function(Object? json) decode) {
  try {
    return decode(jsonDecode(body));
  } on FormatException catch (error) {
    throw GcProtocolException(uri, error.message);
  }
}
