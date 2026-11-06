import 'json_text.dart';

/// The BDP problem-family prefix.
const problemTypePrefix = 'https://github.com/gastownhall/bdp/problems/';

/// One row of the closed problem table: family suffix, HTTP status, retry.
typedef _Row = (String family, int status, String retry);

const Map<String, _Row> _table = {
  'malformed-request': ('request', 400, 'never'),
  'invalid-parameter': ('request', 400, 'never'),
  'unauthenticated': ('authentication', 401, 'after-state-change'),
  'forbidden': ('authorization', 403, 'after-state-change'),
  'resource-not-found': ('not-found', 404, 'after-state-change'),
  'foreign-view': ('conflict', 409, 'after-state-change'),
  'cursor-expired': ('gone', 410, 'after-state-change'),
  'request-too-large': ('size', 413, 'never'),
  'limit-exceeded': ('size', 413, 'never'),
  'temporarily-unavailable': ('unavailable', 503, 'after-delay'),
  'unsupported-media-type': ('request', 415, 'never'),
  'validation-failed': ('validation', 422, 'never'),
  'type-not-installed': ('validation', 422, 'after-state-change'),
  'identity-taken': ('conflict', 409, 'never'),
  'revision-mismatch': ('conflict', 409, 'after-state-change'),
  'incident-links-exist': ('conflict', 409, 'after-state-change'),
  'idempotency-conflict': ('conflict', 409, 'never'),
  'catch-up-timeout': ('unavailable', 503, 'after-delay'),
};

/// A BDP problem: an RFC 9457 Problem Details value with the BDP `code` and
/// `retry` members.
///
/// Thrown as a direct problem before admission; carried inside a `failed`
/// Mutation Receipt after it.
final class AuthorityProblem implements Exception {
  AuthorityProblem(
    this.code, {
    this.title,
    this.detail,
    this.pointer,
    this.instance,
    this.diagnostics,
    this.limit,
  }) : assert(_table.containsKey(code), 'unknown problem code $code');

  final String code;
  final String? title;
  final String? detail;
  final String? pointer;
  final String? instance;
  final List<JsonMap>? diagnostics;
  final String? limit;

  /// The code's fixed HTTP status.
  int get status => _table[code]!.$2;

  /// The code's fixed retry disposition.
  String get retry => _table[code]!.$3;

  /// The problem as JSON; [operationIndex] and [operationName] locate a
  /// receipt problem within its request.
  JsonMap toJson({int? operationIndex, String? operationName}) => {
    'type': '$problemTypePrefix${_table[code]!.$1}',
    'title': ?title,
    'status': status,
    'detail': ?detail,
    'instance': ?instance,
    'code': code,
    'retry': retry,
    'operationIndex': ?operationIndex,
    'operationName': ?operationName,
    'pointer': ?pointer,
    'limit': ?limit,
    'diagnostics': ?diagnostics,
  };

  @override
  String toString() =>
      'AuthorityProblem($code${detail == null ? '' : ': $detail'})';
}
