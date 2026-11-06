/// A bd store served as a BDP Scope: the bd authority, which reads and
/// writes the store through bd's own CLI and JSON, never its tables, and
/// stands in for bd until bd speaks BDP itself.
///
/// It is apart from `bdp.dart`: a client above the Scope reads and writes
/// it through `LocalScope` or `ScopeClient` and never runs bd. Such a client
/// reads what a failed write was with [bdWriteFailureOf], never by parsing a
/// problem's title. The read's own arguments are exported for a test that
/// lists a store as bd prints it, so one spelling of the read serves both.
library;

import 'src/authority/bd/bd_writes.dart';

export 'package:genesis_foundation/genesis_foundation.dart' show effect;

export 'src/authority/bd/bd_authority.dart' show BdScopeAuthority;
export 'src/authority/bd/bd_cli.dart'
    show BdCalls, BdCli, BdFailure, BdOutput, BdProcessCli, bdExplain;
export 'src/authority/bd/bd_rows.dart' show bdListArguments;
export 'src/authority/bd/bd_server.dart' show BdStoreServer, serveBdStore;
export 'src/authority/bd/bd_writes.dart' show BdWriteFailure, bdWriteFailureOf;
