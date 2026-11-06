/// The BDP v0 client alone: everything `bdp.dart` exports but the authority,
/// so a client on any platform, the web included, imports it. It reaches
/// neither `dart:io` nor SQLite.
library;

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
