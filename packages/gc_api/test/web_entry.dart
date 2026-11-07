// The web program web_test.dart compiles with `dart compile js`: it touches
// the client and its event stream, so a library either reaches that the web
// cannot load fails the compile.
import 'package:gc_api/gc_api.dart';

void main() {
  if (const [
    GcApi,
    GcCity,
    GcEvent,
    SessionPage,
    GcSession,
    PendingPage,
    SessionPending,
  ].isEmpty) {
    throw StateError('unreachable');
  }
}
