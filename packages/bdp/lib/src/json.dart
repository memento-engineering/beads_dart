import 'package:collection/collection.dart';

/// A decoded JSON object.
typedef JsonObject = Map<String, Object?>;

/// Deep JSON value equality: maps by key, lists by position, numbers by value.
const DeepCollectionEquality jsonEquality = DeepCollectionEquality();

/// Returns an unmodifiable deep copy of a decoded JSON value, preserving
/// member order.
Object? freezeJson(Object? value) => switch (value) {
  final Map<String, Object?> map => Map<String, Object?>.unmodifiable({
    for (final entry in map.entries) entry.key: freezeJson(entry.value),
  }),
  final List<Object?> list => List<Object?>.unmodifiable(list.map(freezeJson)),
  _ => value,
};

/// Returns an unmodifiable deep copy of a JSON object.
JsonObject freezeObject(JsonObject value) => freezeJson(value)! as JsonObject;

/// Reads one JSON object, naming the offending member by JSON Pointer when a
/// member is missing or has the wrong shape.
///
/// Tokens are read as strings and only as strings: a number where a token
/// belongs is a [FormatException], never a reinterpretation.
final class JsonReader {
  JsonReader._(this._map, this.path);

  /// Wraps [value], which must be a JSON object.
  factory JsonReader.of(Object? value, String path) {
    if (value is! Map<String, Object?>) {
      throw FormatException('${_where(path)}: expected a JSON object');
    }
    return JsonReader._(value, path);
  }

  final JsonObject _map;

  /// The JSON Pointer of this object within the decoded document.
  final String path;

  /// The pointer of [key] beneath this object.
  String at(String key) => '$path/$key';

  /// Whether [key] is present, even with a `null` value.
  bool has(String key) => _map.containsKey(key);

  /// The member names of this object.
  Iterable<String> get keys => _map.keys;

  /// The raw value of [key].
  Object? raw(String key) => _map[key];

  /// A required string member.
  String string(String key) => _string(_require(key), at(key));

  /// An optional string member; absent and `null` both read as `null`.
  String? optionalString(String key) {
    final value = _map[key];
    return value == null ? null : _string(value, at(key));
  }

  /// A required integer member.
  int integer(String key) => _integer(_require(key), at(key));

  /// An optional integer member.
  int? optionalInteger(String key) {
    final value = _map[key];
    return value == null ? null : _integer(value, at(key));
  }

  /// A required boolean member.
  bool boolean(String key) {
    final value = _require(key);
    if (value is! bool) throw _wrong(at(key), 'a boolean');
    return value;
  }

  /// An optional boolean member.
  bool? optionalBoolean(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is! bool) throw _wrong(at(key), 'a boolean');
    return value;
  }

  /// A required JSON object member, frozen.
  JsonObject object(String key) {
    final value = _require(key);
    if (value is! Map<String, Object?>) throw _wrong(at(key), 'an object');
    return freezeObject(value);
  }

  /// An optional JSON object member, frozen.
  JsonObject? optionalObject(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is! Map<String, Object?>) throw _wrong(at(key), 'an object');
    return freezeObject(value);
  }

  /// A required member decoded by [decode].
  T decode<T>(String key, T Function(Object? value, String path) decode) =>
      decode(_require(key), at(key));

  /// An optional member decoded by [decode]; absent and `null` read as `null`.
  T? optionalDecode<T>(
    String key,
    T Function(Object? value, String path) decode,
  ) {
    final value = _map[key];
    return value == null ? null : decode(value, at(key));
  }

  /// A required array member whose items are decoded by [decode].
  List<T> list<T>(String key, T Function(Object? value, String path) decode) =>
      decodeList(_require(key), at(key), decode);

  /// An optional array member whose items are decoded by [decode].
  List<T>? optionalList<T>(
    String key,
    T Function(Object? value, String path) decode,
  ) {
    final value = _map[key];
    return value == null ? null : decodeList(value, at(key), decode);
  }

  /// The members of this object not named in [known], frozen, in order.
  JsonObject unknownMembers(Set<String> known) => Map.unmodifiable({
    for (final entry in _map.entries)
      if (!known.contains(entry.key)) entry.key: freezeJson(entry.value),
  });

  Object? _require(String key) {
    if (!_map.containsKey(key)) {
      throw FormatException('${_where(at(key))}: required member is missing');
    }
    final value = _map[key];
    if (value == null) throw _wrong(at(key), 'a value, not null');
    return value;
  }
}

/// Decodes a JSON array whose items are decoded by [decode].
List<T> decodeList<T>(
  Object? value,
  String path,
  T Function(Object? value, String path) decode,
) {
  if (value is! List<Object?>) throw _wrong(path, 'an array');
  return List<T>.unmodifiable([
    for (var i = 0; i < value.length; i++) decode(value[i], '$path/$i'),
  ]);
}

/// Decodes a JSON string.
String decodeString(Object? value, String path) => _string(value, path);

/// Decodes a member value by name against an enum's wire spellings.
T decodeEnum<T extends Enum>(
  Object? value,
  String path,
  List<T> values,
  String Function(T value) wire,
) {
  final text = _string(value, path);
  for (final candidate in values) {
    if (wire(candidate) == text) return candidate;
  }
  throw FormatException(
    '${_where(path)}: "$text" is not one of '
    '${values.map(wire).join(', ')}',
  );
}

/// Writes [value] under [key] only when it is non-null.
void putIfPresent(JsonObject json, String key, Object? value) {
  if (value != null) json[key] = value;
}

String _string(Object? value, String path) {
  if (value is! String) throw _wrong(path, 'a string');
  return value;
}

int _integer(Object? value, String path) {
  if (value is! int) throw _wrong(path, 'an integer');
  return value;
}

FormatException _wrong(String path, String expected) =>
    FormatException('${_where(path)}: expected $expected');

String _where(String path) => path.isEmpty ? '(document)' : path;
