import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'json.dart';
import 'records.dart';

/// A Link Type's policy for out-of-Scope endpoints.
enum ExternalEndpointPolicy {
  /// Out-of-Scope endpoints are refused.
  none,

  /// Any opaque out-of-Scope URI is admitted.
  opaque,

  /// Out-of-Scope endpoints are admitted as Bead references.
  bead;

  /// Decodes a policy from its wire spelling.
  static ExternalEndpointPolicy fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (policy) => policy.name);

  /// The wire spelling.
  String toJson() => name;
}

/// A Link Type's constraint on one endpoint.
@immutable
final class EndpointConstraint {
  /// A constraint requiring conformance to every Type in [conformsTo].
  EndpointConstraint({required List<String> conformsTo, this.external})
    : conformsTo = List.unmodifiable(conformsTo);

  /// Decodes an endpoint constraint.
  factory EndpointConstraint.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return EndpointConstraint(
      conformsTo: reader.list('conformsTo', decodeString),
      external: reader.optionalDecode(
        'external',
        ExternalEndpointPolicy.fromJson,
      ),
    );
  }

  /// Type IDs an in-Scope endpoint must conform to.
  final List<String> conformsTo;

  /// The out-of-Scope endpoint policy, when declared.
  final ExternalEndpointPolicy? external;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{'conformsTo': conformsTo};
    putIfPresent(json, 'external', external?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is EndpointConstraint &&
      other.external == external &&
      const ListEquality<String>().equals(other.conformsTo, conformsTo);

  @override
  int get hashCode =>
      Object.hash(external, const ListEquality<String>().hash(conformsTo));
}

/// One `ownsOutgoing` entry: the largest owned set, and a display label for
/// an explicitly declared Link Type.
@immutable
final class OwnedLinkDeclaration {
  /// A declaration bounding the owned set at [max].
  const OwnedLinkDeclaration({required this.max, this.label});

  /// Decodes a declaration.
  factory OwnedLinkDeclaration.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return OwnedLinkDeclaration(
      max: reader.integer('max'),
      label: reader.optionalString('label'),
    );
  }

  /// The largest owned set the Type permits.
  final int max;

  /// Documentation for display; never appears in a Resource record.
  final String? label;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{};
    putIfPresent(json, 'label', label);
    json['max'] = max;
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is OwnedLinkDeclaration && other.max == max && other.label == label;

  @override
  int get hashCode => Object.hash(max, label);
}

/// A Type Descriptor: what a Bead or Link Type is and what it constrains.
@immutable
final class TypeDescriptor {
  /// A Type Descriptor.
  TypeDescriptor({
    required this.id,
    required this.name,
    required this.describes,
    required List<String> conformsTo,
    this.description,
    this.propertiesSchema,
    this.source,
    this.target,
    Map<String, OwnedLinkDeclaration>? ownsOutgoing,
  }) : conformsTo = List.unmodifiable(conformsTo),
       ownsOutgoing = ownsOutgoing == null
           ? null
           : Map.unmodifiable(ownsOutgoing);

  /// Decodes a Type Descriptor.
  factory TypeDescriptor.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return TypeDescriptor(
      id: reader.string('id'),
      name: reader.string('name'),
      description: reader.optionalString('description'),
      describes: reader.decode('describes', ResourceKind.fromJson),
      conformsTo: reader.list('conformsTo', decodeString),
      propertiesSchema: reader.optionalString('propertiesSchema'),
      source: reader.optionalDecode('source', EndpointConstraint.fromJson),
      target: reader.optionalDecode('target', EndpointConstraint.fromJson),
      ownsOutgoing: reader.optionalDecode('ownsOutgoing', (value, path) {
        final owned = JsonReader.of(value, path);
        return {
          for (final key in owned.keys)
            key: owned.decode(key, OwnedLinkDeclaration.fromJson),
        };
      }),
    );
  }

  /// The wildcard `ownsOutgoing` key.
  static const String wildcard = '*';

  /// The Type ID.
  final String id;

  /// The human name.
  final String name;

  /// Optional human description.
  final String? description;

  /// Whether this Type describes Beads or Links.
  final ResourceKind describes;

  /// Type IDs this Type conforms to.
  final List<String> conformsTo;

  /// The URL of the JSON Schema for `properties`, when published.
  final String? propertiesSchema;

  /// The source endpoint constraint of a Link Type.
  final EndpointConstraint? source;

  /// The target endpoint constraint of a Link Type.
  final EndpointConstraint? target;

  /// Owned outgoing Link Types, keyed by Link Type URL or [wildcard].
  final Map<String, OwnedLinkDeclaration>? ownsOutgoing;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{'id': id, 'name': name};
    putIfPresent(json, 'description', description);
    json['describes'] = describes.toJson();
    json['conformsTo'] = conformsTo;
    putIfPresent(json, 'propertiesSchema', propertiesSchema);
    putIfPresent(json, 'source', source?.toJson());
    putIfPresent(json, 'target', target?.toJson());
    putIfPresent(json, 'ownsOutgoing', switch (ownsOutgoing) {
      null => null,
      final owned => {
        for (final entry in owned.entries) entry.key: entry.value.toJson(),
      },
    });
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is TypeDescriptor &&
      other.id == id &&
      other.name == name &&
      other.description == description &&
      other.describes == describes &&
      other.propertiesSchema == propertiesSchema &&
      other.source == source &&
      other.target == target &&
      const ListEquality<String>().equals(other.conformsTo, conformsTo) &&
      const MapEquality<String, OwnedLinkDeclaration>().equals(
        other.ownsOutgoing,
        ownsOutgoing,
      );

  @override
  int get hashCode => Object.hash(
    id,
    name,
    description,
    describes,
    propertiesSchema,
    source,
    target,
    const ListEquality<String>().hash(conformsTo),
    const MapEquality<String, OwnedLinkDeclaration>().hash(ownsOutgoing),
  );
}

/// One entry of the `types/` inventory.
@immutable
final class TypeSummary {
  /// A summary of the Type [id].
  const TypeSummary({
    required this.id,
    required this.name,
    required this.describes,
  });

  /// Decodes a Type summary.
  factory TypeSummary.fromJson(Object? json, [String path = '']) {
    final reader = JsonReader.of(json, path);
    return TypeSummary(
      id: reader.string('id'),
      name: reader.string('name'),
      describes: reader.decode('describes', ResourceKind.fromJson),
    );
  }

  /// The Type ID.
  final String id;

  /// The human name.
  final String name;

  /// Whether the Type describes Beads or Links.
  final ResourceKind describes;

  /// The wire form.
  JsonObject toJson() => {
    'id': id,
    'name': name,
    'describes': describes.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is TypeSummary &&
      other.id == id &&
      other.name == name &&
      other.describes == describes;

  @override
  int get hashCode => Object.hash(id, name, describes);

  @override
  String toString() => 'TypeSummary($id)';
}
