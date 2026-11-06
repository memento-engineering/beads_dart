import 'dart:async';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;

import '../changefeed.dart';
import '../discovery.dart';
import '../local_scope.dart';
import '../operations.dart';
import '../problem.dart';
import '../receipts.dart';
import '../records.dart';
import '../snapshot.dart';
import '../tokens.dart';
import '../types.dart';
import 'authority.dart';
import 'authority_scope.dart';
import 'identity.dart';
import 'json_text.dart';
import 'operations.dart' show OperationKind;
import 'problem.dart';

/// The authority's Scope as a [LocalScope]: the same operations a
/// `ScopeClient` performs over HTTP, answered in process.
///
/// Each answer is the wire document the HTTP handler would serve, decoded
/// with the client's codecs, so the in-process and HTTP paths share one set
/// of shapes. A refusal is the [BdpProblemException] the client would raise
/// for the same problem document, and a document the client cannot decode
/// is a [BdpProtocolException].
mixin AuthorityLocalScope implements LocalScope, AuthorityScope {
  @override
  ScopeDiscovery get discovery => _decodeNow(
    address.discovery,
    () => ScopeDiscovery.fromJson(discoveryDocument().body),
  );

  @override
  Future<BeadRecord> readBead(String bead) async =>
      switch (await _record(bead)) {
        final BeadRecord record => record,
        LinkRecord() => throw _problem(bead, _notFound()),
      };

  @override
  Future<LinkRecord> readLink(String link) async =>
      switch (await _record(link)) {
        final LinkRecord record => record,
        BeadRecord() => throw _problem(link, _notFound()),
      };

  Future<ResourceRecord> _record(String reference) async => _decode(
    reference,
    () => ResourceRecord.fromJson(resource(reference).body),
  );

  @override
  Future<Page<BeadRecord>> beads([BeadQuery query = const BeadQuery()]) async {
    _refuseSelector(address.beads, query.selector);
    return _decode(
      address.beads,
      () => _beadPage(
        collection(
          AuthorityResourceKind.bead,
          type: query.type,
          conformsTo: query.conformsTo,
          limit: query.limit,
        ),
      ),
    );
  }

  @override
  Future<Page<LinkRecord>> links([LinkQuery query = const LinkQuery()]) async {
    _refuseSelector(address.links, query.selector);
    return _decode(
      address.links,
      () => _linkPage(
        collection(
          AuthorityResourceKind.link,
          type: query.type,
          conformsTo: query.conformsTo,
          source: query.source,
          target: query.target,
          endpoint: query.endpoint,
          limit: query.limit,
        ),
      ),
    );
  }

  @override
  Future<Page<LinkRecord>> incidentLinks(
    String bead, {
    LinkDirection direction = LinkDirection.both,
    int? limit,
  }) async => _decode(
    bead,
    () => _linkPage(
      incidentLinkPage(bead, direction: direction.name, limit: limit),
    ),
  );

  @override
  Future<Page<BeadRecord>> nextBeads(String next) async => _decode(next, () {
    final uri = Uri.parse(next);
    if (_base(uri) != address.beads) throw _invalidContinuation();
    final p = uri.queryParameters;
    return _beadPage(
      collection(
        AuthorityResourceKind.bead,
        type: p['type'],
        conformsTo: p['conformsTo'],
        limit: _limit(p),
        cursor: p['cursor'],
      ),
    );
  });

  @override
  Future<Page<LinkRecord>> nextLinks(String next) async => _decode(next, () {
    final uri = Uri.parse(next);
    final base = _base(uri);
    final p = uri.queryParameters;
    if (base == address.links) {
      return _linkPage(
        collection(
          AuthorityResourceKind.link,
          type: p['type'],
          conformsTo: p['conformsTo'],
          source: p['source'],
          target: p['target'],
          endpoint: p['endpoint'],
          limit: _limit(p),
          cursor: p['cursor'],
        ),
      );
    }
    if (p['view'] != 'links') throw _invalidContinuation();
    return _linkPage(
      incidentLinkPage(
        base,
        direction: p['direction'] ?? 'both',
        limit: _limit(p),
        cursor: p['cursor'],
      ),
    );
  });

  @override
  Future<Page<TypeSummary>> types({int? limit}) async =>
      _decode(address.types, () => _typePage(typeInventory(limit: limit)));

  @override
  Future<Page<TypeSummary>> nextTypes(String next) async => _decode(next, () {
    final uri = Uri.parse(next);
    if (_base(uri) != address.types) throw _invalidContinuation();
    final p = uri.queryParameters;
    return _typePage(typeInventory(limit: _limit(p), cursor: p['cursor']));
  });

  /// The descriptor of an installed Type. The HTTP handler serves no
  /// descriptor documents: a Type ID is a URL the Type's publisher hosts,
  /// so over HTTP a client dereferences it there.
  @override
  Future<TypeDescriptor> readTypeDescriptor(String type) async =>
      _decode(type, () => TypeDescriptor.fromJson(typeDescriptor(type).body));

  // Mutations.

  @override
  @effect
  Future<MutationResponse> createBead(
    CreateBead operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(OperationKind.createBead, operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> updateBeadProperties(
    UpdateBeadProperties operation, {
    required IdempotencyKey idempotencyKey,
  }) =>
      _singleton(OperationKind.updateBeadProperties, operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> deleteBead(
    DeleteBead operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(OperationKind.deleteBead, operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> createLink(
    CreateLink operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(OperationKind.createLink, operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> updateLinkProperties(
    UpdateLinkProperties operation, {
    required IdempotencyKey idempotencyKey,
  }) =>
      _singleton(OperationKind.updateLinkProperties, operation, idempotencyKey);

  @override
  @effect
  Future<MutationResponse> deleteLink(
    DeleteLink operation, {
    required IdempotencyKey idempotencyKey,
  }) => _singleton(OperationKind.deleteLink, operation, idempotencyKey);

  @effect
  Future<MutationResponse> _singleton(
    OperationKind kind,
    MutationOperation operation,
    IdempotencyKey key,
  ) async => ReceiptResponse(
    await _submit(kind.target, operation.toRequestJson(), key),
  );

  @override
  @effect
  Future<MutationReceipt> batch(
    List<MutationOperation> operations, {
    required IdempotencyKey idempotencyKey,
  }) => _submit('batch', {
    'operations': [for (final operation in operations) operation.toBatchJson()],
  }, idempotencyKey);

  @effect
  Future<MutationReceipt> _submit(
    String target,
    JsonMap body,
    IdempotencyKey key,
  ) async {
    final url = '${address.operations}$target';
    final AuthorityReceipt receipt;
    try {
      receipt = await mutate(target, body, idempotencyKey: key.value);
    } on AuthorityProblem catch (problem) {
      throw _problem(url, problem);
    }
    return _decode(url, () => MutationReceipt.fromJson(receipt.json));
  }

  @override
  Future<MutationReceipt> readReceipt(String receipt) async =>
      _decode(receipt, () {
        if (!receipt.startsWith(address.receipts)) throw _notFound();
        final token = receipt.substring(address.receipts.length);
        return MutationReceipt.fromJson(this.receipt(token).body);
      });

  @override
  Future<MutationReceiptPage> readReceiptPage(String next) async =>
      // Results always fit a receipt inline, so no receipt has a next page.
      throw _problem(next, _notFound());

  // Replication.

  @override
  Future<ChangefeedPage> changes(ChangefeedStart start) async => _decode(
    address.changes,
    () => ChangefeedPage.fromJson(switch (start) {
      AfterCheckpoint(:final checkpoint) => changePage(
        after: checkpoint.value,
      ).body,
      StartNow() => changePage(startNow: true).body,
    }),
  );

  @override
  Future<ChangefeedPage> nextChanges(String next) async => _decode(next, () {
    final uri = Uri.parse(next);
    final after = uri.queryParameters['after'];
    if (_base(uri) != address.changes || after == null) {
      throw _invalidContinuation();
    }
    return ChangefeedPage.fromJson(changePage(after: after).body);
  });

  @override
  @effect
  ChangefeedSubscription follow(
    ChangefeedStart start,
    ChangeGroupApplier apply,
  ) {
    final String after;
    try {
      after = switch (start) {
        AfterCheckpoint(:final checkpoint) => checkpoint.value,
        StartNow() => changePage(startNow: true).body['after']! as String,
      };
    } on AuthorityProblem catch (problem) {
      return _FailedFollow(_problem(address.changes, problem));
    }
    return _AuthorityFollow(
      watch(after: after),
      apply,
      failGroup: (problem) => _problem(address.changes, problem),
      malformedGroup: (error) => _malformed(address.changes, error),
    );
  }

  @override
  @effect
  Future<SnapshotManifest> snapshot() async => _decode(
    address.snapshot,
    () => SnapshotManifest.fromJson(snapshotDocument().body),
  );

  // Decoding and refusals.

  /// Runs [read], turning the authority's direct problem into the
  /// exception the client raises for it, and a document the client codecs
  /// refuse into a protocol violation.
  T _decodeNow<T>(String target, T Function() read) {
    try {
      return read();
    } on AuthorityProblem catch (problem) {
      throw _problem(target, problem);
    } on FormatException catch (error) {
      throw _malformed(target, error);
    }
  }

  Future<T> _decode<T>(String target, T Function() read) async =>
      _decodeNow(target, read);

  void _refuseSelector(String target, Selector? selector) {
    if (selector != null) {
      throw _problem(
        target,
        AuthorityProblem(
          'invalid-parameter',
          title: 'Unsupported parameter selector',
        ),
      );
    }
  }

  static Page<BeadRecord> _beadPage(AuthorityRead read) =>
      Page.fromJson(read.body, '', BeadRecord.fromJson);

  static Page<LinkRecord> _linkPage(AuthorityRead read) =>
      Page.fromJson(read.body, '', LinkRecord.fromJson);

  static Page<TypeSummary> _typePage(AuthorityRead read) =>
      Page.fromJson(read.body, '', TypeSummary.fromJson);

  /// [uri] without its query: the collection or Resource it continues.
  static String _base(Uri uri) =>
      uri.replace(query: '').toString().replaceAll(RegExp(r'\?$'), '');

  static int? _limit(Map<String, String> parameters) =>
      switch (parameters['limit']) {
        null => null,
        final text => int.tryParse(text) ?? (throw _invalidContinuation()),
      };

  static AuthorityProblem _notFound() =>
      AuthorityProblem('resource-not-found', title: 'No such Resource');

  static AuthorityProblem _invalidContinuation() =>
      AuthorityProblem('invalid-parameter', title: 'Invalid continuation');
}

/// The exception the client raises for [problem] answered at [target].
BdpProblemException _problem(String target, AuthorityProblem problem) =>
    BdpProblemException(
      uri: Uri.parse(target),
      status: problem.status,
      problem: ProblemDetails.fromJson(problem.toJson()),
      retryAfter: problem.retry == 'after-delay'
          ? const Duration(seconds: 1)
          : null,
    );

BdpProtocolException _malformed(String target, Object error) =>
    BdpProtocolException(
      uri: Uri.parse(target),
      message: 'the authority served a document the client cannot decode',
      cause: error,
    );

/// A live changefeed over the authority's own commits: every group after
/// the start checkpoint, decoded and applied one at a time, in order.
final class _AuthorityFollow implements ChangefeedSubscription {
  _AuthorityFollow(
    Stream<JsonMap> groups,
    this._apply, {
    required this._failGroup,
    required this._malformedGroup,
  }) : _groups = StreamIterator(groups) {
    _done = _run();
  }

  final StreamIterator<JsonMap> _groups;
  final ChangeGroupApplier _apply;
  final BdpProblemException Function(AuthorityProblem) _failGroup;
  final BdpProtocolException Function(Object) _malformedGroup;
  late final Future<void> _done;
  bool _cancelled = false;

  Future<void> _run() async {
    try {
      while (await _groups.moveNext()) {
        if (_cancelled) return;
        final ChangeGroup group;
        try {
          group = ChangeGroup.fromJson(_groups.current);
        } on FormatException catch (error) {
          throw _malformedGroup(error);
        }
        await _apply(group);
        if (_cancelled) return;
      }
    } on AuthorityProblem catch (problem) {
      if (!_cancelled) throw _failGroup(problem);
    } finally {
      await _groups.cancel();
    }
  }

  @override
  Future<void> get done => _done;

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await _groups.cancel();
    try {
      await _done;
    } on Object {
      // A failure that raced the cancellation is not reported to the
      // canceller; [done] still carries it.
    }
  }
}

/// A follow that could not start, ending with [error] at once.
final class _FailedFollow implements ChangefeedSubscription {
  _FailedFollow(Object error) : done = Future.error(error);

  @override
  final Future<void> done;

  @override
  Future<void> cancel() async {}
}
