import 'dart:convert';

/// Bead or Link.
enum AuthorityResourceKind {
  bead('beads/'),
  link('links/');

  const AuthorityResourceKind(this.root);

  /// The fixed local-ID root for this kind.
  final String root;
}

/// What a reference spelling denotes, decided from the spelling alone.
sealed class Spelling {
  const Spelling();
}

/// An in-Scope spelling whose path is canonical under the local-ID grammar.
///
/// [kind] is null when the path lies under neither fixed root.
final class InScopeSpelling extends Spelling {
  const InScopeSpelling(this.url, this.kind);

  final String url;
  final AuthorityResourceKind? kind;
}

/// An absolute URI outside the Scope: an opaque external reference.
final class ExternalSpelling extends Spelling {
  const ExternalSpelling(this.uri);

  final String uri;
}

/// A spelling that is neither a canonical local ID, an absolute canonical
/// URL, nor an absolute URI: carrier syntax.
final class InvalidSpelling extends Spelling {
  const InvalidSpelling(this.reason);

  final String reason;
}

/// The canonical Scope URL and the addresses derived from it.
final class ScopeAddress {
  ScopeAddress(this.scope) {
    final uri = Uri.parse(scope);
    if (!(uri.isScheme('http') || uri.isScheme('https')) ||
        !scope.endsWith('/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(scope, 'scope', 'not a canonical Scope URL');
    }
  }

  /// The canonical Scope URL, ending in `/`.
  final String scope;

  String get discovery => '${scope}bdp.json';
  String get beads => '${scope}beads/';
  String get links => '${scope}links/';
  String get types => '${scope}types/';
  String get operations => '${scope}operations/';
  String get aliases => '${scope}alias/';
  String get receipts => '${scope}receipts/';
  String get snapshot => '${scope}snapshot';
  String get changes => '${scope}changes/';
  String get events => '${scope}events/';

  static final _absolute = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');

  /// Classifies a reference spelling: a local ID (`beads/x`), an absolute
  /// canonical URL, or an absolute external URI.
  Spelling classify(String spelling) {
    String path;
    if (spelling.startsWith(scope)) {
      path = spelling.substring(scope.length);
    } else if (_absolute.hasMatch(spelling)) {
      return ExternalSpelling(spelling);
    } else {
      path = spelling;
    }
    final kind = AuthorityResourceKind.values
        .where((k) => path.startsWith(k.root))
        .firstOrNull;
    final idPath = kind == null ? path : path.substring(kind.root.length);
    final problem = idPathProblem(idPath);
    if (problem != null) return InvalidSpelling(problem);
    return InScopeSpelling('$scope$path', kind);
  }

  /// The local ID (`beads/...`) of an in-Scope canonical URL.
  String localId(String url) => url.substring(scope.length);

  static const _literal =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
      "-._~!\$&'()*+,;=:@";
  static const _unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  /// Why [idPath] is not a canonical `{id-path}`, or null when it is: one or
  /// more nonempty segments of literal path characters and uppercase percent
  /// escapes that do not encode an unreserved character or a separator.
  static String? idPathProblem(String idPath) {
    if (idPath.isEmpty) return 'empty identity path';
    for (final segment in idPath.split('/')) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        return 'empty or dot segment';
      }
      final bytes = <int>[];
      for (var i = 0; i < segment.length; i++) {
        final c = segment[i];
        if (c == '%') {
          if (i + 2 >= segment.length) return 'truncated percent escape';
          final hex = segment.substring(i + 1, i + 3);
          if (hex != hex.toUpperCase()) return 'lowercase percent escape';
          final byte = int.tryParse(hex, radix: 16);
          if (byte == null) return 'invalid percent escape';
          final char = String.fromCharCode(byte);
          if (byte < 0x80 && _unreserved.contains(char)) {
            return 'percent-encoded unreserved character';
          }
          if (byte == 0x2F || byte == 0x5C || byte < 0x20 || byte == 0x7F) {
            return 'encoded separator or control';
          }
          bytes.add(byte);
          i += 2;
        } else if (_literal.contains(c)) {
          bytes.add(c.codeUnitAt(0));
        } else {
          return 'character not allowed literally';
        }
      }
      try {
        utf8.decode(bytes);
      } on FormatException {
        return 'invalid UTF-8';
      }
    }
    return null;
  }
}
