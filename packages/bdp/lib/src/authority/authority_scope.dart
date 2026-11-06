import 'dart:async';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;

import 'authority.dart';
import 'identity.dart';
import 'json_text.dart';
import 'types.dart';

/// The wire-level surface of one Scope's authority: what [authorityHandler]
/// serves over HTTP and the in-process [LocalScope] binding decodes.
///
/// [ScopeAuthority] implements it over SQLite. Every read answers the wire
/// document with the Scope context it observed, and throws
/// [AuthorityProblem] for a direct refusal; [mutate] may answer
/// asynchronously, so every caller through this interface awaits it.
abstract interface class AuthorityScope {
  /// The canonical Scope URL and the addresses derived from it.
  ScopeAddress get address;

  /// The Types the Scope serves. It is read-only.
  AuthorityTypeRegistry get typeRegistry;

  /// The current Scope epoch.
  String get epoch;

  /// The Scope context as it stands, with an empty body: what a response
  /// that carries no representation (a problem, a `406`) reports.
  AuthorityRead observe();

  /// The Transactional discovery document.
  AuthorityRead discoveryDocument();

  /// The twelve-entry Transactional Operation Directory.
  AuthorityRead operationDirectory();

  /// A page of the `types/` inventory in canonical-uri order.
  AuthorityRead typeInventory({int? limit, String? cursor});

  /// The Type Descriptor of the installed Type [id].
  AuthorityRead typeDescriptor(String id);

  /// The canonical record of the Bead or Link at [reference].
  AuthorityRead resource(String reference);

  /// A page of [kind]'s collection in canonical-uri order under the
  /// structural predicates. A cursor continues only while the Scope epoch
  /// and head are unchanged; otherwise it fails `cursor-expired`.
  AuthorityRead collection(
    AuthorityResourceKind kind, {
    String? type,
    String? conformsTo,
    String? source,
    String? target,
    String? endpoint,
    int? limit,
    String? cursor,
  });

  /// The incident Link view of the Bead at [reference].
  AuthorityRead incidentLinkPage(
    String reference, {
    String direction = 'both',
    int? limit,
    String? cursor,
  });

  /// The receipt at [token] for [principal]; another principal's, an
  /// unknown, a forgotten or a prior epoch's receipt is `resource-not-found`.
  AuthorityRead receipt(
    String token, {
    String principal = authorityAnonymousPrincipal,
  });

  /// Submits [body] to the operation [target] (`batch` or a singleton target
  /// name such as `create-bead`) as one Mutation Transaction.
  ///
  /// Throws [AuthorityProblem] for a direct refusal (malformed request,
  /// conflicting key, limit). Every admitted request answers its receipt,
  /// `completed` or `failed`. [inadmissibleNumbers] maps the body pointer
  /// of each number literal that does not round-trip through binary64 to
  /// the exact decimal value it denotes. With [admitNew] false, a request
  /// whose key is unknown throws [AuthorityNotAdmitted] instead of
  /// executing, while a retained duplicate still answers its receipt.
  @effect
  FutureOr<AuthorityReceipt> mutate(
    String target,
    Object? body, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
    Map<String, String> inadmissibleNumbers = const {},
    bool admitNew = true,
  });

  /// A finite changefeed page after [after] (a checkpoint, or `genesis`),
  /// or, with [startNow], an empty page anchored at the current head.
  /// Supplying neither, or both, is `invalid-parameter`.
  AuthorityRead changePage({String? after, bool startNow = false, int? limit});

  /// Every committed change group after [after] (a checkpoint or `genesis`;
  /// null means from now), then each group committed to the Scope, live.
  @effect
  Stream<JsonMap> watch({String? after});

  /// A snapshot manifest at the current head with both streams inline. Its
  /// handle is retained for the snapshot lifetime.
  @effect
  AuthorityRead snapshotDocument();

  /// Refetches the manifest a [snapshotDocument] handle names, with the same
  /// anchor, checkpoint and expiry.
  AuthorityRead snapshotHandle(String token);

  /// A finite page of an Event Source: the Scope's (`events/`) when
  /// [resource] is null, else the Bead's or Link's own. [after] is an
  /// exclusive Event ID; null starts at the earliest Event.
  AuthorityRead events({String? resource, String? after, int? limit});

  /// Enforces a minimum-position read context against [observed], the
  /// position a read already served from: a foreign epoch is
  /// `cursor-expired`, a foreign view `foreign-view`, and a position past
  /// [observed] `catch-up-timeout`.
  void requireMinimum({
    String? epoch,
    String? view,
    required String position,
    required AuthorityRead observed,
  });

  /// Ends every live [watch] stream and releases what the authority holds.
  @effect
  FutureOr<void> close();
}
