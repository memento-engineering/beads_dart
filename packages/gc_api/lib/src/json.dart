/// A JSON object read field by field: a missing required field or a field of
/// the wrong type is a [FormatException] naming its path.
extension type const JsonFields(Map<String, Object?> _json) {
  /// [value] as an object, or a [FormatException] naming [path].
  static JsonFields of(Object? value, String path) => switch (value) {
    final Map<String, Object?> json => JsonFields(json),
    _ => throw FormatException('$path is not an object'),
  };

  /// The object itself.
  Map<String, Object?> get json => _json;

  String string(String key) => _required(key, _string(key));

  String? optionalString(String key) => _string(key);

  int integer(String key) => _required(key, _integer(key));

  int? optionalInteger(String key) => _integer(key);

  bool boolean(String key) => _required(key, _boolean(key));

  bool? optionalBoolean(String key) => _boolean(key);

  /// The object at [key], read as one.
  JsonFields object(String key) =>
      JsonFields.of(_required(key, _json[key]), key);

  /// The object at [key], or null when it is absent or null.
  JsonFields? optionalObject(String key) => switch (_json[key]) {
    null => null,
    final value => JsonFields.of(value, key),
  };

  /// The strings at [key]; empty when it is absent or null.
  List<String> strings(String key) => [
    for (final (i, item) in list(key).indexed)
      if (item is String)
        item
      else
        throw FormatException('$key[$i] is not a string'),
  ];

  /// The array at [key]; empty when it is absent or null, which the API
  /// writes for an empty list.
  List<Object?> list(String key) => switch (_json[key]) {
    null => const [],
    final List<Object?> items => items,
    _ => throw FormatException('$key is not an array'),
  };

  /// [key] as an RFC 3339 instant.
  DateTime instant(String key) {
    final text = string(key);
    return DateTime.tryParse(text) ??
        (throw FormatException('$key is not an RFC 3339 instant: $text'));
  }

  T _required<T>(String key, T? value) =>
      value ?? (throw FormatException('$key is missing'));

  String? _string(String key) => switch (_json[key]) {
    null => null,
    final String value => value,
    _ => throw FormatException('$key is not a string'),
  };

  int? _integer(String key) => switch (_json[key]) {
    null => null,
    final int value => value,
    _ => throw FormatException('$key is not an integer'),
  };

  bool? _boolean(String key) => switch (_json[key]) {
    null => null,
    final bool value => value,
    _ => throw FormatException('$key is not a boolean'),
  };
}
