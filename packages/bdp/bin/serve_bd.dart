// Serves one bd store over HTTP as a BDP Scope until SIGINT or SIGTERM.
import 'dart:async';
import 'dart:io';

import 'package:bdp/bd.dart';

const _usage =
    'Usage: serve_bd --store=<directory> [--port=<n>] [--scope=<url>] '
    '[--actor=<name>] [--interval-ms=<n>] [--bd=<executable>]';

const _flags = '''
  --store=<directory>  the directory whose .beads is the store (required)
  --port=<n>           the port to bind on 127.0.0.1; 0 picks one (default 0)
  --scope=<url>        the canonical Scope URL (default http://127.0.0.1:<port>/)
  --actor=<name>       who bd records the writes as (default bdp)
  --interval-ms=<n>    how long after each read the store is read again (default 2000)
  --bd=<executable>    the bd to run (default bd)
  --help               print this usage''';

/// The flags of [arguments], by name, or a [FormatException] saying which
/// one is not a flag this program takes.
Map<String, String> _parse(List<String> arguments) {
  const known = {'store', 'port', 'scope', 'actor', 'interval-ms', 'bd'};
  final flags = <String, String>{};
  for (final argument in arguments) {
    final match = RegExp(r'^--([a-z-]+)=(.*)$').firstMatch(argument);
    final name = match?.group(1);
    if (name == null || !known.contains(name)) {
      throw FormatException('unknown argument $argument');
    }
    if (flags.containsKey(name)) {
      throw FormatException('--$name is given twice');
    }
    flags[name] = match!.group(2)!;
  }
  if (flags['store'] case null || '') {
    throw const FormatException('--store is required');
  }
  for (final name in ['port', 'interval-ms']) {
    if (flags[name] case final text?) {
      final value = int.tryParse(text);
      if (value == null || value < 0 || (name == 'interval-ms' && value < 1)) {
        throw FormatException('--$name is not a valid number: $text');
      }
    }
  }
  return flags;
}

@effect
Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout
      ..writeln(_usage)
      ..writeln(_flags);
    return;
  }
  final Map<String, String> flags;
  try {
    flags = _parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln('serve_bd: ${error.message}')
      ..writeln(_usage);
    exitCode = 64;
    return;
  }
  final BdStoreServer server;
  try {
    server = await serveBdStore(
      store: flags['store']!,
      port: int.parse(flags['port'] ?? '0'),
      scope: flags['scope'],
      actor: flags['actor'] ?? 'bdp',
      interval: Duration(
        milliseconds: int.parse(flags['interval-ms'] ?? '2000'),
      ),
      executable: flags['bd'] ?? 'bd',
      say: stdout.writeln,
    );
  } on BdFailure catch (failure) {
    stderr.writeln('serve_bd: $failure');
    exitCode = 1;
    return;
  }
  final stop = Completer<void>();
  void halt(ProcessSignal _) {
    if (!stop.isCompleted) stop.complete();
  }

  final signals = [
    ProcessSignal.sigint.watch().listen(halt),
    ProcessSignal.sigterm.watch().listen(halt),
  ];
  await stop.future;
  for (final signal in signals) {
    await signal.cancel();
  }
  await server.close();
}
