/// The test double of the `GcClient` seam: [FakeGcClient] answers in process
/// from the JSON fixtures the bash fake gc (`tests/lib/fake-gc.sh`) serves,
/// and records every store write and mail as a [GcMutation].
library;

export 'src/fake_gc_client.dart';
