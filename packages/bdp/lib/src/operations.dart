import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'json.dart';
import 'patch.dart';
import 'records.dart';
import 'tokens.dart';

/// A batch carried a set operation (`updateWhere`, `deleteWhere`), which
/// this client deliberately does not model.
final class UnsupportedOperation implements Exception {
  /// The unsupported operation discriminator at [path].
  const UnsupportedOperation(this.operation, this.path);

  /// The wire discriminator.
  final String operation;

  /// Where it appeared.
  final String path;

  @override
  String toString() =>
      'UnsupportedOperation: "$operation" at $path is outside this client';
}

/// One of the six single-Resource mutation records.
///
/// The same record is a singleton request body ([toRequestJson]) or one
/// member of a `batch` ([toBatchJson]). Only a batch member may carry a
/// [name] label or refer to an earlier label with `@name`.
@immutable
sealed class MutationOperation {
  const MutationOperation._();

  /// Decodes one batch operation record.
  ///
  /// Throws [UnsupportedOperation] for the set operations.
  factory MutationOperation.fromBatchJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    final operation = r.string('operation');
    return switch (operation) {
      'updateWhere' ||
      'deleteWhere' => throw UnsupportedOperation(operation, path),
      _ => MutationOperation.fromRequestJson(operation, json, path),
    };
  }

  /// Decodes a record for the operation named [operation] (its batch
  /// discriminator), ignoring the discriminator member itself.
  factory MutationOperation.fromRequestJson(
    String operation,
    Object? json, [
    String path = '',
  ]) {
    final r = JsonReader.of(json, path);
    return switch (operation) {
      CreateBead.operation => CreateBead(
        type: r.string('type'),
        id: r.optionalString('id'),
        properties: r.optionalObject('properties'),
        attribution: r.optionalDecode('attribution', Attribution.fromJson),
        name: r.optionalString('name'),
      ),
      UpdateBeadProperties.operation => UpdateBeadProperties(
        bead: r.string('bead'),
        change: r.decode('change', PropertyChange.fromJson),
        expectedRevision: r.optionalDecode(
          'expectedRevision',
          Revision.fromJson,
        ),
        attribution: r.optionalDecode('attribution', Attribution.fromJson),
      ),
      DeleteBead.operation => DeleteBead(
        bead: r.string('bead'),
        expectedRevision: r.optionalDecode(
          'expectedRevision',
          Revision.fromJson,
        ),
      ),
      CreateLink.operation => CreateLink(
        type: r.string('type'),
        source: r.decode('source', Reference.fromJson),
        target: r.decode('target', Reference.fromJson),
        id: r.optionalString('id'),
        properties: r.optionalObject('properties'),
        attribution: r.optionalDecode('attribution', Attribution.fromJson),
        name: r.optionalString('name'),
      ),
      UpdateLinkProperties.operation => UpdateLinkProperties(
        link: r.string('link'),
        change: r.decode('change', PropertyChange.fromJson),
        expectedRevision: r.optionalDecode(
          'expectedRevision',
          Revision.fromJson,
        ),
        attribution: r.optionalDecode('attribution', Attribution.fromJson),
      ),
      DeleteLink.operation => DeleteLink(
        link: r.string('link'),
        expectedRevision: r.optionalDecode(
          'expectedRevision',
          Revision.fromJson,
        ),
        attribution: r.optionalDecode('attribution', Attribution.fromJson),
      ),
      _ => throw UnsupportedOperation(operation, path),
    };
  }

  /// The batch discriminator, e.g. `createBead`.
  String get operationName;

  /// The Operation Directory member naming this operation's singleton
  /// target; the same spelling as [operationName].
  String get directoryName => operationName;

  /// The transaction-local label of a creation, when declared.
  String? get name => null;

  /// Every Resource reference this record carries, as written.
  Iterable<String> get references;

  /// The record members, without `operation` or `name`.
  JsonObject toRequestJson();

  /// The batch member: the record plus `operation` and, when declared,
  /// `name`.
  JsonObject toBatchJson() => {
    'name': ?name,
    'operation': operationName,
    ...toRequestJson(),
  };
}

/// Creates a Bead.
final class CreateBead extends MutationOperation {
  /// Creates a Bead of [type], with the supplied local [id] or an
  /// authority-allocated one.
  CreateBead({
    required this.type,
    this.id,
    JsonObject? properties,
    this.attribution,
    this.name,
  }) : properties = properties == null ? null : freezeObject(properties),
       super._();

  /// The batch discriminator.
  static const String operation = 'createBead';

  /// The declared Type ID.
  final String type;

  /// The creator-supplied identity, local or absolute.
  final String? id;

  /// The initial properties; omitted means the protocol default.
  final JsonObject? properties;

  /// The new version's carried attribution.
  final Attribution? attribution;

  @override
  final String? name;

  @override
  String get operationName => operation;

  @override
  Iterable<String> get references => const [];

  @override
  JsonObject toRequestJson() {
    final json = <String, Object?>{};
    putIfPresent(json, 'id', id);
    json['type'] = type;
    putIfPresent(json, 'properties', properties);
    putIfPresent(json, 'attribution', attribution?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is CreateBead &&
      other.type == type &&
      other.id == id &&
      other.attribution == attribution &&
      other.name == name &&
      jsonEquality.equals(other.properties, properties);

  @override
  int get hashCode =>
      Object.hash(type, id, attribution, name, jsonEquality.hash(properties));
}

/// Applies a Property Change to a Bead.
final class UpdateBeadProperties extends MutationOperation {
  /// Applies [change] to [bead], guarded by [expectedRevision] when given.
  const UpdateBeadProperties({
    required this.bead,
    required this.change,
    this.expectedRevision,
    this.attribution,
  }) : super._();

  /// The batch discriminator.
  static const String operation = 'updateBeadProperties';

  /// The Bead reference: local ID, absolute URL, or `@label` in a batch.
  final String bead;

  /// The patch.
  final PropertyChange change;

  /// The revision the Bead must still have.
  final Revision? expectedRevision;

  /// The new version's carried attribution.
  final Attribution? attribution;

  @override
  String get operationName => operation;

  @override
  Iterable<String> get references => [bead];

  @override
  JsonObject toRequestJson() {
    final json = <String, Object?>{'bead': bead};
    putIfPresent(json, 'expectedRevision', expectedRevision?.toJson());
    json['change'] = change.toJson();
    putIfPresent(json, 'attribution', attribution?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateBeadProperties &&
      other.bead == bead &&
      other.change == change &&
      other.expectedRevision == expectedRevision &&
      other.attribution == attribution;

  @override
  int get hashCode => Object.hash(bead, change, expectedRevision, attribution);
}

/// Deletes a Bead.
final class DeleteBead extends MutationOperation {
  /// Deletes [bead], guarded by [expectedRevision] when given.
  const DeleteBead({required this.bead, this.expectedRevision}) : super._();

  /// The batch discriminator.
  static const String operation = 'deleteBead';

  /// The Bead reference.
  final String bead;

  /// The revision the Bead must still have.
  final Revision? expectedRevision;

  @override
  String get operationName => operation;

  @override
  Iterable<String> get references => [bead];

  @override
  JsonObject toRequestJson() {
    final json = <String, Object?>{'bead': bead};
    putIfPresent(json, 'expectedRevision', expectedRevision?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is DeleteBead &&
      other.bead == bead &&
      other.expectedRevision == expectedRevision;

  @override
  int get hashCode => Object.hash(bead, expectedRevision);
}

/// Creates a Link.
final class CreateLink extends MutationOperation {
  /// Creates a Link of [type] from [source] to [target].
  CreateLink({
    required this.type,
    required this.source,
    required this.target,
    this.id,
    JsonObject? properties,
    this.attribution,
    this.name,
  }) : properties = properties == null ? null : freezeObject(properties),
       super._();

  /// The batch discriminator.
  static const String operation = 'createLink';

  /// The declared Link Type ID.
  final String type;

  /// The source endpoint as written.
  final Reference source;

  /// The target endpoint as written.
  final Reference target;

  /// The creator-supplied identity, local or absolute.
  final String? id;

  /// The initial properties; omitted means the protocol default.
  final JsonObject? properties;

  /// The new version's carried attribution.
  final Attribution? attribution;

  @override
  final String? name;

  @override
  String get operationName => operation;

  @override
  Iterable<String> get references => [source.uri, target.uri];

  @override
  JsonObject toRequestJson() {
    final json = <String, Object?>{};
    putIfPresent(json, 'id', id);
    json['type'] = type;
    json['source'] = source.toJson();
    json['target'] = target.toJson();
    putIfPresent(json, 'properties', properties);
    putIfPresent(json, 'attribution', attribution?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is CreateLink &&
      other.type == type &&
      other.source == source &&
      other.target == target &&
      other.id == id &&
      other.attribution == attribution &&
      other.name == name &&
      jsonEquality.equals(other.properties, properties);

  @override
  int get hashCode => Object.hash(
    type,
    source,
    target,
    id,
    attribution,
    name,
    jsonEquality.hash(properties),
  );
}

/// Applies a Property Change to a Link.
final class UpdateLinkProperties extends MutationOperation {
  /// Applies [change] to [link], guarded by [expectedRevision] when given.
  const UpdateLinkProperties({
    required this.link,
    required this.change,
    this.expectedRevision,
    this.attribution,
  }) : super._();

  /// The batch discriminator.
  static const String operation = 'updateLinkProperties';

  /// The Link reference.
  final String link;

  /// The patch.
  final PropertyChange change;

  /// The revision the Link must still have.
  final Revision? expectedRevision;

  /// The new version's carried attribution.
  final Attribution? attribution;

  @override
  String get operationName => operation;

  @override
  Iterable<String> get references => [link];

  @override
  JsonObject toRequestJson() {
    final json = <String, Object?>{'link': link};
    putIfPresent(json, 'expectedRevision', expectedRevision?.toJson());
    json['change'] = change.toJson();
    putIfPresent(json, 'attribution', attribution?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateLinkProperties &&
      other.link == link &&
      other.change == change &&
      other.expectedRevision == expectedRevision &&
      other.attribution == attribution;

  @override
  int get hashCode => Object.hash(link, change, expectedRevision, attribution);
}

/// Deletes a Link.
final class DeleteLink extends MutationOperation {
  /// Deletes [link], guarded by [expectedRevision] when given.
  const DeleteLink({
    required this.link,
    this.expectedRevision,
    this.attribution,
  }) : super._();

  /// The batch discriminator.
  static const String operation = 'deleteLink';

  /// The Link reference.
  final String link;

  /// The revision the Link must still have.
  final Revision? expectedRevision;

  /// The owning source's new version's carried attribution, for an owned
  /// Link.
  final Attribution? attribution;

  @override
  String get operationName => operation;

  @override
  Iterable<String> get references => [link];

  @override
  JsonObject toRequestJson() {
    final json = <String, Object?>{'link': link};
    putIfPresent(json, 'expectedRevision', expectedRevision?.toJson());
    putIfPresent(json, 'attribution', attribution?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is DeleteLink &&
      other.link == link &&
      other.expectedRevision == expectedRevision &&
      other.attribution == attribution;

  @override
  int get hashCode => Object.hash(link, expectedRevision, attribution);
}

/// A `batch` request body: one ordered, all-or-nothing operation list.
@immutable
final class BatchRequest {
  /// A batch of [operations], which must be nonempty.
  BatchRequest(List<MutationOperation> operations)
    : operations = List.unmodifiable(operations) {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', 'is empty');
    }
  }

  /// Decodes a batch request body.
  factory BatchRequest.fromJson(Object? json, [String path = '']) =>
      BatchRequest(
        JsonReader.of(
          json,
          path,
        ).list('operations', MutationOperation.fromBatchJson),
      );

  /// The operations, in declaration order.
  final List<MutationOperation> operations;

  /// The wire form.
  JsonObject toJson() => {
    'operations': [for (final operation in operations) operation.toBatchJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is BatchRequest &&
      const ListEquality<MutationOperation>().equals(
        other.operations,
        operations,
      );

  @override
  int get hashCode => const ListEquality<MutationOperation>().hash(operations);
}
