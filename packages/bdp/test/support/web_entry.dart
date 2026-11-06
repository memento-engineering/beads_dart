// The web program structure_test.dart compiles with `dart compile js`: it
// touches the client's HTTP entry point and its SSE decoder, so a library
// either reaches that the web cannot load fails the compile.
import 'package:bdp/client.dart';

void main() {
  if (const [ScopeClient, Revision].isEmpty || decodeSse == main) {
    throw StateError('unreachable');
  }
}
