// Real-bd test support. A test that runs a real bd stamps only a store it
// creates, in proxied-server mode (one Dolt sql-server for the store), with
// the version of the bd that created it, and before it hands any store to
// an authority it compares that stamp with the bd it will run: a mismatch,
// a store with no stamp or no bd at all skips the test, naming both versions
// or the missing stamp. Nothing turns the check off: this file declares no
// flag and takes nothing from the process's environment of its own, which
// `structure_test.dart` pins.
import 'dart:convert';
import 'dart:io';

import 'package:bdp/bd.dart';
import 'package:test/test.dart';

/// The file a store's stamp is written to, beside its `.beads`.
const stampFile = 'bd-version-stamp';

/// The bd a real-bd test runs: the one the test runner's `PATH` resolves.
const bdExecutable = 'bd';

/// The environment a test's own bd calls run with: the CLI's allowlist, so
/// no inherited `BEADS_*` setting points bd at another store.
Map<String, String> _isolated(String workspace, String actor) => BdProcessCli(
  executable: bdExecutable,
  workspace: workspace,
  actor: actor,
).environment;

/// The version `bd version` prints, or null when bd cannot be run.
Future<String?> bdVersion() async {
  try {
    final result = await Process.run(
      bdExecutable,
      const ['version'],
      environment: _isolated(Directory.systemTemp.path, 'bdp-test')
        ..remove('BEADS_DIR'),
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) return null;
    final version = (result.stdout as String).trim();
    return version.isEmpty ? null : version;
  } on ProcessException {
    return null;
  }
}

/// Whether `dolt version` runs here: bd's proxied-server mode resolves dolt
/// from the `PATH`, so a host with bd and no dolt cannot initialize a store.
Future<bool> doltRuns() async {
  try {
    final result = await Process.run(
      'dolt',
      const ['version'],
      environment: _isolated(Directory.systemTemp.path, 'bdp-test')
        ..remove('BEADS_DIR'),
      includeParentEnvironment: false,
    );
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// A store a test made itself, stamped with [version].
final class StampedStore {
  StampedStore._(this.directory, this.version);

  /// Initializes a proxied-server store with prefix `t` in a new temporary
  /// directory and stamps it with the version bd reports; null, with the
  /// reason, when no bd runs here.
  static Future<(StampedStore?, String?)> create() async {
    final version = await bdVersion();
    if (version == null) return (null, 'no bd on the PATH runs `bd version`');
    if (!await doltRuns()) {
      return (
        null,
        'no dolt on the PATH, which `bd init --proxied-server` needs',
      );
    }
    final directory = await Directory.systemTemp.createTemp('bdp-bd-');
    final result = await Process.run(
      bdExecutable,
      const [
        'init',
        '--non-interactive',
        '--prefix=t',
        '--skip-hooks',
        '--skip-agents',
        '--role=maintainer',
        '-q',
        '--proxied-server',
      ],
      workingDirectory: directory.path,
      environment: _isolated(directory.path, 'bdp-test')..remove('BEADS_DIR'),
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      await directory.delete(recursive: true);
      throw StateError('bd init failed: ${result.stdout}${result.stderr}');
    }
    File('${directory.path}/$stampFile').writeAsStringSync(version);
    return (StampedStore._(directory, version), null);
  }

  /// The directory whose `.beads` is the store.
  final Directory directory;

  /// The version of the bd that made the store.
  final String version;

  /// Stops the store's Dolt server, whatever that answers, then deletes the
  /// store.
  Future<void> delete() async {
    try {
      await Process.run(
        bdExecutable,
        const ['dolt', 'stop'],
        workingDirectory: directory.path,
        environment: _isolated(directory.path, 'bdp-test'),
        includeParentEnvironment: false,
      );
    } on ProcessException {
      // A store whose server cannot be stopped is deleted all the same.
    }
    await directory.delete(recursive: true);
  }
}

/// Why a real-bd test must not run bd against [store], or null when it may:
/// the store carries a stamp, and the stamp names the version bd reports.
Future<String?> stampRefusal(StampedStore store) async {
  final stamp = File('${store.directory.path}/$stampFile');
  if (!stamp.existsSync()) {
    return 'the store at ${store.directory.path} carries no bd version stamp';
  }
  final stamped = stamp.readAsStringSync().trim();
  final running = await bdVersion();
  if (running == null) return 'no bd on the PATH runs `bd version`';
  if (running != stamped) {
    return 'the store was stamped by "$stamped" and the bd here is '
        '"$running"';
  }
  return null;
}

/// The CLI over [store] as [actor], once the stamp check has passed; null,
/// with the test marked skipped naming why, when it has not.
Future<BdProcessCli?> stampedCli(
  StampedStore? store,
  String? absence, {
  String actor = 'bdp-test',
}) async {
  if (store == null) {
    markTestSkipped(absence ?? 'no store was made');
    return null;
  }
  if (await stampRefusal(store) case final refusal?) {
    markTestSkipped(refusal);
    return null;
  }
  return BdProcessCli(
    executable: bdExecutable,
    workspace: store.directory.path,
    actor: actor,
  );
}

/// Runs [arguments] against [store] as a human at the terminal would, and
/// decodes its JSON, or answers its text when it printed none: the test's
/// own hand on the store, never the authority's.
Future<Object?> human(StampedStore store, List<String> arguments) async {
  final result = await Process.run(
    bdExecutable,
    arguments,
    workingDirectory: store.directory.path,
    environment: _isolated(store.directory.path, 'a-human'),
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'bd ${arguments.join(' ')} failed: ${result.stdout}${result.stderr}',
    );
  }
  final out = (result.stdout as String).trim();
  if (out.isEmpty) return null;
  try {
    return jsonDecode(out);
  } on FormatException {
    return out;
  }
}

/// The id of the bead a human makes with [title].
Future<String> humanCreate(StampedStore store, String title) async {
  final made = await human(store, [
    'create',
    '--title=$title',
    '--type=task',
    '--json',
  ]);
  return (made! as Map<String, Object?>)['id']! as String;
}

/// A [BdCli] over [inner] that records every call and may answer one
/// itself.
final class RecordingCli implements BdCli {
  RecordingCli(this.inner);

  final BdCli inner;

  /// Every call's arguments, in order.
  final List<List<String>> calls = [];

  /// Answers a call before [inner] does; null passes it on.
  BdOutput? Function(List<String> arguments)? intercept;

  /// The calls that write: every one but `list`, `config` and `version`.
  List<List<String>> get writes => [
    for (final call in calls)
      if (!const {'list', 'config', 'version'}.contains(call.first)) call,
  ];

  @override
  Future<BdOutput> run(List<String> arguments) async {
    calls.add(List.of(arguments));
    if (intercept?.call(arguments) case final answer?) return answer;
    return inner.run(arguments);
  }
}
