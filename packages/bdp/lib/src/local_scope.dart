import 'package:genesis_foundation/genesis_foundation.dart' show effect;
import 'package:meta/meta.dart';

import 'changefeed.dart';
import 'discovery.dart';
import 'operations.dart';
import 'receipts.dart';
import 'records.dart';
import 'replica.dart';
import 'snapshot.dart';
import 'tokens.dart';
import 'types.dart';

/// A bounded RFC 9535 JSONPath filter over one collection's candidates, as
/// the authority evaluates it. The client sends it verbatim.
@immutable
final class Selector {
  /// A selector expression, which must be nonempty.
  Selector(this.expression) {
    if (expression.isEmpty) {
      throw ArgumentError.value(expression, 'expression', 'is empty');
    }
  }

  /// The JSONPath expression, e.g. `$[?@.properties.status == "open"]`.
  final String expression;

  @override
  bool operator ==(Object other) =>
      other is Selector && other.expression == expression;

  @override
  int get hashCode => expression.hashCode;

  @override
  String toString() => expression;
}

/// The structural predicates of a `beads/` collection read, combined with
/// logical AND.
@immutable
final class BeadQuery {
  /// A query; every predicate is optional.
  const BeadQuery({this.type, this.conformsTo, this.selector, this.limit});

  /// Exact Type ID.
  final String? type;

  /// Effective conformance to this Type ID.
  final String? conformsTo;

  /// A bounded Selector over each candidate.
  final Selector? selector;

  /// The most records in the first page.
  final int? limit;

  /// The query parameters, in a stable order.
  Map<String, String> get queryParameters => {
    'type': ?type,
    'conformsTo': ?conformsTo,
    'selector': ?selector?.expression,
    'limit': ?limit?.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is BeadQuery &&
      other.type == type &&
      other.conformsTo == conformsTo &&
      other.selector == selector &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(type, conformsTo, selector, limit);
}

/// The structural predicates of a `links/` collection read, combined with
/// logical AND; `endpoint` matches either end.
@immutable
final class LinkQuery {
  /// A query; every predicate is optional.
  const LinkQuery({
    this.type,
    this.conformsTo,
    this.source,
    this.target,
    this.endpoint,
    this.selector,
    this.limit,
  });

  /// Exact Type ID.
  final String? type;

  /// Effective conformance to this Type ID.
  final String? conformsTo;

  /// Exact source reference URI, local or absolute.
  final String? source;

  /// Exact target reference URI, local or absolute.
  final String? target;

  /// Source or target reference URI.
  final String? endpoint;

  /// A bounded Selector over each candidate.
  final Selector? selector;

  /// The most records in the first page.
  final int? limit;

  /// The query parameters, in a stable order.
  Map<String, String> get queryParameters => {
    'type': ?type,
    'conformsTo': ?conformsTo,
    'source': ?source,
    'target': ?target,
    'endpoint': ?endpoint,
    'selector': ?selector?.expression,
    'limit': ?limit?.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is LinkQuery &&
      other.type == type &&
      other.conformsTo == conformsTo &&
      other.source == source &&
      other.target == target &&
      other.endpoint == endpoint &&
      other.selector == selector &&
      other.limit == limit;

  @override
  int get hashCode =>
      Object.hash(type, conformsTo, source, target, endpoint, selector, limit);
}

/// Which incident Links a Bead's Link view selects.
enum LinkDirection {
  /// Links whose target is the Bead.
  inbound,

  /// Links whose source is the Bead.
  outbound,

  /// Both.
  both,
}

/// Applies one change group durably. The follower treats completion as
/// durable application and advances its reconnect checkpoint only then.
typedef ChangeGroupApplier = Future<void> Function(ChangeGroup group);

/// A live changefeed observation started by [LocalScope.follow].
abstract interface class ChangefeedSubscription {
  /// Completes when the subscription is cancelled; completes with an error
  /// when it ends on a failure it cannot recover from — a problem response
  /// such as `cursor-expired`, a protocol violation, or a failed apply.
  Future<void> get done;

  /// Stops observing. No group is applied after this returns.
  ///
  /// It ends the observation [LocalScope.follow] started, so it is an
  /// `@effect`, as `follow` is: the owner of the follow cancels it.
  @effect
  Future<void> cancel();
}

/// The operations of one BDP Scope as the kernel consumes them, whether the
/// authority answers over HTTP or in process.
///
/// Reads that miss throw the authority's `resource-not-found` problem;
/// collection reads return pages and never report absence by an empty page.
abstract interface class LocalScope {
  /// The Scope's discovery document.
  ScopeDiscovery get discovery;

  /// Reads one Bead by local ID or canonical URL.
  Future<BeadRecord> readBead(String bead);

  /// Reads one Link by local ID or canonical URL.
  Future<LinkRecord> readLink(String link);

  /// Reads the first page of the Bead collection matching [query].
  Future<Page<BeadRecord>> beads([BeadQuery query = const BeadQuery()]);

  /// Reads the first page of the Link collection matching [query].
  Future<Page<LinkRecord>> links([LinkQuery query = const LinkQuery()]);

  /// Reads the first page of the Links incident upon [bead].
  Future<Page<LinkRecord>> incidentLinks(
    String bead, {
    LinkDirection direction = LinkDirection.both,
    int? limit,
  });

  /// Follows a Bead page continuation, including a snapshot's Bead stream.
  Future<Page<BeadRecord>> nextBeads(String next);

  /// Follows a Link page continuation, including a snapshot's Link stream
  /// and an incident-Link view.
  Future<Page<LinkRecord>> nextLinks(String next);

  /// Reads the first page of the Type inventory.
  Future<Page<TypeSummary>> types({int? limit});

  /// Follows a Type inventory continuation.
  Future<Page<TypeSummary>> nextTypes(String next);

  /// Reads the Type Descriptor at its Type ID.
  Future<TypeDescriptor> readTypeDescriptor(String type);

  /// Creates a Bead.
  @effect
  Future<MutationResponse> createBead(
    CreateBead operation, {
    required IdempotencyKey idempotencyKey,
  });

  /// Updates a Bead's properties.
  @effect
  Future<MutationResponse> updateBeadProperties(
    UpdateBeadProperties operation, {
    required IdempotencyKey idempotencyKey,
  });

  /// Deletes a Bead.
  @effect
  Future<MutationResponse> deleteBead(
    DeleteBead operation, {
    required IdempotencyKey idempotencyKey,
  });

  /// Creates a Link.
  @effect
  Future<MutationResponse> createLink(
    CreateLink operation, {
    required IdempotencyKey idempotencyKey,
  });

  /// Updates a Link's properties.
  @effect
  Future<MutationResponse> updateLinkProperties(
    UpdateLinkProperties operation, {
    required IdempotencyKey idempotencyKey,
  });

  /// Deletes a Link.
  @effect
  Future<MutationResponse> deleteLink(
    DeleteLink operation, {
    required IdempotencyKey idempotencyKey,
  });

  /// Executes [operations] as one all-or-nothing Mutation Transaction.
  @effect
  Future<MutationReceipt> batch(
    List<MutationOperation> operations, {
    required IdempotencyKey idempotencyKey,
  });

  /// Reads a Mutation Receipt by its URL, to resolve a lost or pending
  /// response.
  Future<MutationReceipt> readReceipt(String receipt);

  /// Follows a receipt's result-page continuation.
  Future<MutationReceiptPage> readReceiptPage(String next);

  /// Reads one finite changefeed page from [start].
  Future<ChangefeedPage> changes(ChangefeedStart start);

  /// Follows a changefeed page continuation.
  Future<ChangefeedPage> nextChanges(String next);

  /// Observes the changefeed live from [start], calling [apply] once per
  /// group, in order, one at a time.
  ///
  /// Every reconnect resumes after the checkpoint of the last group whose
  /// [apply] completed — the consumer's durable checkpoint — and never after
  /// a group the transport delivered but [apply] did not finish.
  @effect
  ChangefeedSubscription follow(
    ChangefeedStart start,
    ChangeGroupApplier apply,
  );

  /// Creates a snapshot and returns its manifest.
  @effect
  Future<SnapshotManifest> snapshot();
}

/// Page walking and replica bootstrap over any [LocalScope].
extension LocalScopeReading on LocalScope {
  /// Every Bead matching [query], following continuations to the end.
  Stream<BeadRecord> allBeads([BeadQuery query = const BeadQuery()]) =>
      _walk(beads(query), nextBeads);

  /// Every Link matching [query], following continuations to the end.
  Stream<LinkRecord> allLinks([LinkQuery query = const LinkQuery()]) =>
      _walk(links(query), nextLinks);

  /// Every Link incident upon [bead], following continuations to the end.
  Stream<LinkRecord> allIncidentLinks(
    String bead, {
    LinkDirection direction = LinkDirection.both,
  }) => _walk(incidentLinks(bead, direction: direction), nextLinks);

  /// Creates a snapshot, stages both of its streams completely, and installs
  /// them as a verified [Replica] anchored at the snapshot's checkpoint.
  @effect
  Future<Replica> bootstrap() async {
    final manifest = await snapshot();
    final beads = await _walk(Future.value(manifest.beads), nextBeads).toList();
    final links = await _walk(Future.value(manifest.links), nextLinks).toList();
    return Replica.fromSnapshot(manifest, beads: beads, links: links);
  }
}

Stream<T> _walk<T>(
  Future<Page<T>> first,
  Future<Page<T>> Function(String next) follow,
) async* {
  var page = await first;
  while (true) {
    yield* Stream.fromIterable(page.items);
    final next = page.next;
    if (next == null) return;
    page = await follow(next);
  }
}
