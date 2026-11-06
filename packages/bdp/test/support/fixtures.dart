import 'dart:convert';
import 'dart:io';

/// Reads a copied BDP fixture by its path beneath `test/fixtures/bdp/`.
Map<String, Object?> fixture(String path) =>
    jsonDecode(File('test/fixtures/bdp/$path').readAsStringSync())
        as Map<String, Object?>;

/// The exchanges (or cases) of a transactional or read-update fixture file.
List<Map<String, Object?>> exchangesOf(Map<String, Object?> file) => [
  for (final entry
      in (file['exchanges'] ?? file['cases'] ?? const <Object?>[])
          as List<Object?>)
    entry! as Map<String, Object?>,
];

/// The exchange named [id] in [file].
Map<String, Object?> exchange(Map<String, Object?> file, String id) =>
    exchangesOf(file).singleWhere((entry) => entry['id'] == id);

/// The response member of an exchange.
Map<String, Object?> responseOf(Map<String, Object?> exchange) =>
    exchange['response']! as Map<String, Object?>;

/// The request member of an exchange.
Map<String, Object?> requestOf(Map<String, Object?> exchange) =>
    exchange['request']! as Map<String, Object?>;

/// The JSON body of a request or response, when the fixture records one.
Object? bodyOf(Map<String, Object?> message) => message['body'];

/// Lower-cased header map of a request or response.
Map<String, String> headersOf(Map<String, Object?> message) => {
  for (final MapEntry(:key, :value)
      in ((message['headers'] ?? const <String, Object?>{})
              as Map<String, Object?>)
          .entries)
    key.toLowerCase(): value! as String,
};
