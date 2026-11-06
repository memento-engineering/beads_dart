import 'json_text.dart';

/// Whether [path] is an RFC 6901 JSON Pointer.
bool isJsonPointer(String path) =>
    path.isEmpty ||
    (path.startsWith('/') && !RegExp('~[^01]|~\$').hasMatch(path));

/// A Property Change that cannot apply: a missing `replace`/`remove` target,
/// an unreachable parent, or a non-object result.
final class PatchFailure implements Exception {
  const PatchFailure(this.message, this.instanceLocation);

  final String message;
  final String instanceLocation;
}

/// Applies an RFC 6902 patch restricted to `add`, `replace` and `remove` to a
/// copy of [properties] and returns the result.
JsonMap applyPatch(JsonMap properties, List<JsonMap> change) {
  Object? document = jsonCopy(properties);
  for (final op in change) {
    final path = op['path']! as String;
    final tokens = path.isEmpty
        ? const <String>[]
        : path
              .substring(1)
              .split('/')
              .map((t) => t.replaceAll('~1', '/').replaceAll('~0', '~'))
              .toList();
    final kind = op['op']! as String;
    if (tokens.isEmpty) {
      if (kind == 'remove') throw PatchFailure('cannot remove the root', path);
      document = jsonCopy(op['value']);
      continue;
    }
    Object? parent = document;
    for (final token in tokens.take(tokens.length - 1)) {
      parent = switch (parent) {
        final Map<String, Object?> map when map.containsKey(token) =>
          map[token],
        final List<Object?> list when _index(token, list.length) != null =>
          list[_index(token, list.length)!],
        _ => throw PatchFailure('path does not exist', path),
      };
    }
    final last = tokens.last;
    switch (parent) {
      case final Map<String, Object?> map:
        if (kind != 'add' && !map.containsKey(last)) {
          throw PatchFailure('$kind target does not exist', path);
        }
        if (kind == 'remove') {
          map.remove(last);
        } else {
          map[last] = jsonCopy(op['value']);
        }
      case final List<Object?> list:
        final append = kind == 'add' && last == '-';
        final index = append
            ? list.length
            : _index(last, kind == 'add' ? list.length + 1 : list.length);
        if (index == null) throw PatchFailure('array index is invalid', path);
        switch (kind) {
          case 'add':
            list.insert(index, jsonCopy(op['value']));
          case 'replace':
            list[index] = jsonCopy(op['value']);
          default:
            list.removeAt(index);
        }
      default:
        throw PatchFailure('parent is not a container', path);
    }
  }
  if (document is! Map<String, Object?>) {
    throw const PatchFailure('properties must remain a JSON object', '');
  }
  return document;
}

int? _index(String token, int bound) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(token)) return null;
  final value = int.parse(token);
  return value < bound ? value : null;
}
