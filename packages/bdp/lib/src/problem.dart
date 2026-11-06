import 'package:meta/meta.dart';

import 'json.dart';

/// The BDP v0 problem-family prefix.
const String problemTypePrefix = 'https://github.com/gastownhall/bdp/problems/';

/// What a caller may do after a problem.
enum RetryDisposition {
  /// The request as written can never succeed.
  never('never'),

  /// Refresh state or construct a new request first.
  afterStateChange('after-state-change'),

  /// The same request may succeed later.
  afterDelay('after-delay');

  const RetryDisposition(this.wire);

  /// The wire token.
  final String wire;

  /// Decodes a disposition from its wire token.
  static RetryDisposition fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (retry) => retry.wire);

  /// The wire token.
  String toJson() => wire;
}

/// The BDP v0 problem codes, by profile context, as the schema bundle closes
/// them.
abstract final class ProblemCodes {
  /// `malformed-request`.
  static const malformedRequest = 'malformed-request';

  /// `invalid-parameter`.
  static const invalidParameter = 'invalid-parameter';

  /// `unauthenticated`.
  static const unauthenticated = 'unauthenticated';

  /// `forbidden`.
  static const forbidden = 'forbidden';

  /// `resource-not-found`.
  static const resourceNotFound = 'resource-not-found';

  /// `resource-pruned`.
  static const resourcePruned = 'resource-pruned';

  /// `resource-erased`.
  static const resourceErased = 'resource-erased';

  /// `foreign-view`.
  static const foreignView = 'foreign-view';

  /// `cursor-expired`.
  static const cursorExpired = 'cursor-expired';

  /// `request-too-large`.
  static const requestTooLarge = 'request-too-large';

  /// `limit-exceeded`.
  static const limitExceeded = 'limit-exceeded';

  /// `rate-limited`.
  static const rateLimited = 'rate-limited';

  /// `temporarily-unavailable`.
  static const temporarilyUnavailable = 'temporarily-unavailable';

  /// `revision-unknown`.
  static const revisionUnknown = 'revision-unknown';

  /// `revision-unretained`.
  static const revisionUnretained = 'revision-unretained';

  /// `revision-reorganized`.
  static const revisionReorganized = 'revision-reorganized';

  /// `revision-not-tracked`.
  static const revisionNotTracked = 'revision-not-tracked';

  /// `revision-unrepresentable`.
  static const revisionUnrepresentable = 'revision-unrepresentable';

  /// `unsupported-media-type`.
  static const unsupportedMediaType = 'unsupported-media-type';

  /// `binding-unavailable`.
  static const bindingUnavailable = 'binding-unavailable';

  /// `validation-failed`.
  static const validationFailed = 'validation-failed';

  /// `type-not-installed`.
  static const typeNotInstalled = 'type-not-installed';

  /// `identity-taken`.
  static const identityTaken = 'identity-taken';

  /// `alias-path-taken`.
  static const aliasPathTaken = 'alias-path-taken';

  /// `revision-mismatch`.
  static const revisionMismatch = 'revision-mismatch';

  /// `incident-links-exist`.
  static const incidentLinksExist = 'incident-links-exist';

  /// `aggregate-constraint-violation`.
  static const aggregateConstraintViolation = 'aggregate-constraint-violation';

  /// `idempotency-conflict`.
  static const idempotencyConflict = 'idempotency-conflict';

  /// `idempotency-in-progress`.
  static const idempotencyInProgress = 'idempotency-in-progress';

  /// `idempotency-expired`.
  static const idempotencyExpired = 'idempotency-expired';

  /// `revision-allocation-unsafe`.
  static const revisionAllocationUnsafe = 'revision-allocation-unsafe';

  /// `cardinality-violated`.
  static const cardinalityViolated = 'cardinality-violated';

  /// `event-history-expired`.
  static const eventHistoryExpired = 'event-history-expired';

  /// `catch-up-timeout`.
  static const catchUpTimeout = 'catch-up-timeout';

  /// The Read profile's closed table.
  static const Set<String> read = {
    malformedRequest,
    invalidParameter,
    unauthenticated,
    forbidden,
    resourceNotFound,
    resourcePruned,
    resourceErased,
    foreignView,
    cursorExpired,
    requestTooLarge,
    limitExceeded,
    rateLimited,
    temporarilyUnavailable,
    revisionUnknown,
    revisionUnretained,
    revisionReorganized,
    revisionNotTracked,
    revisionUnrepresentable,
  };

  /// The Read+Update union: the Read table plus its mutation rows.
  static const Set<String> readUpdate = {
    ...read,
    unsupportedMediaType,
    bindingUnavailable,
    validationFailed,
    typeNotInstalled,
    identityTaken,
    aliasPathTaken,
    revisionMismatch,
    incidentLinksExist,
    aggregateConstraintViolation,
    idempotencyConflict,
    idempotencyInProgress,
    idempotencyExpired,
    revisionAllocationUnsafe,
  };

  /// The Transactional-only rows.
  static const Set<String> transactionalOnly = {
    cardinalityViolated,
    eventHistoryExpired,
    catchUpTimeout,
  };

  /// Codes served as direct problem responses on a Transactional Scope.
  static const Set<String> direct = {
    ...read,
    unsupportedMediaType,
    idempotencyConflict,
    eventHistoryExpired,
    catchUpTimeout,
    revisionAllocationUnsafe,
  };

  /// Codes carried inside a `failed` Mutation Receipt.
  static const Set<String> receipt = {
    forbidden,
    resourceNotFound,
    limitExceeded,
    bindingUnavailable,
    validationFailed,
    typeNotInstalled,
    identityTaken,
    aliasPathTaken,
    revisionMismatch,
    incidentLinksExist,
    aggregateConstraintViolation,
    cardinalityViolated,
    revisionAllocationUnsafe,
  };
}

/// One entry of a `validation-failed` problem's diagnostics.
@immutable
final class ValidationDiagnostic {
  /// A diagnostic.
  const ValidationDiagnostic({
    required this.message,
    this.type,
    this.schemaLocation,
    this.instanceLocation,
  });

  /// Decodes a diagnostic.
  factory ValidationDiagnostic.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return ValidationDiagnostic(
      type: r.optionalString('type'),
      schemaLocation: r.optionalString('schemaLocation'),
      instanceLocation: r.optionalString('instanceLocation'),
      message: r.string('message'),
    );
  }

  /// The failing effective Type, for a Type-contract failure.
  final String? type;

  /// The absolute keyword location of the failed schema keyword.
  final String? schemaLocation;

  /// A JSON Pointer within `properties`.
  final String? instanceLocation;

  /// What failed.
  final String message;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{};
    putIfPresent(json, 'type', type);
    putIfPresent(json, 'schemaLocation', schemaLocation);
    putIfPresent(json, 'instanceLocation', instanceLocation);
    json['message'] = message;
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is ValidationDiagnostic &&
      other.type == type &&
      other.schemaLocation == schemaLocation &&
      other.instanceLocation == instanceLocation &&
      other.message == message;

  @override
  int get hashCode =>
      Object.hash(type, schemaLocation, instanceLocation, message);
}

/// RFC 9457 Problem Details with BDP's required `code` and `retry`.
///
/// Members the protocol names are typed; every other member is an RFC 9457
/// extension carried verbatim in [extensions].
@immutable
final class ProblemDetails {
  /// A problem.
  ProblemDetails({
    required this.type,
    required this.code,
    required this.retry,
    this.title,
    this.status,
    this.detail,
    this.instance,
    this.retryAfter,
    this.pointer,
    this.limit,
    this.operationIndex,
    this.operationName,
    List<ValidationDiagnostic>? diagnostics,
    this.diagnosticsTruncated,
    JsonObject extensions = const {},
  }) : diagnostics = diagnostics == null
           ? null
           : List.unmodifiable(diagnostics),
       extensions = freezeObject(extensions);

  /// Decodes a problem document.
  factory ProblemDetails.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return ProblemDetails(
      type: r.string('type'),
      title: r.optionalString('title'),
      status: r.optionalInteger('status'),
      detail: r.optionalString('detail'),
      instance: r.optionalString('instance'),
      code: r.string('code'),
      retry: r.decode('retry', RetryDisposition.fromJson),
      retryAfter: r.optionalInteger('retryAfter'),
      pointer: r.optionalString('pointer'),
      limit: r.optionalString('limit'),
      operationIndex: r.optionalInteger('operationIndex'),
      operationName: r.optionalString('operationName'),
      diagnostics: r.optionalList('diagnostics', ValidationDiagnostic.fromJson),
      diagnosticsTruncated: r.optionalBoolean('diagnosticsTruncated'),
      extensions: r.unknownMembers(_typedMembers),
    );
  }

  static const Set<String> _typedMembers = {
    'type',
    'title',
    'status',
    'detail',
    'instance',
    'code',
    'retry',
    'retryAfter',
    'pointer',
    'limit',
    'operationIndex',
    'operationName',
    'diagnostics',
    'diagnosticsTruncated',
  };

  /// The problem-family type URL.
  final String type;

  /// A short human summary.
  final String? title;

  /// The HTTP status the problem carries; for a receipt or sequence-member
  /// problem, the would-be direct status.
  final int? status;

  /// A human explanation of this occurrence.
  final String? detail;

  /// A URI identifying this occurrence.
  final String? instance;

  /// The exact normative condition.
  final String code;

  /// What the caller may do next.
  final RetryDisposition retry;

  /// Suggested delay in seconds for an `after-delay` problem.
  final int? retryAfter;

  /// A JSON Pointer into the request body naming the offending member.
  final String? pointer;

  /// The limit crossed, for `limit-exceeded`.
  final String? limit;

  /// The failing operation's index, inside a receipt or sequence.
  final int? operationIndex;

  /// The failing operation's label, when it declared one.
  final String? operationName;

  /// The diagnostics of a `validation-failed` problem.
  final List<ValidationDiagnostic>? diagnostics;

  /// Whether diagnostics beyond an advertised bound were omitted.
  final bool? diagnosticsTruncated;

  /// Every other member, verbatim.
  final JsonObject extensions;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{'type': type};
    putIfPresent(json, 'title', title);
    putIfPresent(json, 'status', status);
    putIfPresent(json, 'detail', detail);
    putIfPresent(json, 'instance', instance);
    json['code'] = code;
    json['retry'] = retry.toJson();
    putIfPresent(json, 'retryAfter', retryAfter);
    putIfPresent(json, 'pointer', pointer);
    putIfPresent(json, 'limit', limit);
    putIfPresent(json, 'operationIndex', operationIndex);
    putIfPresent(json, 'operationName', operationName);
    putIfPresent(json, 'diagnostics', switch (diagnostics) {
      null => null,
      final entries => [for (final entry in entries) entry.toJson()],
    });
    putIfPresent(json, 'diagnosticsTruncated', diagnosticsTruncated);
    json.addAll(extensions);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is ProblemDetails && jsonEquality.equals(other.toJson(), toJson());

  @override
  int get hashCode => jsonEquality.hash(toJson());

  @override
  String toString() => 'ProblemDetails($code, ${retry.wire})';
}

/// A failure observed while talking to a BDP Scope.
sealed class BdpException implements Exception {
  const BdpException(this.uri);

  /// The request URL.
  final Uri uri;
}

/// The Scope answered with a BDP Problem Details document.
final class BdpProblemException extends BdpException {
  /// A problem response with HTTP [status].
  const BdpProblemException({
    required Uri uri,
    required this.status,
    required this.problem,
    this.retryAfter,
  }) : super(uri);

  /// The HTTP status of the response.
  final int status;

  /// The problem document.
  final ProblemDetails problem;

  /// The `Retry-After` delay the response carried, if any.
  final Duration? retryAfter;

  /// The problem code.
  String get code => problem.code;

  /// The problem-family type URL.
  String get type => problem.type;

  @override
  String toString() =>
      'BdpProblemException($status ${problem.code}, ${problem.retry.wire}) '
      'for $uri';
}

/// The Scope answered with an HTTP status that carries no BDP problem: a
/// bodyless `304`, `405`, `406`, `412` or `500`, or a body that is not
/// Problem Details.
final class BdpHttpException extends BdpException {
  /// An HTTP-native failure with [status].
  const BdpHttpException({
    required Uri uri,
    required this.status,
    this.reason,
    this.retryAfter,
  }) : super(uri);

  /// The HTTP status.
  final int status;

  /// The reason phrase or a short description.
  final String? reason;

  /// The `Retry-After` delay the response carried, if any.
  final Duration? retryAfter;

  /// Whether the status names a condition that may clear on its own: a
  /// request timeout, rate limiting, or a server or gateway failure such as
  /// an intermediary's bodyless `502` or `503`.
  bool get transient => const {408, 429, 500, 502, 503, 504}.contains(status);

  @override
  String toString() =>
      'BdpHttpException($status${switch (reason) {
        null => '',
        final reason => ' $reason',
      }}) for $uri';
}

/// A successful response did not match the BDP wire shape the client
/// expected.
final class BdpProtocolException extends BdpException {
  /// A protocol violation described by [message].
  const BdpProtocolException({
    required Uri uri,
    required this.message,
    this.cause,
  }) : super(uri);

  /// What was wrong.
  final String message;

  /// The underlying decode failure, if any.
  final Object? cause;

  @override
  String toString() => 'BdpProtocolException($message) for $uri';
}
