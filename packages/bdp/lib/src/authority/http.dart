import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;
import 'package:shelf/shelf.dart';

import 'authority.dart';
import 'authority_scope.dart';
import 'identity.dart';
import 'json_text.dart';
import 'problem.dart';

const _json = 'application/json';
const _eventStream = 'text/event-stream';
const _private = 'private, no-store';

/// A shelf [Handler] serving [authority]'s Scope over HTTP with the BDP wire
/// shapes: discovery, Resource and collection reads, the singleton and
/// `batch` targets, receipts, the changefeed (JSON and SSE), Event Sources
/// and snapshots.
///
/// Requests are routed by their path below the canonical Scope URL's path,
/// so the server must be reachable at that path. [principalOf] names the
/// authenticated principal of a request; by default every caller is the
/// anonymous principal.
///
/// Each read decides, in order: query parameters, the target and its
/// non-disclosure, the minimum-position context, response negotiation
/// (`406`), then HTTP preconditions (`304` / `412`), so an ordinary refusal
/// is never replaced by a negotiation or conditional outcome.
///
/// An unexpected fault is answered with a bodyless `500` that keeps its
/// details off the wire, as the BDP HTTP rules require, and is handed to
/// [onFault]; by default it is written to standard error.
///
/// The returned [Handler] commits and opens streams over [authority] for
/// the requests it serves. It is a function value, so `genesis_lint` does
/// not see what calling it does: call it only from code that owns those
/// effects.
Handler authorityHandler(
  AuthorityScope authority, {
  String Function(Request request)? principalOf,
  void Function(Object error, StackTrace stack)? onFault,
}) {
  return _Routes(
    authority,
    principalOf ?? (_) => authorityAnonymousPrincipal,
    onFault ?? _reportToStderr,
  ).serve;
}

void _reportToStderr(Object error, StackTrace stack) =>
    stderr.writeln('bdp authority: internal fault: $error\n$stack');

/// An HTTP-native refusal with no BDP problem body.
final class _Bodyless implements Exception {
  const _Bodyless(this.response);
  final Response response;
}

Response _problem(AuthorityProblem problem, Map<String, String> context) =>
    Response(
      problem.status,
      body: jsonEncode(problem.toJson()),
      headers: {
        'content-type': 'application/problem+json',
        'cache-control': _private,
        ...context,
        if (problem.retry == 'after-delay') 'retry-after': '1',
      },
    );

/// The bodyless `406`, with the Scope context.
_Bodyless _notAcceptable(Map<String, String> context) =>
    _Bodyless(Response(406, headers: {'cache-control': _private, ...context}));

AuthorityProblem _invalidParameter(String title) =>
    AuthorityProblem('invalid-parameter', title: title);

final class _Routes {
  _Routes(this.authority, this.principalOf, this.report);

  final AuthorityScope authority;
  final String Function(Request) principalOf;
  final void Function(Object error, StackTrace stack) report;

  ScopeAddress get address => authority.address;

  /// Answers [request], turning a refusal into its response and an
  /// unexpected fault into a bodyless `500` it reports.
  @effect
  Future<Response> serve(Request request) async {
    try {
      return await handle(request);
    } on AuthorityProblem catch (problem) {
      return _problem(problem, currentContext());
    } on _Bodyless catch (bodyless) {
      return bodyless.response;
    } catch (error, stack) {
      report(error, stack);
      return Response(500);
    }
  }

  @effect
  FutureOr<Response> handle(Request request) {
    final scopePath = Uri.parse(address.scope).path;
    final path = request.requestedUri.path;
    if (!path.startsWith(scopePath)) throw _notFound();
    final relative = path.substring(scopePath.length);
    if (relative.startsWith('operations/') && relative != 'operations/') {
      _methods(request, const ['POST']);
      return _mutate(request, relative.substring('operations/'.length));
    }
    _methods(request, const ['GET', 'HEAD']);
    return switch (relative) {
      '' => _scopeRoot(),
      'bdp.json' => _read(request, {}, (_) => authority.discoveryDocument()),
      'operations/' => _read(
        request,
        {},
        (_) => authority.operationDirectory(),
      ),
      'types/' => _read(request, {
        'limit',
        'cursor',
      }, (p) => authority.typeInventory(limit: _limit(p), cursor: p['cursor'])),
      'beads/' => _collection(request, AuthorityResourceKind.bead),
      'links/' => _collection(request, AuthorityResourceKind.link),
      'receipts/' => throw _notFound(),
      'snapshot' => _snapshot(request),
      'changes/' => _changes(request),
      'events/' => _events(request, null),
      _ when relative.startsWith('beads/') || relative.startsWith('links/') =>
        _resource(request, '${address.scope}$relative'),
      _ when relative.startsWith('receipts/') => _receipt(
        request,
        relative.substring('receipts/'.length),
      ),
      _ => throw _notFound(),
    };
  }

  static AuthorityProblem _notFound() =>
      AuthorityProblem('resource-not-found', title: 'No such Resource');

  void _methods(Request request, List<String> allowed) {
    if (!allowed.contains(request.method)) {
      throw _Bodyless(Response(405, headers: {'allow': allowed.join(', ')}));
    }
  }

  Response _scopeRoot() => Response(
    204,
    headers: {
      'link': '<bdp.json>; rel="service-desc"; type="application/json"',
    },
  );

  /// The parameters of [request], refusing unknown or repeated ones.
  Map<String, String> _parameters(Request request, Set<String> allowed) {
    final all = request.requestedUri.queryParametersAll;
    for (final entry in all.entries) {
      if (!allowed.contains(entry.key)) {
        throw _invalidParameter('Unsupported parameter ${entry.key}');
      }
      if (entry.value.length != 1) {
        throw _invalidParameter('Repeated parameter ${entry.key}');
      }
    }
    return {for (final e in all.entries) e.key: e.value.single};
  }

  static int? _limit(Map<String, String> parameters) {
    final text = parameters['limit'];
    if (text == null) return null;
    return int.tryParse(text) ??
        (throw _invalidParameter('limit is an integer'));
  }

  /// Negotiates the response media type among [offered]; null when the
  /// request accepts none of them.
  static String? _negotiate(Request request, List<String> offered) {
    final header = request.headers['accept'];
    if (header == null || header.trim().isEmpty) return offered.first;
    var best = (offered.first, -1.0);
    for (final media in offered) {
      final [type, subtype] = media.split('/');
      var quality = -1.0;
      var specificity = -1;
      for (final range in header.split(',')) {
        final parts = range.split(';').map((p) => p.trim()).toList();
        final rangeSplit = parts.first.toLowerCase().split('/');
        if (rangeSplit.length != 2) continue;
        final level = switch (rangeSplit) {
          [final t, final s] when t == type && s == subtype => 2,
          [final t, '*'] when t == type => 1,
          ['*', '*'] => 0,
          _ => -1,
        };
        if (level <= specificity) continue;
        var q = 1.0;
        for (final p in parts.skip(1)) {
          if (p.startsWith('q=')) q = double.tryParse(p.substring(2)) ?? 0;
        }
        (specificity, quality) = (level, q);
      }
      if (quality > best.$2) best = (media, quality);
    }
    return best.$2 <= 0 ? null : best.$1;
  }

  /// The current Scope context, for a response with no representation; empty
  /// when the store cannot be read, so the original refusal still goes out.
  Map<String, String> currentContext() {
    try {
      return _readContext(authority.observe());
    } on Object {
      return const {};
    }
  }

  Map<String, String> _readContext(AuthorityRead read) =>
      _context(read.epoch, read.position);

  Map<String, String> _context(String epoch, String position) => {
    'bdp-scope-epoch': epoch,
    'bdp-authorization-view': authorityViewToken,
    'bdp-scope-position': position,
  };

  /// Applies the minimum-position read context, when the request carries
  /// one, to a read that already passed non-disclosure.
  void _minimum(Request request, AuthorityRead observed) {
    final position = request.headers['bdp-minimum-scope-position'];
    if (position == null) return;
    authority.requireMinimum(
      epoch: request.headers['bdp-scope-epoch'],
      view: request.headers['bdp-authorization-view'],
      position: position,
      observed: observed,
    );
  }

  /// Negotiates among [offered] for a read that observed [context], refusing
  /// with the bodyless `406`.
  static String _accept(
    Request request,
    List<String> offered,
    Map<String, String> context,
  ) => _negotiate(request, offered) ?? (throw _notAcceptable(context));

  /// A JSON read of the Scope: parameters, minimum position, negotiation,
  /// then preconditions against [etag].
  Response _read(
    Request request,
    Set<String> allowed,
    AuthorityRead Function(Map<String, String> parameters) read, {
    String? Function(AuthorityRead)? etag,
    Object? Function(AuthorityRead)? body,
  }) {
    final parameters = _parameters(request, allowed);
    final result = read(parameters);
    _minimum(request, result);
    final context = _readContext(result);
    _accept(request, const [_json], context);
    final tag = etag?.call(result);
    final headers = {
      'content-type': _json,
      'cache-control': _private,
      ...context,
      'etag': ?tag,
    };
    final precondition = _precondition(request, tag);
    if (precondition != null) {
      return Response(
        precondition,
        headers: {...headers}..remove('content-type'),
      );
    }
    if (request.method == 'HEAD') return Response.ok(null, headers: headers);
    return Response.ok(
      jsonEncode(body?.call(result) ?? result.body),
      headers: headers,
    );
  }

  /// The status an HTTP precondition selects, or null to proceed.
  static int? _precondition(Request request, String? etag) {
    List<String> tags(String header) =>
        header.split(',').map((t) => t.trim()).toList();
    final ifMatch = request.headers['if-match'];
    if (ifMatch != null) {
      final list = tags(ifMatch);
      if (!list.contains('*') && (etag == null || !list.contains(etag))) {
        return 412;
      }
    }
    final ifNoneMatch = request.headers['if-none-match'];
    if (ifNoneMatch != null) {
      final list = tags(ifNoneMatch);
      if (list.contains('*') || (etag != null && list.contains(etag))) {
        return 304;
      }
    }
    return null;
  }

  @effect
  Response _resource(Request request, String id) {
    final view = request.requestedUri.queryParameters['view'];
    switch (view) {
      case null:
        return _read(
          request,
          {},
          (_) => authority.resource(id),
          etag: (r) => '"${r.body['revision']}"',
        );
      case 'properties':
        return _read(
          request,
          {'view'},
          (_) => authority.resource(id),
          etag: (r) => '"${r.body['revision']}"',
          body: (r) => r.body['properties'],
        );
      case 'links':
        return _read(request, {'view', 'direction', 'limit', 'cursor'}, (p) {
          final direction = p['direction'] ?? 'both';
          if (!const {'inbound', 'outbound', 'both'}.contains(direction)) {
            throw _invalidParameter('direction is inbound, outbound or both');
          }
          return authority.incidentLinkPage(
            id,
            direction: direction,
            limit: _limit(p),
            cursor: p['cursor'],
          );
        });
      case 'events':
        return _events(request, id);
      default:
        throw _invalidParameter('Unsupported view');
    }
  }

  Response _collection(Request request, AuthorityResourceKind kind) => _read(
    request,
    {
      'type',
      'conformsTo',
      'limit',
      'cursor',
      if (kind == AuthorityResourceKind.link) ...{
        'source',
        'target',
        'endpoint',
      },
    },
    (p) => authority.collection(
      kind,
      type: p['type'],
      conformsTo: p['conformsTo'],
      source: p['source'],
      target: p['target'],
      endpoint: p['endpoint'],
      limit: _limit(p),
      cursor: p['cursor'],
    ),
  );

  Response _receipt(Request request, String token) => _read(
    request,
    {},
    (_) => authority.receipt(token, principal: principalOf(request)),
  );

  @effect
  Response _snapshot(Request request) => _read(request, {'snapshot'}, (p) {
    final handle = p['snapshot'];
    return handle == null
        ? authority.snapshotDocument()
        : authority.snapshotHandle(handle);
  });

  @effect
  Response _changes(Request request) {
    final p = _parameters(request, {'after', 'start'});
    if (p.containsKey('start') && p['start'] != 'now') {
      throw _invalidParameter('start is "now"');
    }
    if (p.containsKey('start') && p.containsKey('after')) {
      throw _invalidParameter('Supply exactly one of after and start=now');
    }
    final after = request.headers['last-event-id'] ?? p['after'];
    final startNow =
        p.containsKey('start') && !request.headers.containsKey('last-event-id');
    final page = authority.changePage(
      after: startNow ? null : after,
      startNow: startNow,
    );
    _minimum(request, page);
    final context = _readContext(page);
    final media = _accept(request, const [_json, _eventStream], context);
    final finite = _finite(request, media, context, page);
    if (finite != null) return finite;
    final frames = authority
        .watch(after: startNow ? page.body['after']! as String : after)
        .map(
          (group) =>
              'id: ${group['checkpoint']}\nevent: change-group\ndata: ${jsonEncode(group)}\n\n',
        );
    return _stream(context, frames);
  }

  @effect
  Response _events(Request request, String? resource) {
    final p = _parameters(request, {
      'after',
      'limit',
      if (resource != null) 'view',
    });
    final after = request.headers['last-event-id'] ?? p['after'];
    final first = authority.events(
      resource: resource,
      after: after,
      limit: _limit(p),
    );
    _minimum(request, first);
    final context = _readContext(first);
    final media = _accept(request, const [_json, _eventStream], context);
    return _finite(request, media, context, first) ??
        _stream(context, _eventFrames(resource, after));
  }

  /// The response to an observation read that does not open a stream: a
  /// precondition outcome, a HEAD, or the finite JSON page. Null means
  /// stream [media] `text/event-stream`. Finite pages carry no validator.
  static Response? _finite(
    Request request,
    String media,
    Map<String, String> context,
    AuthorityRead page,
  ) {
    final headers = {
      'content-type': media,
      'cache-control': media == _json ? _private : 'no-store, no-transform',
      ...context,
    };
    final precondition = _precondition(request, null);
    if (precondition != null) {
      return Response(
        precondition,
        headers: {...headers}..remove('content-type'),
      );
    }
    if (request.method == 'HEAD') return Response.ok(null, headers: headers);
    return media == _json
        ? Response.ok(jsonEncode(page.body), headers: headers)
        : null;
  }

  /// Every Event of the source after [after], then each new one as groups
  /// commit, as SSE frames.
  @effect
  Stream<String> _eventFrames(String? resource, String? after) async* {
    var cursor = after;
    // Watch from the head as it stands before the first page is read, so a
    // group committed while pages are being sent still wakes the loop.
    final mark = authority.changePage(startNow: true).body['after']! as String;
    final commits = StreamIterator(authority.watch(after: mark));
    try {
      while (true) {
        while (true) {
          final page = authority.events(resource: resource, after: cursor).body;
          for (final event in (page['events']! as List).cast<JsonMap>()) {
            cursor = event['id']! as String;
            yield 'id: $cursor\nevent: ${event['type']}\ndata: ${jsonEncode(event)}\n\n';
          }
          if (page['next'] == null) break;
        }
        if (!await commits.moveNext()) return;
      }
    } finally {
      await commits.cancel();
    }
  }

  static Response _stream(Map<String, String> context, Stream<String> frames) {
    final headers = {
      'content-type': _eventStream,
      'cache-control': 'no-store, no-transform',
      ...context,
    };
    return Response.ok(
      frames.map<List<int>>(utf8.encode),
      headers: headers,
      context: {'shelf.io.buffer_output': false},
    );
  }

  @effect
  Future<Response> _mutate(Request request, String target) async {
    final length = request.contentLength;
    if (length != null && length > ScopeAuthority.maximumBodyBytes) {
      throw AuthorityProblem(
        'request-too-large',
        title: 'Request body is too large',
      );
    }
    final type = request.mimeType;
    if (type != _json) {
      throw AuthorityProblem(
        'unsupported-media-type',
        title: 'Body is not application/json',
      );
    }
    final keys = request.headersAll['idempotency-key'];
    if (keys == null || keys.length != 1) {
      throw AuthorityProblem(
        'malformed-request',
        title: 'Idempotency-Key field is required',
      );
    }
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > ScopeAuthority.maximumBodyBytes) {
        throw AuthorityProblem(
          'request-too-large',
          title: 'Request body is too large',
        );
      }
    }
    final StrictJson body;
    try {
      body = parseStrictJson(utf8.decode(bytes));
    } on FormatException {
      throw AuthorityProblem('malformed-request', title: 'Body is not UTF-8');
    } on JsonTextException catch (e) {
      throw AuthorityProblem(
        'malformed-request',
        title: e.message,
        pointer: e.pointer,
      );
    }
    // An unknown key is refused with 406 before admission; a retained
    // duplicate is compared first, then refused without being re-served.
    final acceptable = _negotiate(request, const [_json]) != null;
    final AuthorityReceipt receipt;
    try {
      receipt = await authority.mutate(
        target,
        body.value,
        idempotencyKey: keys.single,
        principal: principalOf(request),
        inadmissibleNumbers: body.inadmissibleNumbers,
        admitNew: acceptable,
      );
    } on AuthorityNotAdmitted {
      throw _notAcceptable(currentContext());
    }
    final context = _context(
      receipt.json['scopeEpoch']! as String,
      receipt.position,
    );
    if (!acceptable) throw _notAcceptable(context);
    return Response.ok(
      jsonEncode(receipt.json),
      headers: {'content-type': _json, 'cache-control': _private, ...context},
    );
  }
}
