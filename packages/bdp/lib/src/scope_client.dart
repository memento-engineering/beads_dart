import 'dart:async';
import 'dart:convert';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;
import 'package:http/http.dart' as http;

import 'changefeed.dart';
import 'discovery.dart';
import 'http_response.dart';
import 'json.dart';
import 'local_scope.dart';
import 'operations.dart';
import 'problem.dart';
import 'receipts.dart';
import 'records.dart';
import 'snapshot.dart';
import 'sse.dart';
import 'tokens.dart';
import 'types.dart';

/// A BDP Scope reached over HTTP through an injected [http.Client].
///
/// A client is bound to one discovery document. Problem responses become
/// [BdpProblemException]s carrying the problem and the HTTP status;
/// bodyless HTTP refusals become [BdpHttpException]s; a success body that
/// does not match its wire shape is a [BdpProtocolException].
final class ScopeClient implements LocalScope {
  /// A client for the Scope [discovery] describes, using [operations] as its
  /// Operation Directory when the profile has one.
  ScopeClient({
    required http.Client httpClient,
    required this.discovery,
    this.operations,
    Map<String, String> headers = const {},
    this.reconnectDelay = const Duration(seconds: 1),
  }) : _http = httpClient,
       _headers = Map.unmodifiable(headers);

  /// Discovers the Scope at [scope]: follows the Scope response's
  /// `service-desc` link to the discovery document and, above Read, reads
  /// the Operation Directory.
  ///
  /// [headers] are sent on every request, e.g. an `authorization` field.
  static Future<ScopeClient> discover(
    Uri scope, {
    required http.Client httpClient,
    Map<String, String> headers = const {},
    Duration reconnectDelay = const Duration(seconds: 1),
  }) async {
    final landing = await httpClient.get(scope, headers: headers);
    if (landing.statusCode != 200 && landing.statusCode != 204) {
      throw classifyFailure(
        scope,
        landing.statusCode,
        landing.headers,
        landing.bodyBytes,
      );
    }
    final description = _serviceDescription(scope, landing.headers['link']);
    if (description == null) {
      throw BdpProtocolException(
        uri: scope,
        message: 'the Scope response carries no service-desc link',
      );
    }
    final json = {...headers, 'accept': 'application/json'};
    final discovery = readResponse(
      description,
      await httpClient.get(description, headers: json),
      ScopeDiscovery.fromJson,
    );
    OperationDirectory? operations;
    if (discovery.operations case final directory?) {
      final uri = Uri.parse(directory);
      operations = readResponse(
        uri,
        await httpClient.get(uri, headers: json),
        OperationDirectory.fromJson,
      );
    }
    return ScopeClient(
      httpClient: httpClient,
      discovery: discovery,
      operations: operations,
      headers: headers,
      reconnectDelay: reconnectDelay,
    );
  }

  final http.Client _http;
  final Map<String, String> _headers;

  @override
  final ScopeDiscovery discovery;

  /// The Operation Directory, above Read.
  final OperationDirectory? operations;

  /// How long a live changefeed waits before reconnecting when the server
  /// suggests no delay.
  final Duration reconnectDelay;

  @override
  Future<BeadRecord> readBead(String bead) =>
      _get(_resource(bead, discovery.beads), BeadRecord.fromJson);

  @override
  Future<LinkRecord> readLink(String link) =>
      _get(_resource(link, discovery.links), LinkRecord.fromJson);

  @override
  Future<Page<BeadRecord>> beads([BeadQuery query = const BeadQuery()]) =>
      _get(_query(discovery.beads, query.queryParameters), _beadPage);

  @override
  Future<Page<LinkRecord>> links([LinkQuery query = const LinkQuery()]) =>
      _get(_query(discovery.links, query.queryParameters), _linkPage);

  @override
  Future<Page<LinkRecord>> incidentLinks(
    String bead, {
    LinkDirection direction = LinkDirection.both,
    int? limit,
  }) => _get(
    _query(_resource(bead, discovery.beads).toString(), {
      'view': 'links',
      'direction': direction.name,
      if (limit != null) 'limit': '$limit',
    }),
    _linkPage,
  );

  @override
  Future<Page<BeadRecord>> nextBeads(String next) =>
      _get(Uri.parse(next), _beadPage);

  @override
  Future<Page<LinkRecord>> nextLinks(String next) =>
      _get(Uri.parse(next), _linkPage);

  @override
  Future<Page<TypeSummary>> types({int? limit}) => _get(
    _query(discovery.types, {if (limit != null) 'limit': '$limit'}),
    _typePage,
  );

  @override
  Future<Page<TypeSummary>> nextTypes(String next) =>
      _get(Uri.parse(next), _typePage);

  @override
  Future<TypeDescriptor> readTypeDescriptor(String type) =>
      _get(Uri.parse(type), TypeDescriptor.fromJson);

  @override
  @effect
  Future<MutationResponse> createBead(
    CreateBead operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> updateBeadProperties(
    UpdateBeadProperties operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> deleteBead(
    DeleteBead operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> createLink(
    CreateLink operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> updateLinkProperties(
    UpdateLinkProperties operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> deleteLink(
    DeleteLink operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(operation, idempotencyKey);

  @override
  @effect
  Future<MutationReceipt> batch(
    List<MutationOperation> operations, {
    required IdempotencyKey idempotencyKey,
  }) async {
    _requireTransactional('batch');
    final target = _operationTarget('batch');
    final response = await _post(
      target,
      BatchRequest(operations).toJson(),
      idempotencyKey,
    );
    return readResponse(
      target,
      response,
      MutationReceipt.fromJson,
      ok: _accepted,
    );
  }

  @override
  Future<MutationReceipt> readReceipt(String receipt) =>
      _get(Uri.parse(receipt), MutationReceipt.fromJson);

  @override
  Future<MutationReceiptPage> readReceiptPage(String next) =>
      _get(Uri.parse(next), MutationReceiptPage.fromJson);

  @override
  Future<ChangefeedPage> changes(ChangefeedStart start) =>
      _get(_changesUri(start), ChangefeedPage.fromJson);

  @override
  Future<ChangefeedPage> nextChanges(String next) =>
      _get(Uri.parse(next), ChangefeedPage.fromJson);

  @override
  @effect
  ChangefeedSubscription follow(
    ChangefeedStart start,
    ChangeGroupApplier apply,
  ) {
    _requireTransactional('the changefeed');
    final follower = _ChangefeedFollower(this, start, apply);
    unawaited(follower.run());
    return follower;
  }

  @override
  @effect
  Future<SnapshotManifest> snapshot() {
    _requireTransactional('snapshot');
    return _get(Uri.parse(discovery.snapshot!), SnapshotManifest.fromJson);
  }

  Uri _changesUri(ChangefeedStart start) {
    _requireTransactional('the changefeed');
    return _query(discovery.changes!, start.queryParameters);
  }

  Future<MutationResponse> _singleton(
    MutationOperation operation,
    IdempotencyKey idempotencyKey,
  ) async {
    if (operation.name case final name?) {
      throw ArgumentError.value(name, 'name', 'a singleton carries no label');
    }
    for (final reference in operation.references) {
      if (reference.startsWith('@')) {
        throw ArgumentError.value(
          reference,
          'reference',
          'a singleton cannot use a batch-local label',
        );
      }
    }
    final target = _operationTarget(operation.directoryName);
    final response = await _post(
      target,
      operation.toRequestJson(),
      idempotencyKey,
    );
    return switch (discovery.profile) {
      Profile.transactional => ReceiptResponse(
        readResponse(target, response, MutationReceipt.fromJson, ok: _accepted),
      ),
      Profile.readUpdate || Profile.read => ResultResponse(
        readResponse(target, response, MutationResult.fromJson),
      ),
    };
  }

  Future<http.Response> _post(
    Uri target,
    JsonObject body,
    IdempotencyKey idempotencyKey,
  ) => _http.post(
    target,
    headers: {
      ..._headers,
      'accept': 'application/json',
      'content-type': 'application/json',
      'idempotency-key': idempotencyKey.value,
    },
    body: utf8.encode(jsonEncode(body)),
  );

  Uri _operationTarget(String name) {
    final root = discovery.operations;
    final directory = operations;
    if (root == null || directory == null) {
      throw UnsupportedError(
        'a ${discovery.profile.wire} Scope has no mutation targets',
      );
    }
    final relative = directory[name];
    if (relative == null) {
      throw UnsupportedError('the Operation Directory does not offer $name');
    }
    return Uri.parse(root).resolve(relative);
  }

  void _requireTransactional(String surface) {
    if (discovery.profile != Profile.transactional) {
      throw UnsupportedError(
        '$surface needs a transactional Scope; this one is '
        '${discovery.profile.wire}',
      );
    }
  }

  Uri _resource(String reference, String root) {
    final resolved = Uri.parse(discovery.scope).resolve(reference);
    if (!resolved.toString().startsWith(root)) {
      throw ArgumentError.value(reference, 'reference', 'is not under $root');
    }
    return resolved;
  }

  Future<T> _get<T>(
    Uri uri,
    T Function(Object? json, String path) decode,
  ) async => readResponse(
    uri,
    await _http.get(uri, headers: {..._headers, 'accept': 'application/json'}),
    decode,
  );
}

const Set<int> _accepted = {200, 202};

Page<BeadRecord> _beadPage(Object? json, String path) =>
    Page.fromJson(json, path, BeadRecord.fromJson);

Page<LinkRecord> _linkPage(Object? json, String path) =>
    Page.fromJson(json, path, LinkRecord.fromJson);

Page<TypeSummary> _typePage(Object? json, String path) =>
    Page.fromJson(json, path, TypeSummary.fromJson);

/// Appends [parameters] to [base], percent-encoding every value so a
/// Selector reaches the authority exactly as written.
Uri _query(String base, Map<String, String> parameters) {
  if (parameters.isEmpty) return Uri.parse(base);
  final query = [
    for (final MapEntry(:key, :value) in parameters.entries)
      '${Uri.encodeComponent(key)}=${Uri.encodeComponent(value)}',
  ].join('&');
  return Uri.parse('$base${base.contains('?') ? '&' : '?'}$query');
}

final RegExp _linkValue = RegExp(r'<([^>]*)>([^<]*)');
final RegExp _relParameter = RegExp(
  r'''(?:^|;)\s*rel\s*=\s*(?:"([^"]*)"|([^\s;,]+))''',
  caseSensitive: false,
);

/// The `service-desc` target of an RFC 8288 `Link` field, resolved against
/// [base].
Uri? _serviceDescription(Uri base, String? link) {
  if (link == null) return null;
  for (final match in _linkValue.allMatches(link)) {
    final rel = _relParameter.firstMatch(match.group(2)!);
    final relations = (rel?.group(1) ?? rel?.group(2) ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'));
    if (relations.contains('service-desc')) {
      return base.resolve(match.group(1)!);
    }
  }
  return null;
}

final class _ApplyFailed implements Exception {
  const _ApplyFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

/// The subscription was cancelled while a request was outstanding.
final class _Stopped implements Exception {
  const _Stopped();
}

/// One live changefeed observation.
///
/// The reconnect cursor is the checkpoint of the last group whose apply
/// completed. Requests carry it in `after` and never send `Last-Event-ID`,
/// so transport progress cannot stand in for durable application.
///
/// A `start=now` observation first resolves the head with a finite read.
/// Every request, the finite head read included, is aborted by [cancel],
/// and every request retries a dropped connection, an after-delay problem
/// or a transient HTTP status from where it stood.
final class _ChangefeedFollower implements ChangefeedSubscription {
  _ChangefeedFollower(this._client, ChangefeedStart start, this._apply)
    : _retryDelay = _client.reconnectDelay,
      _durable = switch (start) {
        AfterCheckpoint(:final checkpoint) => checkpoint,
        StartNow() => null,
      },
      _head = switch (start) {
        AfterCheckpoint() => null,
        StartNow() => _client._changesUri(start),
      };

  final ScopeClient _client;
  final ChangeGroupApplier _apply;
  final Completer<void> _done = Completer();
  final Completer<void> _stop = Completer();

  /// The delay before the next reconnect; an SSE `retry` field replaces it.
  Duration _retryDelay;

  /// The checkpoint of the last group applied, or the start checkpoint.
  Checkpoint? _durable;

  /// The next page of the finite `start=now` head read, until it ends.
  Uri? _head;

  bool get _stopped => _stop.isCompleted;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> cancel() async {
    if (!_stop.isCompleted) _stop.complete();
    try {
      await _done.future;
    } on Object {
      // The failure is reported through [done].
    }
  }

  Future<void> run() async {
    try {
      while (!_stopped) {
        try {
          if (_head case final head?) {
            await _readHead(head);
            continue;
          }
          await _stream(_durable!);
          await _pause(_retryDelay);
        } on _ApplyFailed {
          rethrow;
        } on Object catch (error) {
          if (_stopped) break;
          final delay = _transientDelay(error);
          if (delay == null) rethrow;
          await _pause(delay);
        }
      }
      _done.complete();
    } on _ApplyFailed catch (failure) {
      _done.completeError(failure.error, failure.stackTrace);
    } catch (error, stackTrace) {
      _done.completeError(error, stackTrace);
    }
  }

  /// Reads one page of the `start=now` head, applies its groups and moves
  /// to its continuation; the last page's checkpoint is the head.
  Future<void> _readHead(Uri head) async {
    final response = await _send(head, 'application/json');
    final page = readResponse(
      head,
      await _orStop(http.Response.fromStream(response)),
      ChangefeedPage.fromJson,
    );
    for (final group in page.groups) {
      if (_stopped) return;
      await _applyOne(group);
      _durable = group.checkpoint;
    }
    _durable = page.lastCheckpoint;
    _head = switch (page.next) {
      final next? => Uri.parse(next),
      null => null,
    };
  }

  /// Observes the live feed after [durable] until the stream ends.
  Future<void> _stream(Checkpoint durable) async {
    final uri = _client._changesUri(ChangefeedStart.after(durable));
    final response = await _send(uri, 'text/event-stream');
    if (response.statusCode != 200) {
      throw classifyFailure(
        uri,
        response.statusCode,
        response.headers,
        await _orStop(response.stream.toBytes()),
      );
    }
    final mediaType = mediaTypeOf(response.headers['content-type']);
    if (mediaType != 'text/event-stream') {
      await response.stream.drain<void>();
      throw BdpProtocolException(
        uri: uri,
        message: 'expected text/event-stream, got $mediaType',
      );
    }
    // Each read of the body is raced against [cancel], so an idle stream
    // from a client that ignores the abort cannot hold the subscription.
    final frames = StreamIterator(decodeSse(response.stream));
    try {
      while (await _orStop(frames.moveNext())) {
        if (_stopped) break;
        switch (frames.current) {
          case SseRetry(:final delay):
            _retryDelay = delay;
          case SseMessage(event: 'change-group', :final data, :final id):
            final group = _decodeGroup(uri, data, id);
            await _applyOne(group);
            _durable = group.checkpoint;
          case SseMessage():
            // Only change groups advance a replica.
            break;
        }
      }
    } finally {
      // Not awaited: a body that ignores the abort may never finish
      // cancelling, and one that honours it fails its cancellation with the
      // abort, which ends nothing that has not already ended.
      unawaited(_discard(frames.cancel()));
    }
  }

  static Future<void> _discard(Future<void> cancellation) async {
    try {
      await cancellation;
    } on Object {
      // See the caller.
    }
  }

  /// Sends a GET that [cancel] aborts, whether or not the client honours
  /// the abort trigger.
  Future<http.StreamedResponse> _send(Uri uri, String accept) {
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: _stop.future,
    )..headers.addAll({..._client._headers, 'accept': accept});
    return _orStop(_client._http.send(request));
  }

  /// Completes with [work], or fails with [_Stopped] once [cancel] is
  /// called, whichever comes first.
  Future<T> _orStop<T>(Future<T> work) =>
      Future.any([work, _stop.future.then<T>((_) => throw const _Stopped())]);

  /// The delay before retrying after [error], or `null` when [error] ends
  /// the subscription.
  Duration? _transientDelay(Object error) => switch (error) {
    http.ClientException() => _retryDelay,
    BdpProblemException(:final problem, :final retryAfter)
        when problem.retry == RetryDisposition.afterDelay =>
      retryAfter ?? _retryDelay,
    BdpHttpException(:final retryAfter, transient: true) =>
      retryAfter ?? _retryDelay,
    _ => null,
  };

  ChangeGroup _decodeGroup(Uri uri, String data, String? id) {
    final group = decodeBody(uri, utf8.encode(data), ChangeGroup.fromJson);
    if (id != group.checkpoint.value) {
      throw BdpProtocolException(
        uri: uri,
        message: 'SSE id "$id" is not the group checkpoint ${group.checkpoint}',
      );
    }
    return group;
  }

  Future<void> _applyOne(ChangeGroup group) async {
    try {
      await _apply(group);
    } catch (error, stackTrace) {
      throw _ApplyFailed(error, stackTrace);
    }
  }

  Future<void> _pause(Duration delay) async {
    if (_stopped) return;
    await Future.any([Future<void>.delayed(delay), _stop.future]);
  }
}
