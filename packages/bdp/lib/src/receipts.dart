import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'json.dart';
import 'problem.dart';
import 'records.dart';
import 'tokens.dart';

/// What a Read+Update singleton did.
enum MutationOutcome {
  /// A Resource was created.
  created,

  /// A Resource was updated, or the update was a no-op.
  updated,

  /// A Resource was deleted.
  deleted;

  /// Decodes an outcome.
  static MutationOutcome fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (outcome) => outcome.name);

  /// The wire spelling.
  String toJson() => name;
}

/// A Read+Update singleton's inline result: the postimage, or the deleted
/// identity.
@immutable
final class MutationResult {
  /// A result.
  const MutationResult({
    required this.outcome,
    this.resource,
    this.deleted,
    this.source,
    this.sourceRevision,
  });

  /// Decodes a mutation result.
  factory MutationResult.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return MutationResult(
      outcome: r.decode('outcome', MutationOutcome.fromJson),
      resource: r.optionalDecode('resource', ResourceRecord.fromJson),
      deleted: r.optionalDecode('deleted', DeletedIdentity.fromJson),
      source: r.optionalString('source'),
      sourceRevision: r.optionalDecode('sourceRevision', Revision.fromJson),
    );
  }

  /// What happened.
  final MutationOutcome outcome;

  /// The complete postimage of a creation or update.
  final ResourceRecord? resource;

  /// The canonical identity of a deletion.
  final DeletedIdentity? deleted;

  /// The owning source Bead an owned-Link mutation versioned.
  final String? source;

  /// The owning source's revision after the mutation.
  final Revision? sourceRevision;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{'outcome': outcome.toJson()};
    putIfPresent(json, 'resource', resource?.toJson());
    putIfPresent(json, 'deleted', deleted?.toJson());
    putIfPresent(json, 'source', source);
    putIfPresent(json, 'sourceRevision', sourceRevision?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is MutationResult &&
      other.outcome == outcome &&
      other.resource == resource &&
      other.deleted == deleted &&
      other.source == source &&
      other.sourceRevision == sourceRevision;

  @override
  int get hashCode =>
      Object.hash(outcome, resource, deleted, source, sourceRevision);
}

/// A Mutation Receipt's terminal or pending disposition.
enum ReceiptStatus {
  /// The transaction is still executing.
  pending,

  /// The transaction committed.
  completed,

  /// The transaction failed whole and committed nothing.
  failed;

  /// Decodes a status.
  static ReceiptStatus fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (status) => status.name);

  /// The wire spelling.
  String toJson() => name;
}

/// Whether a receipt's detailed results are disclosed.
enum ReceiptDetail {
  /// Results are present.
  available,

  /// The detail aged out; only allocated identities remain.
  expired,

  /// The current view may not see the detail.
  withheld;

  /// Decodes a detail state.
  static ReceiptDetail fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (detail) => detail.name);

  /// The wire spelling.
  String toJson() => name;
}

/// What one receipt result entry reports.
enum ReceiptOutcome {
  /// A Resource was created.
  created,

  /// A Resource was updated.
  updated,

  /// A Resource was deleted.
  deleted,

  /// A set operation's matched count.
  matched,

  /// The current view withholds the entry.
  withheld,

  /// The version the entry reported was erased.
  erased;

  /// Decodes an outcome.
  static ReceiptOutcome fromJson(Object? json, [String path = '']) =>
      decodeEnum(json, path, values, (outcome) => outcome.name);

  /// The wire spelling.
  String toJson() => name;
}

/// One result entry of a Mutation Receipt or receipt page.
@immutable
final class ReceiptResult {
  /// A result entry for the operation at [operationIndex].
  const ReceiptResult({
    required this.operationIndex,
    required this.outcome,
    this.operationName,
    this.resource,
    this.deleted,
    this.erased,
    this.source,
    this.sourceRevision,
    this.count,
    this.alias,
    this.target,
  });

  /// Decodes a result entry.
  factory ReceiptResult.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return ReceiptResult(
      operationIndex: r.integer('operationIndex'),
      operationName: r.optionalString('operationName'),
      outcome: r.decode('outcome', ReceiptOutcome.fromJson),
      resource: r.optionalDecode('resource', ResourceRecord.fromJson),
      deleted: r.optionalDecode('deleted', DeletedIdentity.fromJson),
      erased: r.optionalDecode('erased', ResourceIdentity.fromJson),
      source: r.optionalString('source'),
      sourceRevision: r.optionalDecode('sourceRevision', Revision.fromJson),
      count: r.optionalInteger('count'),
      alias: r.optionalString('alias'),
      target: r.optionalString('target'),
    );
  }

  /// The zero-based index of the operation in its request.
  final int operationIndex;

  /// The operation's label, when it declared one.
  final String? operationName;

  /// What this entry reports.
  final ReceiptOutcome outcome;

  /// The complete postimage of a creation or update.
  final ResourceRecord? resource;

  /// The canonical identity of a deletion.
  final DeletedIdentity? deleted;

  /// The identity of an erased version.
  final ResourceIdentity? erased;

  /// The owning source an owned-Link mutation versioned.
  final String? source;

  /// The owning source's revision after the mutation.
  final Revision? sourceRevision;

  /// A set operation's matched count.
  final int? count;

  /// The absolute alias URL of an alias mutation.
  final String? alias;

  /// The canonical target of an alias put.
  final String? target;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{'operationIndex': operationIndex};
    putIfPresent(json, 'operationName', operationName);
    json['outcome'] = outcome.toJson();
    putIfPresent(json, 'resource', resource?.toJson());
    putIfPresent(json, 'deleted', deleted?.toJson());
    putIfPresent(json, 'erased', erased?.toJson());
    putIfPresent(json, 'source', source);
    putIfPresent(json, 'sourceRevision', sourceRevision?.toJson());
    putIfPresent(json, 'count', count);
    putIfPresent(json, 'alias', alias);
    putIfPresent(json, 'target', target);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is ReceiptResult &&
      other.operationIndex == operationIndex &&
      other.operationName == operationName &&
      other.outcome == outcome &&
      other.resource == resource &&
      other.deleted == deleted &&
      other.erased == erased &&
      other.source == source &&
      other.sourceRevision == sourceRevision &&
      other.count == count &&
      other.alias == alias &&
      other.target == target;

  @override
  int get hashCode => Object.hash(
    operationIndex,
    operationName,
    outcome,
    resource,
    deleted,
    erased,
    source,
    sourceRevision,
    count,
    alias,
    target,
  );
}

/// An identity a completed transaction allocated, retained after its detail
/// expired.
@immutable
final class AllocatedIdentity {
  /// A disclosed allocation.
  const AllocatedIdentity({
    required this.operationIndex,
    required String this.id,
    required String this.type,
    this.operationName,
  }) : withheld = false;

  /// An allocation the current view may not see.
  const AllocatedIdentity.withheld({
    required this.operationIndex,
    this.operationName,
  }) : id = null,
       type = null,
       withheld = true;

  /// Decodes an allocated identity.
  factory AllocatedIdentity.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    final index = r.integer('operationIndex');
    final name = r.optionalString('operationName');
    if (r.optionalBoolean('withheld') ?? false) {
      return AllocatedIdentity.withheld(
        operationIndex: index,
        operationName: name,
      );
    }
    return AllocatedIdentity(
      operationIndex: index,
      operationName: name,
      id: r.string('id'),
      type: r.string('type'),
    );
  }

  /// The allocating operation's index.
  final int operationIndex;

  /// The allocating operation's label.
  final String? operationName;

  /// The allocated canonical URL, unless withheld.
  final String? id;

  /// The allocated Resource's Type, unless withheld.
  final String? type;

  /// Whether the identity is withheld from the current view.
  final bool withheld;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{'operationIndex': operationIndex};
    putIfPresent(json, 'operationName', operationName);
    if (withheld) {
      json['withheld'] = true;
    } else {
      json['id'] = id;
      json['type'] = type;
    }
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is AllocatedIdentity &&
      other.operationIndex == operationIndex &&
      other.operationName == operationName &&
      other.id == id &&
      other.type == type &&
      other.withheld == withheld;

  @override
  int get hashCode =>
      Object.hash(operationIndex, operationName, id, type, withheld);
}

/// A durable Mutation Receipt: the one record of an admitted Transactional
/// mutation's disposition.
@immutable
final class MutationReceipt {
  /// A receipt.
  MutationReceipt({
    required this.id,
    required this.status,
    required this.idempotencyKey,
    required this.scopeEpoch,
    required this.authorizationView,
    required this.transaction,
    this.detail,
    this.requiredPosition,
    this.effectPosition,
    List<ReceiptResult>? results,
    this.next,
    List<AllocatedIdentity>? allocated,
    this.problem,
    this.expiresAt,
  }) : results = results == null ? null : List.unmodifiable(results),
       allocated = allocated == null ? null : List.unmodifiable(allocated);

  /// Decodes a receipt.
  factory MutationReceipt.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    final results = r.optionalList('results', ReceiptResult.fromJson);
    if (results != null && !r.has('next')) {
      throw FormatException('${r.at('next')}: required beside results');
    }
    return MutationReceipt(
      id: r.string('id'),
      status: r.decode('status', ReceiptStatus.fromJson),
      detail: r.optionalDecode('detail', ReceiptDetail.fromJson),
      idempotencyKey: r.decode('idempotencyKey', IdempotencyKey.fromJson),
      scopeEpoch: r.decode('scopeEpoch', ScopeEpoch.fromJson),
      authorizationView: r.decode(
        'authorizationView',
        AuthorizationView.fromJson,
      ),
      transaction: r.decode('transaction', TransactionId.fromJson),
      requiredPosition: r.optionalDecode(
        'requiredPosition',
        ScopePosition.fromJson,
      ),
      effectPosition: r.optionalDecode(
        'effectPosition',
        ScopePosition.fromJson,
      ),
      results: results,
      next: r.optionalString('next'),
      allocated: r.optionalList('allocated', AllocatedIdentity.fromJson),
      problem: r.optionalDecode('problem', ProblemDetails.fromJson),
      expiresAt: r.optionalString('expiresAt'),
    );
  }

  /// The receipt URL.
  final String id;

  /// The disposition.
  final ReceiptStatus status;

  /// Whether detailed results are disclosed; absent while pending.
  final ReceiptDetail? detail;

  /// The key the mutation was submitted under.
  final IdempotencyKey idempotencyKey;

  /// The epoch the key's namespace belongs to.
  final ScopeEpoch scopeEpoch;

  /// The view the mutation executed in.
  final AuthorizationView authorizationView;

  /// The transaction identity.
  final TransactionId transaction;

  /// The position the view must observe before relying on the outcome.
  final ScopePosition? requiredPosition;

  /// The position of the change group the mutation produced, if any.
  final ScopePosition? effectPosition;

  /// The result entries, when the detail is available.
  final List<ReceiptResult>? results;

  /// The next result page, beside [results]; `null` when inline.
  final String? next;

  /// Identities a completed transaction allocated, after expiry.
  final List<AllocatedIdentity>? allocated;

  /// The failure of a `failed` receipt.
  final ProblemDetails? problem;

  /// When the detail or failed receipt may be forgotten, as served.
  final String? expiresAt;

  /// Whether the transaction committed.
  bool get isCompleted => status == ReceiptStatus.completed;

  /// Whether the transaction is still executing.
  bool get isPending => status == ReceiptStatus.pending;

  /// The wire form.
  JsonObject toJson() {
    final json = <String, Object?>{'id': id, 'status': status.toJson()};
    putIfPresent(json, 'detail', detail?.toJson());
    json['idempotencyKey'] = idempotencyKey.toJson();
    json['scopeEpoch'] = scopeEpoch.toJson();
    json['authorizationView'] = authorizationView.toJson();
    json['transaction'] = transaction.toJson();
    putIfPresent(json, 'requiredPosition', requiredPosition?.toJson());
    putIfPresent(json, 'effectPosition', effectPosition?.toJson());
    if (results case final results?) {
      json['results'] = [for (final result in results) result.toJson()];
      json['next'] = next;
    }
    putIfPresent(json, 'allocated', switch (allocated) {
      null => null,
      final allocated => [for (final entry in allocated) entry.toJson()],
    });
    putIfPresent(json, 'problem', problem?.toJson());
    putIfPresent(json, 'expiresAt', expiresAt);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      other is MutationReceipt && jsonEquality.equals(other.toJson(), toJson());

  @override
  int get hashCode => jsonEquality.hash(toJson());

  @override
  String toString() => 'MutationReceipt($id ${status.name})';
}

/// A continuation page of a receipt's results.
@immutable
final class MutationReceiptPage {
  /// A page of [results] of the receipt [receipt].
  MutationReceiptPage({
    required this.receipt,
    required List<ReceiptResult> results,
    required this.next,
  }) : results = List.unmodifiable(results);

  /// Decodes a receipt page.
  factory MutationReceiptPage.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    if (!r.has('next')) {
      throw FormatException('${r.at('next')}: required member is missing');
    }
    return MutationReceiptPage(
      receipt: r.string('receipt'),
      results: r.list('results', ReceiptResult.fromJson),
      next: r.optionalString('next'),
    );
  }

  /// The receipt URL.
  final String receipt;

  /// The result entries.
  final List<ReceiptResult> results;

  /// The next page, or `null`.
  final String? next;

  /// The wire form.
  JsonObject toJson() => {
    'receipt': receipt,
    'results': [for (final result in results) result.toJson()],
    'next': next,
  };

  @override
  bool operator ==(Object other) =>
      other is MutationReceiptPage &&
      other.receipt == receipt &&
      other.next == next &&
      const ListEquality<ReceiptResult>().equals(other.results, results);

  @override
  int get hashCode => Object.hash(
    receipt,
    next,
    const ListEquality<ReceiptResult>().hash(results),
  );
}

/// What a singleton mutation answered, which depends on the Scope's
/// profile.
@immutable
sealed class MutationResponse {
  const MutationResponse._();
}

/// A Transactional Scope's answer: the Mutation Receipt, pending when the
/// transaction had not finished within the authority's wait bound.
final class ReceiptResponse extends MutationResponse {
  /// Wraps [receipt].
  const ReceiptResponse(this.receipt) : super._();

  /// The receipt.
  final MutationReceipt receipt;

  @override
  bool operator ==(Object other) =>
      other is ReceiptResponse && other.receipt == receipt;

  @override
  int get hashCode => receipt.hashCode;
}

/// A Read+Update Scope's answer: the inline mutation result.
final class ResultResponse extends MutationResponse {
  /// Wraps [result].
  const ResultResponse(this.result) : super._();

  /// The result.
  final MutationResult result;

  @override
  bool operator ==(Object other) =>
      other is ResultResponse && other.result == result;

  @override
  int get hashCode => result.hashCode;
}
