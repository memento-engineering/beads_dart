import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'json_text.dart';
import 'patch.dart';
import 'problem.dart';

/// The six single-Resource operations, with their wire discriminator and
/// singleton target name.
enum OperationKind {
  createBead('create-bead', AuthorityResourceKind.bead),
  updateBeadProperties('update-bead-properties', AuthorityResourceKind.bead),
  deleteBead('delete-bead', AuthorityResourceKind.bead),
  createLink('create-link', AuthorityResourceKind.link),
  updateLinkProperties('update-link-properties', AuthorityResourceKind.link),
  deleteLink('delete-link', AuthorityResourceKind.link);

  const OperationKind(this.target, this.kind);

  /// The singleton target's path segment under `operations/`.
  final String target;

  /// The kind of Resource the operation acts on.
  final AuthorityResourceKind kind;

  static OperationKind? byTarget(String target) =>
      values.where((k) => k.target == target).firstOrNull;
}

/// A Resource reference after spelling resolution.
sealed class Ref {
  const Ref();
}

/// An absolute canonical in-Scope URL of the required kind.
final class CanonicalRef extends Ref {
  const CanonicalRef(this.url);
  final String url;
}

/// A batch-local reference to an earlier creation that supplied no `id`.
final class LabelRef extends Ref {
  const LabelRef(this.index);
  final int index;
}

/// A spelling that cannot name a Resource of the required kind; the
/// operation fails `resource-not-found` when reached.
final class UnresolvableRef extends Ref {
  const UnresolvableRef(this.spelling);
  final String spelling;
}

/// A Link endpoint after spelling resolution, with its optional pin.
sealed class Endpoint {
  const Endpoint(this.pin);
  final String? pin;
}

/// An in-Scope endpoint that must name a live Bead.
final class LocalEndpoint extends Endpoint {
  const LocalEndpoint(this.ref, super.pin);
  final Ref ref;
}

/// An opaque out-of-Scope endpoint.
final class ExternalEndpoint extends Endpoint {
  const ExternalEndpoint(this.uri, super.pin);
  final String uri;
}

/// An in-Scope spelling that is not a Bead; fails `validation-failed`.
final class MiscategorizedEndpoint extends Endpoint {
  const MiscategorizedEndpoint(this.spelling, super.pin);
  final String spelling;
}

/// One parsed operation of a Mutation Transaction.
sealed class Operation {
  Operation(this.index, this.name, this.pointer);

  /// Zero-based position in the transaction.
  final int index;

  /// The batch-local label, when the creation declared one.
  final String? name;

  /// JSON Pointer to this operation's record in the request body.
  final String pointer;

  OperationKind get kind;

  /// The normalized record that idempotency compares.
  JsonMap get semantic;
}

final class CreateBead extends Operation {
  CreateBead(
    super.index,
    super.name,
    super.pointer, {
    required this.id,
    required this.type,
    required this.properties,
    required this.attribution,
  });

  final String? id;
  final String type;
  final JsonMap properties;
  final JsonMap? attribution;

  @override
  OperationKind get kind => OperationKind.createBead;

  @override
  JsonMap get semantic => {
    'operation': kind.name,
    'id': ?id,
    'type': type,
    'properties': properties,
    'attribution': ?attribution,
  };
}

final class CreateLink extends Operation {
  CreateLink(
    super.index,
    super.name,
    super.pointer, {
    required this.id,
    required this.type,
    required this.source,
    required this.target,
    required this.properties,
    required this.attribution,
  });

  final String? id;
  final String type;
  final Endpoint source;
  final Endpoint target;
  final JsonMap properties;
  final JsonMap? attribution;

  @override
  OperationKind get kind => OperationKind.createLink;

  @override
  JsonMap get semantic => {
    'operation': kind.name,
    'id': ?id,
    'type': type,
    'source': _endpointSemantic(source),
    'target': _endpointSemantic(target),
    'properties': properties,
    'attribution': ?attribution,
  };
}

/// An update of a Bead's or Link's properties.
final class UpdateProperties extends Operation {
  UpdateProperties(
    super.index,
    super.name,
    super.pointer, {
    required this.kind,
    required this.subject,
    required this.change,
    required this.expectedRevision,
    required this.attribution,
  });

  @override
  final OperationKind kind;
  final Ref subject;
  final List<JsonMap> change;
  final String? expectedRevision;
  final JsonMap? attribution;

  @override
  JsonMap get semantic => {
    'operation': kind.name,
    kind.kind.name: _refSemantic(subject),
    'change': change,
    'expectedRevision': ?expectedRevision,
    'attribution': ?attribution,
  };
}

/// A deletion of a Bead or Link.
final class Delete extends Operation {
  Delete(
    super.index,
    super.name,
    super.pointer, {
    required this.kind,
    required this.subject,
    required this.expectedRevision,
    required this.attribution,
  });

  @override
  final OperationKind kind;
  final Ref subject;
  final String? expectedRevision;
  final JsonMap? attribution;

  @override
  JsonMap get semantic => {
    'operation': kind.name,
    kind.kind.name: _refSemantic(subject),
    'expectedRevision': ?expectedRevision,
    'attribution': ?attribution,
  };
}

Object _refSemantic(Ref ref) => switch (ref) {
  CanonicalRef(:final url) => url,
  LabelRef(:final index) => {'@': index},
  UnresolvableRef(:final spelling) => {'unresolved': spelling},
};

JsonMap _endpointSemantic(Endpoint e) => {
  'uri': switch (e) {
    LocalEndpoint(:final ref) => _refSemantic(ref),
    ExternalEndpoint(:final uri) => uri,
    MiscategorizedEndpoint(:final spelling) => {'miscategorized': spelling},
  },
  'revision': ?e.pin,
};

/// The semantic identity of a transaction: a digest of its operations'
/// normalized records in declaration order, and of the number literals that
/// were inadmissible with the exact values they denote (their parsed values
/// are not the literals). Numbers compare by exact decimal value, so `1` and
/// `1.0`, or `0` and `-0.0`, are one request, and `9007199254740992` and
/// `9007199254740993` are two.
String semanticFingerprint(
  List<Operation> operations, {
  Map<String, String> inadmissibleNumbers = const {},
}) => sha256
    .convert(
      utf8.encode(
        semanticText([
          for (final o in operations) o.semantic,
          if (inadmissibleNumbers.isNotEmpty)
            {'inadmissibleNumbers': inadmissibleNumbers},
        ]),
      ),
    )
    .toString();

/// Parses a `batch` request body.
List<Operation> parseBatch(Object? body, ScopeAddress scope) {
  if (body is! Map<String, Object?>) {
    throw _malformed('Request body is not a batch request', '');
  }
  for (final key in body.keys) {
    if (key != 'operations') {
      throw _malformed(
        'Request body is not a batch request',
        '/${pointerToken(key)}',
      );
    }
  }
  final records = body['operations'];
  if (records is! List || records.isEmpty) {
    throw _malformed('operations is a nonempty array', '/operations');
  }
  final parser = _RecordParser(scope, batch: true);
  return [
    for (var i = 0; i < records.length; i++)
      parser.parse(records[i], i, '/operations/$i', null),
  ];
}

/// Parses a singleton target's request body.
Operation parseSingleton(
  OperationKind kind,
  Object? body,
  ScopeAddress scope,
) => _RecordParser(scope, batch: false).parse(body, 0, '', kind);

AuthorityProblem _malformed(String title, String pointer) =>
    AuthorityProblem('malformed-request', title: title, pointer: pointer);

final class _RecordParser {
  _RecordParser(this.scope, {required this.batch});

  final ScopeAddress scope;
  final bool batch;

  /// Label name -> (creating operation, resolved reference).
  final Map<String, (Operation, Ref)> _labels = {};

  static final _labelPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$');

  static const _members = {
    OperationKind.createBead: {'id', 'type', 'properties', 'attribution'},
    OperationKind.createLink: {
      'id', 'type', 'source', 'target', 'properties', 'attribution', //
    },
    OperationKind.updateBeadProperties: {
      'bead', 'change', 'expectedRevision', 'attribution', //
    },
    OperationKind.updateLinkProperties: {
      'link', 'change', 'expectedRevision', 'attribution', //
    },
    OperationKind.deleteBead: {'bead', 'expectedRevision'},
    OperationKind.deleteLink: {'link', 'expectedRevision', 'attribution'},
  };

  Operation parse(Object? record, int index, String at, OperationKind? fixed) {
    if (record is! Map<String, Object?>) {
      throw _malformed('An operation record is an object', at);
    }
    OperationKind kind;
    if (fixed != null) {
      kind = fixed;
    } else {
      final op = record['operation'];
      kind =
          OperationKind.values.where((k) => k.name == op).firstOrNull ??
          (throw const {
                'putAlias',
                'deleteAlias',
                'updateWhere',
                'deleteWhere',
              }.contains(op)
              ? AuthorityProblem(
                  'forbidden',
                  title: 'Operation is not served by this authority',
                  pointer: '$at/operation',
                )
              : _malformed('Unknown operation', '$at/operation'));
    }
    final allowed = {
      ..._members[kind]!,
      if (batch) 'operation',
      if (batch &&
          (kind == OperationKind.createBead ||
              kind == OperationKind.createLink))
        'name',
    };
    for (final key in record.keys) {
      if (!allowed.contains(key)) {
        throw _malformed('Unexpected member', '$at/${pointerToken(key)}');
      }
    }
    final name = _string(record, 'name', at, required: false);
    if (name != null && !_labelPattern.hasMatch(name)) {
      throw _malformed('Invalid label', '$at/name');
    }
    if (name != null && _labels.containsKey(name)) {
      throw _malformed('Duplicate label', '$at/name');
    }
    final attribution = _attribution(record, at);
    final operation = switch (kind) {
      OperationKind.createBead => CreateBead(
        index,
        name,
        at,
        id: _creationId(record, at, AuthorityResourceKind.bead),
        type: _type(record, at),
        properties: _properties(record, at),
        attribution: attribution,
      ),
      OperationKind.createLink => CreateLink(
        index,
        name,
        at,
        id: _creationId(record, at, AuthorityResourceKind.link),
        type: _type(record, at),
        source: _endpoint(record, 'source', at),
        target: _endpoint(record, 'target', at),
        properties: _properties(record, at),
        attribution: attribution,
      ),
      OperationKind.updateBeadProperties ||
      OperationKind.updateLinkProperties => UpdateProperties(
        index,
        name,
        at,
        kind: kind,
        subject: _subject(record, at, kind.kind),
        change: _change(record, at),
        expectedRevision: _string(
          record,
          'expectedRevision',
          at,
          required: false,
        ),
        attribution: attribution,
      ),
      OperationKind.deleteBead || OperationKind.deleteLink => Delete(
        index,
        name,
        at,
        kind: kind,
        subject: _subject(record, at, kind.kind),
        expectedRevision: _string(
          record,
          'expectedRevision',
          at,
          required: false,
        ),
        attribution: attribution,
      ),
    };
    if (name != null) {
      final id = switch (operation) {
        CreateBead(:final id) || CreateLink(:final id) => id,
        _ => null,
      };
      _labels[name] = (
        operation,
        id == null ? LabelRef(index) : CanonicalRef(id),
      );
    }
    return operation;
  }

  String? _string(JsonMap r, String key, String at, {required bool required}) {
    final value = r[key];
    if (value == null && !required && !r.containsKey(key)) return null;
    if (value is! String || value.isEmpty) {
      throw _malformed('$key is a nonempty string', '$at/$key');
    }
    return value;
  }

  String _type(JsonMap r, String at) {
    final type = _string(r, 'type', at, required: true)!;
    final uri = Uri.tryParse(type);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw _malformed('type is an absolute Type URL', '$at/type');
    }
    return type;
  }

  JsonMap _properties(JsonMap r, String at) {
    if (!r.containsKey('properties')) return {};
    final p = r['properties'];
    if (p is! Map<String, Object?>) {
      throw _malformed('properties is an object', '$at/properties');
    }
    return p;
  }

  JsonMap? _attribution(JsonMap r, String at) {
    if (!r.containsKey('attribution')) return null;
    final a = r['attribution'];
    final ok =
        a is Map<String, Object?> &&
        a.length == 2 &&
        a['principal'] is String &&
        (a['principal']! as String).isNotEmpty &&
        (a['status'] == 'claimed' || a['status'] == 'unknown');
    if (!ok) throw _malformed('Invalid attribution', '$at/attribution');
    return a;
  }

  List<JsonMap> _change(JsonMap r, String at) {
    final change = r['change'];
    if (change is! List || change.isEmpty) {
      throw _malformed('change is a nonempty patch array', '$at/change');
    }
    for (var i = 0; i < change.length; i++) {
      final op = change[i];
      final here = '$at/change/$i';
      final ok =
          op is Map<String, Object?> &&
          switch (op['op']) {
            'add' || 'replace' =>
              op.length == 3 && op.containsKey('value') && op['path'] is String,
            'remove' => op.length == 2 && op['path'] is String,
            _ => false,
          };
      if (!ok) throw _malformed('Invalid patch operation', here);
      if (!isJsonPointer(op['path']! as String)) {
        throw _malformed('path is not a JSON Pointer', '$here/path');
      }
    }
    return change.cast<JsonMap>();
  }

  String? _creationId(JsonMap r, String at, AuthorityResourceKind kind) {
    final id = _string(r, 'id', at, required: false);
    if (id == null) return null;
    final spelling = scope.classify(id);
    if (id.startsWith('@') ||
        spelling is! InScopeSpelling ||
        spelling.kind != kind) {
      throw _malformed('id is a canonical ${kind.root} identity', '$at/id');
    }
    return spelling.url;
  }

  Ref _label(String spelling, String at, AuthorityResourceKind kind) {
    if (!batch) {
      throw _malformed('Singleton targets do not accept local references', at);
    }
    final entry = _labels[spelling.substring(1)];
    if (entry == null) {
      throw _malformed('Label referenced before its creating operation', at);
    }
    if (entry.$1.kind.kind != kind) {
      throw _malformed('Label names a Resource of the other kind', at);
    }
    return entry.$2;
  }

  Ref _subject(JsonMap r, String at, AuthorityResourceKind kind) {
    final key = kind.name;
    final value = _string(r, key, at, required: true)!;
    if (value.startsWith('@')) return _label(value, '$at/$key', kind);
    return switch (scope.classify(value)) {
      InvalidSpelling() => throw _malformed('Invalid reference', '$at/$key'),
      InScopeSpelling(:final url, kind: final k) when k == kind => CanonicalRef(
        url,
      ),
      _ => UnresolvableRef(value),
    };
  }

  Endpoint _endpoint(JsonMap r, String key, String at) {
    var value = r[key];
    String? pin;
    var here = '$at/$key';
    if (value is Map<String, Object?>) {
      final revision = value['revision'];
      if (value.length != 2 ||
          revision is! String ||
          revision.isEmpty ||
          value['uri'] is! String) {
        throw _malformed('Invalid Pinned Reference', here);
      }
      pin = revision;
      value = value['uri'];
      here = '$here/uri';
    }
    if (value is! String || value.isEmpty) {
      throw _malformed('$key is a reference', here);
    }
    if (value.startsWith('@')) {
      return LocalEndpoint(
        _label(value, here, AuthorityResourceKind.bead),
        pin,
      );
    }
    return switch (scope.classify(value)) {
      InvalidSpelling() => throw _malformed('Invalid reference', here),
      ExternalSpelling(:final uri) => ExternalEndpoint(uri, pin),
      InScopeSpelling(:final url, kind: AuthorityResourceKind.bead) =>
        LocalEndpoint(CanonicalRef(url), pin),
      InScopeSpelling() => MiscategorizedEndpoint(value, pin),
    };
  }
}
