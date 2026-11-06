import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'json_text.dart';

/// The constraint a Link Type places on one endpoint.
final class AuthorityEndpointConstraint {
  const AuthorityEndpointConstraint._(this.conformsTo, this.external);

  factory AuthorityEndpointConstraint._fromJson(Object? json) {
    if (json == null) return const AuthorityEndpointConstraint._([], 'opaque');
    if (json is! Map) throw ArgumentError('endpoint constraint is an object');
    final external = json['external'] ?? 'opaque';
    if (external is! String || !_externalPolicies.contains(external)) {
      throw ArgumentError('external is one of $_externalPolicies');
    }
    return AuthorityEndpointConstraint._(
      _typeIds(json['conformsTo']),
      external,
    );
  }

  static const _externalPolicies = {'none', 'opaque', 'bead'};

  /// Types every in-Scope endpoint Bead must effectively conform to.
  final List<String> conformsTo;

  /// The external-endpoint policy: `none`, `opaque`, or `bead`.
  final String external;

  JsonMap toJson() => {
    'conformsTo': conformsTo,
    if (external != 'opaque') 'external': external,
  };
}

List<String> _typeIds(Object? json) {
  if (json == null) return const [];
  if (json is! List || json.any((e) => e is! String)) {
    throw ArgumentError('conformsTo is an array of Type URLs');
  }
  return List.unmodifiable(json.cast<String>());
}

/// An installed Type Descriptor: a Type's identity, category, conformance,
/// properties schema URL and, for a Link Type, endpoint constraints.
final class AuthorityTypeDescriptor {
  const AuthorityTypeDescriptor._({
    required this.id,
    required this.name,
    required this.description,
    required this.describes,
    required this.conformsTo,
    required this.propertiesSchema,
    required this.source,
    required this.target,
  });

  /// Parses a descriptor; throws [ArgumentError] when it is not one.
  factory AuthorityTypeDescriptor.fromJson(JsonMap json) {
    const members = {
      'id',
      'name',
      'description',
      'describes',
      'conformsTo',
      'propertiesSchema',
      'source',
      'target',
    };
    final extra = json.keys.where((k) => !members.contains(k));
    if (extra.isNotEmpty) throw ArgumentError('unsupported members $extra');
    final id = json['id'];
    final name = json['name'];
    final describes = json['describes'];
    final schema = json['propertiesSchema'];
    final description = json['description'];
    final uri = id is String ? Uri.tryParse(id) : null;
    if (id is! String ||
        uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError('id is an absolute http(s) Type URL');
    }
    if (name is! String || name.isEmpty) throw ArgumentError('name required');
    if (description != null && description is! String) {
      throw ArgumentError('description is a string');
    }
    if (schema != null && schema is! String) {
      throw ArgumentError('propertiesSchema is a URL');
    }
    final kind = switch (describes) {
      'bead' => AuthorityResourceKind.bead,
      'link' => AuthorityResourceKind.link,
      _ => throw ArgumentError('describes is "bead" or "link"'),
    };
    final isLink = kind == AuthorityResourceKind.link;
    if (!isLink && (json.containsKey('source') || json.containsKey('target'))) {
      throw ArgumentError('only a Link Type carries endpoint constraints');
    }
    return AuthorityTypeDescriptor._(
      id: id,
      name: name,
      description: description as String?,
      describes: kind,
      conformsTo: _typeIds(json['conformsTo']),
      propertiesSchema: schema as String?,
      source: isLink
          ? AuthorityEndpointConstraint._fromJson(json['source'])
          : null,
      target: isLink
          ? AuthorityEndpointConstraint._fromJson(json['target'])
          : null,
    );
  }

  final String id;
  final String name;
  final String? description;
  final AuthorityResourceKind describes;
  final List<String> conformsTo;
  final String? propertiesSchema;
  final AuthorityEndpointConstraint? source;
  final AuthorityEndpointConstraint? target;

  /// The `types/` inventory summary.
  JsonMap get summary => {'id': id, 'name': name, 'describes': describes.name};

  JsonMap toJson() => {
    'id': id,
    'name': name,
    'description': ?description,
    'describes': describes.name,
    'conformsTo': conformsTo,
    'propertiesSchema': ?propertiesSchema,
    if (source case final s?) 'source': s.toJson(),
    if (target case final t?) 'target': t.toJson(),
  };
}

/// The revision of a Type: a digest of its [descriptor] and [schema].
///
/// Local discipline, as a Resource revision is: SHA-256 over the canonical
/// JSON of `{descriptor, schema}`, base64url, first 22 characters. Equal
/// content shares a revision, so a writer names the revision of the Type it
/// writes under without asking the store.
String authorityTypeRevisionOf(
  AuthorityTypeDescriptor descriptor,
  JsonMap? schema,
) {
  final content = canonicalJson({
    'descriptor': descriptor.toJson(),
    'schema': schema,
  });
  return base64Url
      .encode(sha256.convert(utf8.encode(content)).bytes)
      .substring(0, 22);
}

/// One installed revision of a Type: the [descriptor] and [schema] pinned
/// under [type] by one installation, named by [revision].
final class AuthorityTypeRevision {
  AuthorityTypeRevision._(this.descriptor, this.schema)
    : type = descriptor.id,
      revision = authorityTypeRevisionOf(descriptor, schema);

  /// The Type ID.
  final String type;

  /// The digest [authorityTypeRevisionOf] gives [descriptor] and [schema].
  final String revision;

  final AuthorityTypeDescriptor descriptor;

  /// The properties schema, unmodifiable at every depth, or null.
  final JsonMap? schema;

  @override
  bool operator ==(Object other) =>
      other is AuthorityTypeRevision &&
      other.type == type &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(type, revision);

  @override
  String toString() => 'AuthorityTypeRevision($type, $revision)';
}

/// The installed Types and their pinned properties schemas.
///
/// A Type is installed only after its parents, so the conformance graph is
/// acyclic by construction and every contract closure is local. Installed
/// schemas are deep, unmodifiable copies: neither the installer's map nor
/// [schemaOf]'s result can change a contract once it is installed.
///
/// Each Type ID has one current contract, the revision installed last.
/// Installing other content at an installed ID pins a new revision beside
/// the earlier ones, never over them: [revisionsOf] lists every revision in
/// installation order, and every other member answers the current one.
///
/// A registry built with the public constructor is a standalone validator.
/// The one a `ScopeAuthority` exposes is a read-only view of the Types
/// pinned in its store; Types reach it only through
/// `ScopeAuthority.installType`, and [install] on it throws [StateError].
final class AuthorityTypeRegistry {
  AuthorityTypeRegistry()
    : _pinned = false,
      _types = {},
      _schemas = {},
      _revisions = {};

  AuthorityTypeRegistry._pinnedCopy(AuthorityTypeRegistry from)
    : _pinned = true,
      _types = {...from._types},
      _schemas = {...from._schemas},
      _revisions = _copyRevisions(from);

  final bool _pinned;
  final Map<String, AuthorityTypeDescriptor> _types;
  final Map<String, JsonMap> _schemas;
  final Map<String, List<AuthorityTypeRevision>> _revisions;

  static Map<String, List<AuthorityTypeRevision>> _copyRevisions(
    AuthorityTypeRegistry from,
  ) => {
    for (final MapEntry(:key, :value) in from._revisions.entries)
      key: [...value],
  };

  /// Every installed Type, at its current revision, in installation order.
  Iterable<AuthorityTypeDescriptor> get all => _types.values;

  /// How many Types are installed.
  int get length => _types.length;

  AuthorityTypeDescriptor? operator [](String id) => _types[id];

  /// The schema pinned for [descriptor]'s current revision, if it declares
  /// one. It is unmodifiable at every depth.
  JsonMap? schemaOf(AuthorityTypeDescriptor descriptor) =>
      _schemas[descriptor.id];

  /// Every revision installed under [id], in installation order, the last
  /// the current one; empty for an ID not installed.
  List<AuthorityTypeRevision> revisionsOf(String id) =>
      List.unmodifiable(_revisions[id] ?? const <AuthorityTypeRevision>[]);

  /// Installs [descriptor] with its properties [schema].
  ///
  /// Reinstalling content identical to the current revision is a no-op;
  /// other content at an installed Type ID installs as its new current
  /// revision. A missing parent, a category mismatch, a revision that
  /// changes what the Type describes or makes conformance cyclic, or a
  /// schema using a construct this validator does not implement throws
  /// [ArgumentError].
  void install(AuthorityTypeDescriptor descriptor, {JsonMap? schema}) {
    if (_pinned) {
      throw StateError(
        'this registry mirrors a store; install through '
        'ScopeAuthority.installType',
      );
    }
    _add(descriptor, schema == null ? null : freezeJson(schema) as JsonMap);
  }

  /// Checks and adds a Type, or a revision of one, whose [schema] is already
  /// frozen; false when it is identical to the current revision.
  bool _add(AuthorityTypeDescriptor descriptor, JsonMap? schema) {
    final existing = _types[descriptor.id];
    if (existing != null) {
      final same =
          jsonEquals(existing.toJson(), descriptor.toJson()) &&
          jsonEquals(_schemas[descriptor.id], schema);
      if (same) return false;
      if (existing.describes != descriptor.describes) {
        throw ArgumentError(
          '${descriptor.id} describes ${existing.describes.name}; '
          'a revision does not change it',
        );
      }
    }
    for (final parent in descriptor.conformsTo) {
      final p = _types[parent];
      if (p == null) throw ArgumentError('parent $parent is not installed');
      if (p.describes != descriptor.describes) {
        throw ArgumentError('parent $parent describes another category');
      }
      if (existing != null && effectiveTypes(parent).contains(descriptor.id)) {
        throw ArgumentError(
          'parent $parent conforms to ${descriptor.id}; the revision would '
          'make conformance cyclic',
        );
      }
    }
    for (final endpoint in [descriptor.source, descriptor.target]) {
      for (final required in endpoint?.conformsTo ?? const <String>[]) {
        if (_types[required]?.describes != AuthorityResourceKind.bead) {
          throw ArgumentError(
            'endpoint Type $required is not an installed '
            'Bead Type',
          );
        }
      }
    }
    if ((descriptor.propertiesSchema == null) != (schema == null)) {
      throw ArgumentError('propertiesSchema and schema go together');
    }
    if (schema != null) {
      final root = schema['additionalProperties'];
      final rootUnevaluated = schema['unevaluatedProperties'];
      if ((root != null && root != true) ||
          (rootUnevaluated != null && rootUnevaluated != true)) {
        throw ArgumentError('a properties schema root stays open');
      }
      _checkSchema(schema);
      _schemas[descriptor.id] = schema;
    } else {
      _schemas.remove(descriptor.id);
    }
    _types[descriptor.id] = descriptor;
    (_revisions[descriptor.id] ??= []).add(
      AuthorityTypeRevision._(descriptor, schema),
    );
    return true;
  }

  /// [id] plus the transitive closure of its `conformsTo`.
  Set<String> effectiveTypes(String id) {
    final result = <String>{};
    void visit(String t) {
      if (!result.add(t)) return;
      for (final parent in _types[t]?.conformsTo ?? const <String>[]) {
        visit(parent);
      }
    }

    visit(id);
    return result;
  }

  /// Every installed Type whose effective set contains [id].
  Set<String> conformingTo(String id) => {
    for (final t in _types.keys)
      if (effectiveTypes(t).contains(id)) t,
  };

  /// Validates [properties] against every effective Type's schema, returning
  /// `validation-failed` diagnostics (empty when valid).
  List<JsonMap> validate(String typeId, JsonMap properties) {
    final diagnostics = <JsonMap>[];
    for (final t in effectiveTypes(typeId)) {
      final descriptor = _types[t]!;
      final schema = _schemas[t];
      if (schema == null) continue;
      _Validation(
        typeId: t,
        schemaId: descriptor.propertiesSchema!,
        root: schema,
        diagnostics: diagnostics,
      ).check(schema, properties, '', '');
    }
    return diagnostics;
  }

  /// Projects [properties] written under an earlier revision of [typeId]
  /// through its current one: a diagnostic for each member that no
  /// effective Type's current schema declares at its root (when one of them
  /// has a schema), followed by [validate]'s. Empty when the current
  /// revision reads the properties as they were written. Throws
  /// [ArgumentError] for a Type not installed.
  List<JsonMap> project(String typeId, JsonMap properties) {
    if (_types[typeId] == null) {
      throw ArgumentError('$typeId is not installed');
    }
    final schemas = [
      for (final t in effectiveTypes(typeId))
        if (_schemas[t] case final schema?) (t, schema),
    ];
    final diagnostics = <JsonMap>[];
    if (schemas case [(final first, _), ...]) {
      for (final member in properties.keys) {
        final declared = schemas.any(
          (s) => (s.$2['properties'] as Map?)?.containsKey(member) ?? false,
        );
        if (declared) continue;
        diagnostics.add({
          'type': first,
          'schemaLocation': '${_types[first]!.propertiesSchema}#/properties',
          'instanceLocation': '/${pointerToken(member)}',
          'message': 'member "$member" is not declared by the current revision',
        });
      }
    }
    return [...diagnostics, ...validate(typeId, properties)];
  }
}

/// The read-only registry of the Types pinned in a store, from its rows in
/// installation order.
AuthorityTypeRegistry pinnedTypes(Iterable<(JsonMap, JsonMap?)> rows) {
  final registry = AuthorityTypeRegistry();
  for (final (descriptor, schema) in rows) {
    registry._add(
      AuthorityTypeDescriptor.fromJson(descriptor),
      schema == null ? null : freezeJson(schema) as JsonMap,
    );
  }
  return AuthorityTypeRegistry._pinnedCopy(registry);
}

/// [pinned] plus [descriptor], as the read-only registry the store holds
/// once the Type is pinned, or, when other content is pinned at its ID, once
/// its new revision is; null when content identical to the current revision
/// is already pinned. Throws [ArgumentError] when the Type cannot be
/// installed. [pinned] is unchanged either way.
AuthorityTypeRegistry? withType(
  AuthorityTypeRegistry pinned,
  AuthorityTypeDescriptor descriptor,
  JsonMap? schema,
) {
  final staged = AuthorityTypeRegistry().._types.addAll(pinned._types);
  staged._schemas.addAll(pinned._schemas);
  staged._revisions.addAll(AuthorityTypeRegistry._copyRevisions(pinned));
  if (!staged._add(descriptor, schema)) return null;
  return AuthorityTypeRegistry._pinnedCopy(staged);
}

/// The only dialect the validator implements.
const _dialect = 'https://json-schema.org/draft/2020-12/schema';

const _keywords = {
  r'$schema', r'$id', r'$defs', r'$ref', r'$comment', 'title', //
  'description', 'default', 'examples', 'format', 'deprecated', 'readOnly',
  'writeOnly', 'type', 'enum', 'const', 'properties', 'required',
  'additionalProperties', 'unevaluatedProperties', 'items', 'minItems',
  'maxItems', 'uniqueItems', 'minLength', 'maxLength', 'pattern', 'minimum',
  'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'minProperties',
  'maxProperties', 'allOf', 'anyOf', 'oneOf', 'not',
};

const _typeNames = {
  'object', 'array', 'string', 'number', 'integer', 'boolean', 'null', //
};

/// Refuses a schema unless every construct in it means, to the validator,
/// what it means in JSON Schema 2020-12: only the listed keywords with
/// well-formed values, `$schema` and `$id` at the root only, and `$ref` only
/// as a JSON Pointer fragment naming a subschema of this document, never
/// one that re-enters itself without descending into the instance.
void _checkSchema(JsonMap root) {
  final locations = <String, Object?>{};
  final refs = <String, String>{};
  _checkKeywords(root, '', locations, refs);
  for (final MapEntry(key: at, value: ref) in refs.entries) {
    final target = _fragmentPointer(ref);
    if (!locations.containsKey(target)) {
      throw ArgumentError('\$ref "$ref" at "$at" names no subschema');
    }
  }
  // Edges that apply another subschema to the same instance; a cycle among
  // them would never terminate.
  List<String> sameInstance(String at) {
    final schema = locations[at];
    if (schema is! Map) return const [];
    return [
      if (refs[at] case final ref?) _fragmentPointer(ref),
      for (final key in ['allOf', 'anyOf', 'oneOf'])
        if (schema[key] case final List<Object?> list)
          for (var i = 0; i < list.length; i++) '$at/$key/$i',
      if (schema.containsKey('not')) '$at/not',
    ];
  }

  final done = <String>{};
  final onPath = <String>{};
  void visit(String at) {
    if (done.contains(at)) return;
    if (!onPath.add(at)) {
      throw ArgumentError('\$ref cycle through "$at" never descends');
    }
    sameInstance(at).forEach(visit);
    onPath.remove(at);
    done.add(at);
  }

  locations.keys.forEach(visit);
}

/// The JSON Pointer a local `$ref` names: `#` or `#/…`, percent-decoded.
String _fragmentPointer(String ref) {
  if (!ref.startsWith('#')) {
    throw ArgumentError(r'only local $ref is implemented');
  }
  final String pointer;
  try {
    pointer = Uri.decodeComponent(ref.substring(1));
  } on Object {
    // An invalid escape is an ArgumentError, invalid UTF-8 a FormatException.
    throw ArgumentError('\$ref "$ref" is not percent-encoded correctly');
  }
  if (pointer.isNotEmpty && !pointer.startsWith('/')) {
    throw ArgumentError(
      '\$ref "$ref" is an anchor; only JSON Pointer fragments are implemented',
    );
  }
  return pointer;
}

void _checkKeywords(
  Object? schema,
  String at,
  Map<String, Object?> locations,
  Map<String, String> refs,
) {
  locations[at] = schema;
  if (schema is bool) return;
  if (schema is! Map) {
    throw ArgumentError('schema at "$at" is not an object or boolean');
  }
  Never refuse(String key, String why) =>
      throw ArgumentError('schema keyword "$key" at "$at" $why');
  void sub(Object? value, String path) =>
      _checkKeywords(value, '$at/$path', locations, refs);
  for (final entry in schema.entries) {
    final key = entry.key as String;
    final value = entry.value;
    if (!_keywords.contains(key)) refuse(key, 'is not implemented');
    switch (key) {
      case r'$schema':
        if (at.isNotEmpty) refuse(key, 'is only implemented at the root');
        if (value != _dialect && value != '$_dialect#') {
          refuse(key, 'names a dialect other than $_dialect');
        }
      case r'$id':
        if (at.isNotEmpty) refuse(key, 'is only implemented at the root');
        if (value is! String) refuse(key, 'is not a string');
        final fragment = value.indexOf('#');
        if (fragment >= 0 && fragment != value.length - 1) {
          refuse(key, 'has a fragment');
        }
      case r'$ref':
        if (value is! String) refuse(key, 'is not a string');
        _fragmentPointer(value);
        refs[at] = value;
      case 'type':
        final names = value is List ? value : [value];
        if (names.isEmpty ||
            names.any((n) => !_typeNames.contains(n)) ||
            names.toSet().length != names.length) {
          refuse(key, 'is not a type name or a list of distinct ones');
        }
      case 'enum' || 'examples' when value is! List:
        refuse(key, 'is not an array');
      case 'required'
          when value is! List ||
              value.any((n) => n is! String) ||
              value.toSet().length != value.length:
        refuse(key, 'is not an array of distinct strings');
      case 'properties' || r'$defs':
        if (value is! Map) refuse(key, 'is not an object');
        for (final e in value.entries) {
          sub(e.value, '$key/${pointerToken(e.key as Object)}');
        }
      case 'allOf' || 'anyOf' || 'oneOf':
        if (value is! List || value.isEmpty) {
          refuse(key, 'is not a nonempty array');
        }
        for (var i = 0; i < value.length; i++) {
          sub(value[i], '$key/$i');
        }
      case 'items' || 'not' || 'additionalProperties':
        sub(value, key);
      case 'unevaluatedProperties' when value != true:
        refuse(key, 'is not implemented');
      case 'minItems' ||
              'maxItems' ||
              'minLength' ||
              'maxLength' ||
              'minProperties' ||
              'maxProperties'
          when value is! int || value < 0:
        refuse(key, 'is not a non-negative integer');
      case 'minimum' || 'maximum' || 'exclusiveMinimum' || 'exclusiveMaximum'
          when value is! num:
        refuse(key, 'is not a number');
      case 'uniqueItems' || 'deprecated' || 'readOnly' || 'writeOnly'
          when value is! bool:
        refuse(key, 'is not a boolean');
      case 'title' || 'description' || r'$comment' || 'format'
          when value is! String:
        refuse(key, 'is not a string');
      case 'pattern':
        if (value is! String) refuse(key, 'is not a string');
        try {
          RegExp(value, unicode: true);
        } on FormatException {
          refuse(key, 'is not a regular expression');
        }
    }
  }
}

final class _Validation {
  _Validation({
    required this.typeId,
    required this.schemaId,
    required this.root,
    required this.diagnostics,
  });

  final String typeId;
  final String schemaId;
  final JsonMap root;
  final List<JsonMap> diagnostics;

  void _fail(String schemaAt, String instanceAt, String message) =>
      diagnostics.add({
        'type': typeId,
        'schemaLocation': '$schemaId#$schemaAt',
        'instanceLocation': instanceAt,
        'message': message,
      });

  bool valid(Object? schema, Object? value, String schemaAt) {
    final probe = _Validation(
      typeId: typeId,
      schemaId: schemaId,
      root: root,
      diagnostics: [],
    );
    probe.check(schema, value, schemaAt, '');
    return probe.diagnostics.isEmpty;
  }

  void check(Object? schema, Object? value, String s, String i) {
    if (schema == true) return;
    if (schema == false) return _fail(s, i, 'no value is allowed here');
    final m = schema! as Map;
    if (m[r'$ref'] case final String ref) {
      check(_resolve(ref), value, ref.substring(1), i);
    }
    if (m['type'] case final Object type) {
      final allowed = type is List ? type.cast<String>() : [type as String];
      if (!allowed.any((t) => _isType(t, value))) {
        _fail('$s/type', i, 'expected ${allowed.join(' or ')}');
        return;
      }
    }
    if (m['enum'] case final List<Object?> options
        when !options.any((o) => jsonEquals(o, value))) {
      _fail('$s/enum', i, 'value is not one of the enumerated values');
    }
    if (m.containsKey('const') && !jsonEquals(m['const'], value)) {
      _fail('$s/const', i, 'value is not the constant');
    }
    if (value is Map) _object(m, value, s, i);
    if (value is List) _array(m, value, s, i);
    if (value is String) _string(m, value, s, i);
    if (value is num) _number(m, value, s, i);
    if (m['allOf'] case final List<Object?> all) {
      for (var k = 0; k < all.length; k++) {
        check(all[k], value, '$s/allOf/$k', i);
      }
    }
    if (m['anyOf'] case final List<Object?> any) {
      var ok = false;
      for (var k = 0; k < any.length && !ok; k++) {
        ok = valid(any[k], value, '$s/anyOf/$k');
      }
      if (!ok) _fail('$s/anyOf', i, 'value matches no anyOf subschema');
    }
    if (m['oneOf'] case final List<Object?> one) {
      var matches = 0;
      for (var k = 0; k < one.length; k++) {
        if (valid(one[k], value, '$s/oneOf/$k')) matches++;
      }
      if (matches != 1) _fail('$s/oneOf', i, 'value matches $matches oneOf');
    }
    if (m.containsKey('not') && valid(m['not'], value, '$s/not')) {
      _fail('$s/not', i, 'value matches the not subschema');
    }
  }

  /// The subschema a local `$ref` names; installation proved it exists.
  Object? _resolve(String ref) {
    Object? at = root;
    final pointer = _fragmentPointer(ref);
    if (pointer.isEmpty) return at;
    for (final token in pointer.substring(1).split('/')) {
      final key = token.replaceAll('~1', '/').replaceAll('~0', '~');
      at = switch (at) {
        final Map<Object?, Object?> map => map[key],
        final List<Object?> list => list[int.parse(key)],
        _ => null,
      };
    }
    return at;
  }

  static bool _isType(String type, Object? value) => switch (type) {
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'number' => value is num,
    'integer' => value is int || (value is double && value == value.floor()),
    'boolean' => value is bool,
    'null' => value == null,
    _ => false,
  };

  void _object(
    Map<Object?, Object?> m,
    Map<Object?, Object?> v,
    String s,
    String i,
  ) {
    if (m['required'] case final List<Object?> required) {
      for (final name in required) {
        if (!v.containsKey(name)) {
          _fail('$s/required', i, 'missing required member "$name"');
        }
      }
    }
    final properties = (m['properties'] as Map?) ?? const {};
    for (final entry in v.entries) {
      final key = entry.key! as String;
      final at = '$i/${pointerToken(key)}';
      if (properties.containsKey(key)) {
        check(
          properties[key],
          entry.value,
          '$s/properties/${pointerToken(key)}',
          at,
        );
      } else if (m.containsKey('additionalProperties')) {
        check(
          m['additionalProperties'],
          entry.value,
          '$s/additionalProperties',
          at,
        );
      }
    }
    if (m['minProperties'] case final int min when v.length < min) {
      _fail('$s/minProperties', i, 'fewer than $min members');
    }
    if (m['maxProperties'] case final int max when v.length > max) {
      _fail('$s/maxProperties', i, 'more than $max members');
    }
  }

  void _array(Map<Object?, Object?> m, List<Object?> v, String s, String i) {
    if (m.containsKey('items')) {
      for (var k = 0; k < v.length; k++) {
        check(m['items'], v[k], '$s/items', '$i/$k');
      }
    }
    if (m['minItems'] case final int min when v.length < min) {
      _fail('$s/minItems', i, 'fewer than $min items');
    }
    if (m['maxItems'] case final int max when v.length > max) {
      _fail('$s/maxItems', i, 'more than $max items');
    }
    if (m['uniqueItems'] == true) {
      for (var a = 0; a < v.length; a++) {
        for (var b = a + 1; b < v.length; b++) {
          if (jsonEquals(v[a], v[b])) {
            return _fail('$s/uniqueItems', i, 'items are not unique');
          }
        }
      }
    }
  }

  void _string(Map<Object?, Object?> m, String v, String s, String i) {
    final length = v.runes.length;
    if (m['minLength'] case final int min when length < min) {
      _fail('$s/minLength', i, 'shorter than $min');
    }
    if (m['maxLength'] case final int max when length > max) {
      _fail('$s/maxLength', i, 'longer than $max');
    }
    if (m['pattern'] case final String p
        when !RegExp(p, unicode: true).hasMatch(v)) {
      _fail('$s/pattern', i, 'does not match $p');
    }
  }

  void _number(Map<Object?, Object?> m, num v, String s, String i) {
    if (m['minimum'] case final num min when v < min) {
      _fail('$s/minimum', i, 'less than $min');
    }
    if (m['maximum'] case final num max when v > max) {
      _fail('$s/maximum', i, 'greater than $max');
    }
    if (m['exclusiveMinimum'] case final num min when v <= min) {
      _fail('$s/exclusiveMinimum', i, 'not greater than $min');
    }
    if (m['exclusiveMaximum'] case final num max when v >= max) {
      _fail('$s/exclusiveMaximum', i, 'not less than $max');
    }
  }
}
