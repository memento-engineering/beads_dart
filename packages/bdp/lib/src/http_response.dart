import 'dart:convert';

import 'package:http/http.dart' as http;

import 'problem.dart';

const Set<int> _ok = {200};

/// Decodes a successful response, or throws the failure it carries.
T readResponse<T>(
  Uri uri,
  http.Response response,
  T Function(Object? json, String path) decode, {
  Set<int> ok = _ok,
}) {
  if (!ok.contains(response.statusCode)) {
    throw classifyFailure(
      uri,
      response.statusCode,
      response.headers,
      response.bodyBytes,
    );
  }
  final mediaType = mediaTypeOf(response.headers['content-type']);
  if (mediaType != 'application/json') {
    throw BdpProtocolException(
      uri: uri,
      message: 'expected application/json, got ${mediaType ?? 'no body type'}',
    );
  }
  return decodeBody(uri, response.bodyBytes, decode);
}

/// Decodes a JSON body, reporting a shape mismatch as a protocol failure.
T decodeBody<T>(
  Uri uri,
  List<int> body,
  T Function(Object? json, String path) decode,
) {
  try {
    return decode(jsonDecode(utf8.decode(body)), '');
  } on FormatException catch (error) {
    throw BdpProtocolException(uri: uri, message: error.message, cause: error);
  } on ArgumentError catch (error) {
    throw BdpProtocolException(
      uri: uri,
      message: '${error.message}',
      cause: error,
    );
  }
}

/// Classifies an unsuccessful response: a parseable Problem Details body is a
/// [BdpProblemException]; anything else is a [BdpHttpException].
BdpException classifyFailure(
  Uri uri,
  int status,
  Map<String, String> headers,
  List<int> body,
) {
  if (mediaTypeOf(headers['content-type']) == 'application/problem+json' &&
      body.isNotEmpty) {
    try {
      final problem = ProblemDetails.fromJson(jsonDecode(utf8.decode(body)));
      return BdpProblemException(
        uri: uri,
        status: status,
        problem: problem,
        retryAfter: _retryAfter(headers['retry-after']),
      );
    } on FormatException {
      // Not a BDP problem document; report the HTTP status alone.
    }
  }
  return BdpHttpException(
    uri: uri,
    status: status,
    reason: body.isEmpty ? null : 'non-problem body',
    retryAfter: _retryAfter(headers['retry-after']),
  );
}

/// The media type of a `content-type` field, without parameters.
String? mediaTypeOf(String? contentType) =>
    contentType?.split(';').first.trim().toLowerCase();

Duration? _retryAfter(String? value) => switch (int.tryParse(value ?? '')) {
  final seconds? when seconds >= 0 => Duration(seconds: seconds),
  _ => null,
};
