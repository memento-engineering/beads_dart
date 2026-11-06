import 'dart:convert';

import 'package:bdp/bdp.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'scope.dart';

/// The principal named by a request's `x-principal` field, for tests that
/// need more than the anonymous one.
String principalFromHeader(Request request) =>
    request.headers['x-principal'] ?? authorityAnonymousPrincipal;

/// Sends one request to [handler] for [target], resolved against the Scope
/// URL (an absolute target is used as is).
Future<Response> sendTo(
  Handler handler,
  String method,
  String target, {
  Map<String, String> headers = const {},
  Object? body,
}) async => handler(
  Request(
    method,
    Uri.parse(scope).resolve(target),
    headers: headers,
    body: body == null ? null : jsonEncode(body),
  ),
);

/// The decoded JSON body of [response].
Future<Json> jsonOf(Response response) async =>
    jsonDecode(await response.readAsString()) as Json;

/// [headers] with every BDP context field rewritten from a fixture's
/// illustrative tokens to [authority]'s: a token ending `-old` stays a
/// foreign token, a minimum position the fixture narrates as later than the
/// head becomes one past it, and every other token becomes the current one.
Map<String, String> localizeHeaders(
  Map<String, Object?> headers,
  ScopeAuthority authority,
) {
  final current = authority.observe();
  return {
    for (final MapEntry(:key, :value) in headers.entries)
      key.toLowerCase(): switch ((key.toLowerCase(), value! as String)) {
        ('bdp-scope-epoch', final v) =>
          v.endsWith('-old') ? 'stale-epoch' : current.epoch,
        ('bdp-authorization-view', final v) =>
          v.endsWith('-old') ? 'stale-view' : authorityViewToken,
        ('bdp-minimum-scope-position', final v) =>
          v.contains('later')
              ? 'p${int.parse(current.position.substring(1)) + 1}'
              : current.position,
        (_, final v) => v,
      },
  };
}

/// Asserts [response] carries [expected]'s fixture fields: the BDP context
/// fields present (their tokens are per-Scope), every other field equal,
/// and no `Content-Type` on a bodyless refusal or precondition outcome.
void expectFixtureHeaders(
  Response response,
  Map<String, Object?> expected, {
  String? reason,
}) {
  final want = {
    for (final e in expected.entries) e.key.toLowerCase(): e.value! as String,
  };
  for (final MapEntry(:key, :value) in want.entries) {
    if (key.startsWith('bdp-')) {
      expect(response.headers[key], isNotEmpty, reason: '$reason: $key');
    } else {
      expect(response.headers[key], value, reason: '$reason: $key');
    }
  }
  if (!want.containsKey('content-type')) {
    expect(
      response.headers['content-type'],
      isNull,
      reason: '$reason: content-type',
    );
  }
}

/// Asserts a problem body matches the fixture's problem in its closed
/// members and validates against the bundle.
void expectFixtureProblem(Json problem, Json expected, {String? reason}) {
  expectSchema(problem, 'transactionalProblem');
  for (final member in ['type', 'status', 'code', 'retry']) {
    expect(problem[member], expected[member], reason: '$reason: $member');
  }
}
