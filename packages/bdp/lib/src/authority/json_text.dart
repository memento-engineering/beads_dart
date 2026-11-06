import 'dart:convert';

/// A decoded JSON object.
typedef JsonMap = Map<String, Object?>;

/// A request body that breaks the carrier's JSON contract.
///
/// [pointer] is an RFC 6901 pointer to the offending member, or empty when
/// the text is not JSON at all.
final class JsonTextException implements Exception {
  const JsonTextException(this.message, this.pointer);

  final String message;
  final String pointer;

  @override
  String toString() => 'JsonTextException($message at "$pointer")';
}

/// The result of [parseStrictJson]: the value plus every number literal
/// that is not admissible under the binary64 round-trip rule.
final class StrictJson {
  const StrictJson(this.value, this.inadmissibleNumbers);

  final Object? value;

  /// The pointer of each inadmissible literal, mapped to the exact decimal
  /// value the literal denotes in its one normalized spelling. The parsed
  /// [value] holds the nearest number Dart can represent instead, so these
  /// spellings are what keeps two such requests distinct.
  final Map<String, String> inadmissibleNumbers;
}

/// Parses [text] under the I-JSON rules BDP admits: no duplicate member
/// names after escape decoding and no unpaired surrogates.
///
/// Inadmissible number literals do not fail the parse; they are reported in
/// [StrictJson.inadmissibleNumbers] because they fail the operation that
/// carries them, not the carrier.
StrictJson parseStrictJson(String text) {
  final parser = _Parser(text);
  final value = parser.document();
  return StrictJson(value, parser.inadmissible);
}

/// Escapes one reference token for a JSON Pointer.
String pointerToken(Object token) =>
    '$token'.replaceAll('~', '~0').replaceAll('/', '~1');

final class _Parser {
  _Parser(this._text);

  final String _text;
  int _at = 0;
  final List<String> _path = [];
  final Map<String, String> inadmissible = {};

  String get _pointer => _path.map((t) => '/${pointerToken(t)}').join();

  Never _fail(String message) => throw JsonTextException(message, _pointer);

  Object? document() {
    final value = _value();
    _space();
    if (_at != _text.length) _fail('Trailing text after the JSON value');
    return value;
  }

  void _space() {
    while (_at < _text.length) {
      final c = _text.codeUnitAt(_at);
      if (c != 0x20 && c != 0x0A && c != 0x0D && c != 0x09) return;
      _at++;
    }
  }

  Object? _value() {
    _space();
    if (_at >= _text.length) _fail('Unexpected end of JSON text');
    final c = _text[_at];
    switch (c) {
      case '{':
        return _object();
      case '[':
        return _array();
      case '"':
        return _string();
      case 't':
        return _literal('true', true);
      case 'f':
        return _literal('false', false);
      case 'n':
        return _literal('null', null);
      default:
        return _number();
    }
  }

  Object? _literal(String word, Object? value) {
    if (!_text.startsWith(word, _at)) _fail('Invalid JSON literal');
    _at += word.length;
    return value;
  }

  JsonMap _object() {
    _at++;
    final result = <String, Object?>{};
    _space();
    if (_peek('}')) return result;
    while (true) {
      _space();
      if (!_peek('"', consume: false)) _fail('Expected a member name');
      final name = _string();
      if (result.containsKey(name)) {
        _path.add(name);
        _fail('Duplicate decoded member name');
      }
      _space();
      if (!_peek(':')) _fail('Expected ":" after a member name');
      _path.add(name);
      result[name] = _value();
      _path.removeLast();
      _space();
      if (_peek('}')) return result;
      if (!_peek(',')) _fail('Expected "," or "}" in an object');
    }
  }

  List<Object?> _array() {
    _at++;
    final result = <Object?>[];
    _space();
    if (_peek(']')) return result;
    while (true) {
      _path.add('${result.length}');
      result.add(_value());
      _path.removeLast();
      _space();
      if (_peek(']')) return result;
      if (!_peek(',')) _fail('Expected "," or "]" in an array');
    }
  }

  bool _peek(String char, {bool consume = true}) {
    if (_at < _text.length && _text[_at] == char) {
      if (consume) _at++;
      return true;
    }
    return false;
  }

  String _string() {
    _at++;
    final units = <int>[];
    while (true) {
      if (_at >= _text.length) _fail('Unterminated string');
      final c = _text.codeUnitAt(_at++);
      if (c == 0x22) break;
      if (c < 0x20) _fail('Unescaped control character in a string');
      if (c != 0x5C) {
        units.add(c);
        continue;
      }
      if (_at >= _text.length) _fail('Unterminated escape');
      final e = _text[_at++];
      switch (e) {
        case '"' || r'\' || '/':
          units.add(e.codeUnitAt(0));
        case 'b':
          units.add(0x08);
        case 'f':
          units.add(0x0C);
        case 'n':
          units.add(0x0A);
        case 'r':
          units.add(0x0D);
        case 't':
          units.add(0x09);
        case 'u':
          if (_at + 4 > _text.length) _fail('Truncated unicode escape');
          final hex = int.tryParse(_text.substring(_at, _at + 4), radix: 16);
          if (hex == null) _fail('Invalid unicode escape');
          units.add(hex);
          _at += 4;
        default:
          _fail('Invalid escape');
      }
    }
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      if (u >= 0xD800 && u <= 0xDBFF) {
        final next = i + 1 < units.length ? units[i + 1] : 0;
        if (next < 0xDC00 || next > 0xDFFF) {
          _fail('Invalid Unicode scalar string');
        }
        i++;
      } else if (u >= 0xDC00 && u <= 0xDFFF) {
        _fail('Invalid Unicode scalar string');
      }
    }
    return String.fromCharCodes(units);
  }

  static final _numberPattern = RegExp(
    r'-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?',
  );

  num _number() {
    final match = _numberPattern.matchAsPrefix(_text, _at);
    if (match == null) _fail('Invalid JSON value');
    final literal = match[0]!;
    _at = match.end;
    final asDouble = double.parse(literal);
    final integral = match[2] == null && match[3] == null;
    final exact = _Decimal.parse(literal);
    final admissible =
        asDouble.isFinite &&
        exact != null &&
        exact == _Decimal.parse(_shortest(asDouble));
    if (!admissible) {
      // An exponent too large to normalize keeps its literal, which no
      // admissible spelling can equal.
      inadmissible[_pointer] = exact?.spelling ?? literal;
    }
    // An overflowing literal is already inadmissible; it parses to the
    // largest finite value of its sign so the request stays encodable.
    if (asDouble.isInfinite) {
      return asDouble.isNegative ? -double.maxFinite : double.maxFinite;
    }
    if (integral) return int.tryParse(literal) ?? asDouble;
    return asDouble;
  }
}

/// The shortest literal that round-trips [value] through binary64.
String _shortest(double value) {
  final text = value.toString();
  return text.contains('e') ? text.replaceFirst('e+', 'e') : text;
}

/// An exact decimal value: `±digits × 10^exponent`, normalized so equal
/// values compare equal whatever their spelling.
///
/// Normalization works on the literal's text, so it is linear in the
/// literal's length.
final class _Decimal {
  const _Decimal(this.negative, this.digits, this.exponent);

  static const _zero = _Decimal(false, '', 0);

  /// The literal's exact value, or null when its exponent is too large to
  /// represent (such a nonzero literal is never binary64-admissible).
  static _Decimal? parse(String literal) {
    var mantissa = literal;
    var exponentText = '';
    final e = literal.indexOf(RegExp('[eE]'));
    if (e >= 0) {
      mantissa = literal.substring(0, e);
      exponentText = literal.substring(e + 1);
    }
    final negative = mantissa.startsWith('-');
    if (negative) mantissa = mantissa.substring(1);
    final dot = mantissa.indexOf('.');
    var fraction = 0;
    if (dot >= 0) {
      fraction = mantissa.length - dot - 1;
      mantissa = mantissa.substring(0, dot) + mantissa.substring(dot + 1);
    }
    var start = 0;
    while (start < mantissa.length && mantissa.codeUnitAt(start) == 0x30) {
      start++;
    }
    if (start == mantissa.length) return _zero;
    var end = mantissa.length;
    while (mantissa.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    final exponent = _exponent(exponentText);
    if (exponent == null) return null;
    return _Decimal(
      negative,
      mantissa.substring(start, end),
      exponent - fraction + (mantissa.length - end),
    );
  }

  /// A decimal exponent literal (`[+-]digits`, or empty for zero), or null
  /// beyond nine significant digits.
  static int? _exponent(String text) {
    if (text.isEmpty) return 0;
    final negative = text.startsWith('-');
    var digits = text.startsWith('-') || text.startsWith('+')
        ? text.substring(1)
        : text;
    digits = digits.replaceFirst(RegExp('^0+'), '');
    if (digits.isEmpty) return 0;
    if (digits.length > 9) return null;
    final value = int.parse(digits);
    return negative ? -value : value;
  }

  /// The exact value of [n], or null for a non-finite double. A double
  /// denotes the value of its shortest round-trip literal, as the literal
  /// it would be written as does.
  static _Decimal? of(num n) => switch (n) {
    final int i => parse('$i'),
    final double d when d.isFinite => parse(_shortest(d)),
    _ => null,
  };

  final bool negative;
  final String digits;
  final int exponent;

  /// The one spelling of this value: `0`, or `[-]digits` `e` `exponent`
  /// with no leading or trailing zero digit, which is itself a JSON number.
  String get spelling =>
      digits.isEmpty ? '0' : '${negative ? '-' : ''}${digits}e$exponent';

  @override
  bool operator ==(Object other) =>
      other is _Decimal &&
      other.negative == negative &&
      other.exponent == exponent &&
      other.digits == digits;

  @override
  int get hashCode => Object.hash(negative, digits, exponent);
}

/// Whether a Scope admits [n] as a JSON number: whether [n] is finite and
/// its exact decimal value survives conversion to the nearest binary64
/// value and back to that value's shortest literal.
///
/// Every finite double is admissible. An integer is admissible only when
/// that literal denotes the integer itself: every integer of magnitude up
/// to 2^53 is, and 9007199254740993 is not, since the nearest binary64
/// value prints as 9007199254740992. An authority refuses a request that
/// carries a number this rejects, at any depth, as "Number literal is not
/// admissible", so a value checked with it before it is written is never
/// refused for its numbers.
bool isAdmissibleNumber(num n) => switch (n) {
  final int i => _Decimal.of(i) == _Decimal.of(i.toDouble()),
  final double d => d.isFinite,
};

/// Whether two numbers denote the same exact decimal value.
bool _numbersEqual(num a, num b) {
  if (a is int && b is int) return a == b;
  if (a is double && b is double) return a == b;
  final exact = _Decimal.of(a);
  return exact != null && exact == _Decimal.of(b);
}

/// JSON value equality under RFC 6902 §4.6: object member order is ignored
/// and numbers compare by exact decimal value, so `1` and `1.0` are equal and
/// `9007199254740993` and `9007199254740992.0` are not.
bool jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return _numbersEqual(a, b);
  return a == b;
}

/// Serializes [value] with object members sorted, so equal values under
/// [jsonEquals] (modulo number spelling) produce identical text.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _sorted(value[k])};
  }
  if (value is List) return [for (final v in value) _sorted(v)];
  return value;
}

/// The text of [value]'s semantic identity, as an authority reads a
/// request to identify it: object members sorted by key, and every number
/// in the one spelling of its exact decimal value — `0`, or
/// `[-]digits` `e` `exponent` with no leading or trailing zero digit.
///
/// Values equal as JSON values — `1`, `1.0` and `1e0`, or `0` and `-0.0` —
/// produce identical text, and values that differ in any digit do not:
/// `9007199254740993` and `9007199254740992.0` are two, though Dart's `==`
/// calls them equal. No number is converted to binary64 on the way. A
/// non-finite double, which no admitted request carries, is written as its
/// bare name, so the text is JSON exactly when the value is.
///
/// [value] is a JSON value: null, a bool, a string, a number, a list of
/// JSON values or a map with string keys. Digest the text to identify a
/// value the way the Scope does.
String semanticText(Object? value) {
  final out = StringBuffer();
  void write(Object? v) {
    switch (v) {
      case Map():
        final keys = v.keys.cast<String>().toList()..sort();
        out.write('{');
        for (var i = 0; i < keys.length; i++) {
          if (i > 0) out.write(',');
          out
            ..write(jsonEncode(keys[i]))
            ..write(':');
          write(v[keys[i]]);
        }
        out.write('}');
      case List():
        out.write('[');
        for (var i = 0; i < v.length; i++) {
          if (i > 0) out.write(',');
          write(v[i]);
        }
        out.write(']');
      case final num n:
        out.write(_Decimal.of(n)?.spelling ?? '$n');
      default:
        out.write(jsonEncode(v));
    }
  }

  write(value);
  return out.toString();
}

/// A deep copy of a decoded JSON value that is unmodifiable at every depth.
Object? freezeJson(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final e in value.entries) e.key as String: freezeJson(e.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(freezeJson));
  return value;
}

/// A deep, mutable copy of a decoded JSON value.
Object? jsonCopy(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries) e.key as String: jsonCopy(e.value),
    };
  }
  if (value is List) return [for (final v in value) jsonCopy(v)];
  return value;
}

/// Decodes stored JSON text that this library wrote itself.
JsonMap decodeMap(String text) => jsonDecode(text) as JsonMap;
