/// Offline support for tests that drive a BDP Scope without a network: an
/// [http.Client] that answers from a shelf handler in process, so a
/// `ScopeClient` can talk to `authorityHandler` with no socket.
library;

import 'package:http/http.dart' as http;

export 'src/testing/handler_client.dart';
