/// A client for the Gas City supervisor's HTTP API: its health and cities, a
/// city's status, its sessions and pending interactions, and its event log as
/// pages and as a live stream.
///
/// It reads beads through nothing here: beads are reached over BDP, through
/// `package:bdp/client.dart`. It runs on every platform, the web included.
library;

export 'src/gc_api.dart' show GcApi, GcCity;
export 'src/models.dart';
export 'src/problem.dart';
