import 'dart:math';

import 'package:meta/meta.dart';

import 'json.dart';

final RegExp _wireToken = RegExp(r'^[A-Za-z0-9_-]{1,256}$');

/// An opaque protocol token: compared for equality and echoed byte for byte,
/// never parsed, ordered or reinterpreted.
///
/// Two tokens are equal only when they are the same kind of token with the
/// same spelling, so a [Revision] never equals a [Checkpoint].
@immutable
sealed class OpaqueToken {
  const OpaqueToken._(this.value);

  /// The token exactly as it appeared on the wire.
  final String value;

  /// The token's JSON form: its spelling, unchanged.
  String toJson() => value;

  @override
  bool operator ==(Object other) =>
      other is OpaqueToken &&
      other.runtimeType == runtimeType &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => value;
}

/// An opaque Resource revision: any nonempty string, compared only for
/// equality.
final class Revision extends OpaqueToken {
  /// Wraps a revision spelling, which must be nonempty.
  Revision(String value) : super._(_nonempty(value, 'Revision'));

  /// Decodes a revision; a non-string value is a [FormatException].
  factory Revision.fromJson(Object? json, [String path = '']) =>
      Revision(_decodeNonempty(json, path));
}

/// A Scope changefeed checkpoint: the exclusive cursor a replica resumes
/// after.
final class Checkpoint extends OpaqueToken {
  /// Wraps a checkpoint spelling under the wire-token grammar.
  Checkpoint(String value) : super._(_token(value, 'Checkpoint'));

  /// Decodes a checkpoint.
  factory Checkpoint.fromJson(Object? json, [String path = '']) =>
      Checkpoint(_decodeToken(json, path));

  /// The reserved initial checkpoint, from which complete retained history
  /// replays.
  static final Checkpoint genesis = Checkpoint('genesis');
}

/// A Scope position: one committed transaction in the Scope order, compared
/// only for equality.
final class ScopePosition extends OpaqueToken {
  /// Wraps a position spelling under the wire-token grammar.
  ScopePosition(String value) : super._(_token(value, 'ScopePosition'));

  /// Decodes a Scope position.
  factory ScopePosition.fromJson(Object? json, [String path = '']) =>
      ScopePosition(_decodeToken(json, path));
}

/// A Scope epoch: the incarnation of an authority history that fences every
/// other history token.
final class ScopeEpoch extends OpaqueToken {
  /// Wraps an epoch spelling under the wire-token grammar.
  ScopeEpoch(String value) : super._(_token(value, 'ScopeEpoch'));

  /// Decodes a Scope epoch.
  factory ScopeEpoch.fromJson(Object? json, [String path = '']) =>
      ScopeEpoch(_decodeToken(json, path));
}

/// An Authorization View token: the read projection the authority bound the
/// request to. It is not a credential.
final class AuthorizationView extends OpaqueToken {
  /// Wraps a view token spelling under the wire-token grammar.
  AuthorizationView(String value) : super._(_token(value, 'AuthorizationView'));

  /// Decodes an Authorization View token.
  factory AuthorizationView.fromJson(Object? json, [String path = '']) =>
      AuthorizationView(_decodeToken(json, path));
}

/// A Mutation Transaction identifier.
final class TransactionId extends OpaqueToken {
  /// Wraps a transaction identifier under the wire-token grammar.
  TransactionId(String value) : super._(_token(value, 'TransactionId'));

  /// Decodes a transaction identifier.
  factory TransactionId.fromJson(Object? json, [String path = '']) =>
      TransactionId(_decodeToken(json, path));
}

/// An Event identifier, unique within its Event Source.
final class EventId extends OpaqueToken {
  /// Wraps an Event identifier under the wire-token grammar.
  EventId(String value) : super._(_token(value, 'EventId'));

  /// Decodes an Event identifier.
  factory EventId.fromJson(Object? json, [String path = '']) =>
      EventId(_decodeToken(json, path));
}

/// A client-minted idempotency key: one semantic mutation within the
/// Scope's idempotency namespace.
final class IdempotencyKey extends OpaqueToken {
  /// Wraps a key spelling under the wire-token grammar.
  IdempotencyKey(String value) : super._(_token(value, 'IdempotencyKey'));

  /// Decodes an idempotency key.
  factory IdempotencyKey.fromJson(Object? json, [String path = '']) =>
      IdempotencyKey(_decodeToken(json, path));

  /// Mints an unguessable 22-character key from a secure random source.
  factory IdempotencyKey.generate([Random? random]) {
    final source = random ?? Random.secure();
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final buffer = StringBuffer();
    for (var i = 0; i < 22; i++) {
      buffer.write(alphabet[source.nextInt(alphabet.length)]);
    }
    return IdempotencyKey(buffer.toString());
  }
}

String _nonempty(String value, String kind) {
  if (value.isEmpty) throw ArgumentError.value(value, kind, 'is empty');
  return value;
}

String _token(String value, String kind) {
  if (!_wireToken.hasMatch(value)) {
    throw ArgumentError.value(
      value,
      kind,
      'does not match the wire-token grammar [A-Za-z0-9_-]{1,256}',
    );
  }
  return value;
}

String _decodeNonempty(Object? json, String path) {
  final value = decodeString(json, path);
  if (value.isEmpty) throw FormatException('$path: expected a nonempty string');
  return value;
}

String _decodeToken(Object? json, String path) {
  final value = decodeString(json, path);
  if (!_wireToken.hasMatch(value)) {
    throw FormatException('$path: "$value" is not a wire token');
  }
  return value;
}
