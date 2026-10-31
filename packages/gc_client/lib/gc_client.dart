/// The `GcClient` seam: how a deterministic seat reads and writes a Gas City
/// store and sends its mail, whatever transport sits behind it.
///
/// [SubprocessGcClient] is the transport that spawns `gc`. The in-process
/// test double, `FakeGcClient`, is in `package:gc_client/testing.dart`.
/// [withoutBanners] reads any command's stderr the way the seam reads gc's.
library;

export 'src/command.dart' show withoutBanners;
export 'src/exceptions.dart';
export 'src/gc_client.dart';
export 'src/model.dart';
export 'src/subprocess_gc_client.dart';
