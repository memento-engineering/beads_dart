/// The Dart client for the Bead Protocol (BDP v0): wire types typed from the
/// normative schema bundle, a [ScopeClient] over HTTP, the [LocalScope]
/// interface an in-process authority implements, and a [Replica] that folds
/// a snapshot and the changefeed.
library;

import 'src/local_scope.dart';
import 'src/replica.dart';
import 'src/scope_client.dart';

export 'src/changefeed.dart';
export 'src/discovery.dart';
export 'src/events.dart';
export 'src/local_scope.dart';
export 'src/operations.dart';
export 'src/patch.dart';
export 'src/problem.dart';
export 'src/receipts.dart';
export 'src/records.dart';
export 'src/replica.dart';
export 'src/scope_client.dart';
export 'src/snapshot.dart';
export 'src/sse.dart';
export 'src/tokens.dart';
export 'src/types.dart';

// The authority: one Scope (Transactional subset) over SQLite, and its
// HTTP handler.
export 'src/authority/authority_library.dart';
// How a Scope reads a JSON value: which numbers it admits, and the text by
// which it identifies a value.
export 'src/authority/json_text.dart' show isAdmissibleNumber, semanticText;
