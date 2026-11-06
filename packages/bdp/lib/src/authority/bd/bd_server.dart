import 'dart:io';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../http.dart';
import 'bd_authority.dart';
import 'bd_cli.dart';

/// One bd store served over HTTP as a BDP Scope by [serveBdStore].
final class BdStoreServer {
  BdStoreServer._(
    this._server,
    this._authority, {
    required this.url,
    required this.bdVersion,
  });

  final HttpServer _server;
  final BdScopeAuthority _authority;

  /// The canonical Scope URL; its service description is `bdp.json` below
  /// it.
  final String url;

  /// The line `bd version` printed as the server started.
  final String bdVersion;

  /// How long after each read of the store ends it is read again.
  Duration get interval => _authority.interval;

  /// Stops answering requests, then closes the authority.
  @effect
  Future<void> close() async {
    await _server.close(force: true);
    await _authority.close();
  }
}

/// Serves the bd store in [store] (the directory whose `.beads` it is) over
/// HTTP at `127.0.0.1:[port]` (0 picks a free one) as the Scope [scope], or
/// `http://127.0.0.1:<bound port>/` when [scope] is null.
///
/// It runs [executable] as [actor] through a [BdProcessCli], reads the store
/// every [interval], and, once it answers, [say]s three lines in order: the
/// `bd version` line read once as it started, the polling interval, and the
/// service description's URL. Throws a [BdFailure] when bd does not report
/// its version.
@effect
Future<BdStoreServer> serveBdStore({
  required String store,
  int port = 0,
  String? scope,
  String actor = 'bdp',
  Duration interval = const Duration(seconds: 2),
  String executable = 'bd',
  void Function(String line)? say,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  final url = scope ?? 'http://127.0.0.1:${server.port}/';
  final cli = BdProcessCli(
    executable: executable,
    workspace: store,
    actor: actor,
  );
  final String bdVersion;
  final BdScopeAuthority authority;
  try {
    bdVersion = await cli.version();
    authority = await BdScopeAuthority.open(
      bd: cli,
      scope: url,
      interval: interval,
    );
  } on Object {
    await server.close(force: true);
    rethrow;
  }
  shelf_io.serveRequests(server, authorityHandler(authority));
  say?.call('bd: $bdVersion');
  say?.call('polling every ${interval.inMilliseconds} ms');
  say?.call('service description: ${url}bdp.json');
  return BdStoreServer._(server, authority, url: url, bdVersion: bdVersion);
}
