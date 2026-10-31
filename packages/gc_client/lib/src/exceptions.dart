import 'model.dart';

/// A failed `GcClient` call: a [GcTransportException] or a [GcRefusal].
sealed class GcException implements Exception {
  const GcException(this.message, {this.exitCode, this.stderr = ''});

  /// What failed and why, fit for a log line or a failure reason.
  final String message;

  /// The exit status of the `gc` process, when one ran.
  final int? exitCode;

  /// What the `gc` process printed on stderr, unedited, gc's informational
  /// banners included; empty when none ran or it printed nothing.
  final String stderr;
}

/// The store could not be reached, or answered with something unreadable.
/// Transient: the same call may succeed later.
final class GcTransportException extends GcException {
  /// Creates the failure [message], with the [exitCode] and [stderr] of `gc`
  /// if it ran.
  const GcTransportException(super.message, {super.exitCode, super.stderr});

  @override
  String toString() => 'GcTransportException: $message';
}

/// The store answered and refused. Hard: the same call will be refused again.
final class GcRefusal extends GcException {
  /// Creates the refusal [message], with the [exitCode] and [stderr] of `gc`
  /// if it ran.
  const GcRefusal(super.message, {super.exitCode, super.stderr});

  @override
  String toString() => 'GcRefusal: $message';
}

/// The class of a seat's failure [error]: [FailureClass.transient] for a
/// [GcTransportException], since the same call may succeed later, and
/// [FailureClass.hard] for anything else, a [GcRefusal] included.
FailureClass failureClassOf(Object? error) =>
    error is GcTransportException ? FailureClass.transient : FailureClass.hard;
