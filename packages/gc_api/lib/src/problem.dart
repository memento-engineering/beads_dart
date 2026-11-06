import 'package:meta/meta.dart';

import 'json.dart';

/// An RFC 9457 Problem Details body as the Gas City API writes it
/// (`application/problem+json`, the `ErrorModel` schema).
///
/// Every member is optional: a refusal the API makes before routing, such as
/// a mutation without `X-GC-Request`, carries only `title`, `status` and
/// `detail`. bdp's `ProblemDetails` does not fit, since it requires BDP's
/// `code` and `retry`.
@immutable
final class GcProblem {
  const GcProblem({
    this.type,
    this.title,
    this.status,
    this.detail,
    this.instance,
    this.code,
    this.errors = const [],
  });

  factory GcProblem.fromJson(Object? json) {
    final r = JsonFields.of(json, 'problem');
    return GcProblem(
      type: r.optionalString('type'),
      title: r.optionalString('title'),
      status: r.optionalInteger('status'),
      detail: r.optionalString('detail'),
      instance: r.optionalString('instance'),
      code: r.optionalString('code'),
      errors: r.list('errors'),
    );
  }

  /// A URI naming the kind of problem, e.g. `urn:gascity:error:bead-not-found`.
  final String? type;

  final String? title;

  /// The HTTP status the server meant, which the response's status repeats.
  final int? status;

  final String? detail;

  final String? instance;

  /// The short name of the kind of problem, e.g. `bead-not-found`.
  final String? code;

  /// Per-field validation errors, as the server wrote them.
  final List<Object?> errors;

  /// Whether the server refused a mutation because it is read-only: bound to
  /// an address other than loopback without `allow_mutations`.
  bool get readOnly => detail?.startsWith('read_only') ?? false;

  @override
  String toString() =>
      'GcProblem(${code ?? type ?? title}, status: $status, detail: $detail)';
}

/// A request to the Gas City API that did not succeed.
sealed class GcApiException implements Exception {
  const GcApiException(this.uri);

  /// The request's target.
  final Uri uri;
}

/// The server refused the request with a Problem Details body.
final class GcProblemException extends GcApiException {
  const GcProblemException(
    super.uri, {
    required this.status,
    required this.problem,
  });

  final int status;

  final GcProblem problem;

  @override
  String toString() => 'GcProblemException($status $uri: $problem)';
}

/// The server answered with a failing status and no Problem Details body.
final class GcHttpException extends GcApiException {
  const GcHttpException(super.uri, {required this.status, this.body = ''});

  final int status;

  /// The response body, as text.
  final String body;

  /// Whether a retry may succeed: a timeout, a rate limit or a server error.
  bool get transient => const {408, 429, 500, 502, 503, 504}.contains(status);

  @override
  String toString() => 'GcHttpException($status $uri)';
}

/// The server's answer did not have the shape the API describes.
final class GcProtocolException extends GcApiException {
  const GcProtocolException(super.uri, this.message);

  final String message;

  @override
  String toString() => 'GcProtocolException($uri: $message)';
}
