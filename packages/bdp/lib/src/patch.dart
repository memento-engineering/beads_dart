import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'json.dart';

final RegExp _jsonPointer = RegExp(r'^(/([^/~]|~[01])*)*$');

/// One RFC 6902 operation of a Property Change; BDP v0 admits `add`,
/// `replace` and `remove`.
@immutable
sealed class PatchOp {
  PatchOp._(this.path) {
    if (!_jsonPointer.hasMatch(path)) {
      throw ArgumentError.value(path, 'path', 'is not a JSON Pointer');
    }
  }

  /// Adds [value] at [path].
  factory PatchOp.add(String path, Object? value) = AddOp;

  /// Replaces the value at [path] with [value].
  factory PatchOp.replace(String path, Object? value) = ReplaceOp;

  /// Removes the value at [path].
  factory PatchOp.remove(String path) = RemoveOp;

  /// Decodes one patch operation.
  factory PatchOp.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    final op = r.string('op');
    final pointer = r.string('path');
    Object? value() {
      if (!r.has('value')) {
        throw FormatException('${r.at('value')}: required member is missing');
      }
      return freezeJson(r.raw('value'));
    }

    return switch (op) {
      'add' => AddOp(pointer, value()),
      'replace' => ReplaceOp(pointer, value()),
      'remove' => RemoveOp(pointer),
      _ => throw FormatException('${r.at('op')}: "$op" is not admitted'),
    };
  }

  /// The JSON Pointer, relative to `properties`.
  final String path;

  /// The wire form.
  JsonObject toJson();
}

/// An `add` operation.
final class AddOp extends PatchOp {
  /// Adds [value] at [path].
  AddOp(super.path, Object? value) : value = freezeJson(value), super._();

  /// The value added; may be JSON `null`.
  final Object? value;

  @override
  JsonObject toJson() => {'op': 'add', 'path': path, 'value': value};

  @override
  bool operator ==(Object other) =>
      other is AddOp &&
      other.path == path &&
      jsonEquality.equals(other.value, value);

  @override
  int get hashCode => Object.hash('add', path, jsonEquality.hash(value));
}

/// A `replace` operation.
final class ReplaceOp extends PatchOp {
  /// Replaces the value at [path] with [value].
  ReplaceOp(super.path, Object? value) : value = freezeJson(value), super._();

  /// The replacement value; may be JSON `null`.
  final Object? value;

  @override
  JsonObject toJson() => {'op': 'replace', 'path': path, 'value': value};

  @override
  bool operator ==(Object other) =>
      other is ReplaceOp &&
      other.path == path &&
      jsonEquality.equals(other.value, value);

  @override
  int get hashCode => Object.hash('replace', path, jsonEquality.hash(value));
}

/// A `remove` operation.
final class RemoveOp extends PatchOp {
  /// Removes the value at [path].
  RemoveOp(super.path) : super._();

  @override
  JsonObject toJson() => {'op': 'remove', 'path': path};

  @override
  bool operator ==(Object other) => other is RemoveOp && other.path == path;

  @override
  int get hashCode => Object.hash('remove', path);
}

/// An ordered, nonempty RFC 6902 patch applied to one `properties` object.
@immutable
final class PropertyChange {
  /// A change of [operations], which must be nonempty.
  PropertyChange(List<PatchOp> operations)
    : operations = List.unmodifiable(operations) {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', 'is empty');
    }
  }

  /// Decodes a Property Change array.
  factory PropertyChange.fromJson(Object? json, [String path = '']) {
    final operations = decodeList(json, path, PatchOp.fromJson);
    if (operations.isEmpty) {
      throw FormatException('$path: a Property Change is nonempty');
    }
    return PropertyChange(operations);
  }

  /// The operations, in application order.
  final List<PatchOp> operations;

  /// The wire form.
  List<JsonObject> toJson() => [for (final op in operations) op.toJson()];

  @override
  bool operator ==(Object other) =>
      other is PropertyChange &&
      const ListEquality<PatchOp>().equals(other.operations, operations);

  @override
  int get hashCode => const ListEquality<PatchOp>().hash(operations);
}
