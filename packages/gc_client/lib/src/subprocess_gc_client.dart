import 'dart:convert';
import 'dart:io';

import 'command.dart';
import 'exceptions.dart';
import 'gc_client.dart';
import 'model.dart';

/// Runs [executable] with [arguments] in [workingDirectory], with
/// [environment] added to the caller's, and completes with its exit code and
/// output, as [Process.run] does.
typedef GcRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// The [GcClient] transport that spawns `gc`, one process per call, with the
/// command line the bash seat ran for the same call: [showBead] runs
/// `gc bd show <id> --json`, [release] runs
/// `gc bd update <id> --status <status> --assignee '' --force`, and so on.
///
/// A call that cannot start `gc`, or that exits 0 without the JSON it asked
/// for, fails with a [GcTransportException]. A non-zero exit is read as gc
/// itself reads one: a signal, exit 4 (gc's managed Dolt server was
/// unreachable) or a stderr naming a transport failure (`dial tcp`,
/// `connection refused` and the rest gc retries on) is a
/// [GcTransportException]; any other non-zero exit is a [GcRefusal]. The
/// message names the call and carries its stderr without gc's informational
/// banners (`gc bd: answering from the city store`). [claimHook] reads gc's
/// answer first, whatever the exit status, because gc exits 1 on a drain it
/// did not acknowledge. [sling] starts gc itself, in
/// [ProcessStartMode.inheritStdio], never through the runner, which would
/// capture what gc prints: only gc's exit status comes back.
final class SubprocessGcClient implements GcClient {
  /// Creates the transport that runs [executable] (looked up on the PATH of
  /// [environment] when that sets one, else on the caller's) in
  /// [workingDirectory] (the caller's when null), adding [environment] to the
  /// caller's, every call but [sling] through [runner] ([processRun] when
  /// null).
  SubprocessGcClient({
    this.executable = 'gc',
    this.workingDirectory,
    this.environment,
    GcRunner? runner,
  }) : _runner = runner ?? processRun;

  /// The gc executable: a name looked up on the PATH, or a path.
  final String executable;

  /// The directory gc runs in; null runs it in the caller's.
  final String? workingDirectory;

  /// The variables gc gets on top of the caller's environment.
  final Map<String, String>? environment;

  final GcRunner _runner;

  @override
  Future<Bead> showBead(String id) async {
    final args = showArgs(id);
    return readBead(args, await _call(args));
  }

  @override
  Future<void> updateMetadata(String id, Map<String, String> metadata) =>
      _call(metadataArgs(id, metadata));

  @override
  Future<void> appendNotes(String id, String text) =>
      _call(notesArgs(id, text));

  @override
  Future<void> closeBead(String id, Outcome outcome) =>
      _call(closeArgs(id, outcome));

  @override
  Future<void> release(String id, {required String status}) =>
      _call(releaseArgs(id, status));

  @override
  Future<Convoy> convoyStatus(String convoyId) async {
    final args = convoyArgs(convoyId);
    return readConvoy(convoyId, args, await _call(args));
  }

  @override
  Future<void> mail(String to, String subject, String body) =>
      _call(mailArgs(to, subject, body));

  @override
  Future<HookClaim> claimHook({bool drainAck = false}) async {
    final args = hookArgs(drainAck: drainAck);
    final result = await _start(args);
    final stdout = result.stdout as String;
    final claim = HookClaim.fromJson(decodeJson(stdout));
    if (claim != null) return claim;
    if (result.exitCode != 0) {
      throw gcFailure(args, result.exitCode, result.stderr as String);
    }
    throw unexpectedOutput(args, stdout);
  }

  @override
  Future<List<Bead>> listByRoot(String rootId) async {
    final args = listArgs(rootId);
    return readBeads(args, await _call(args));
  }

  @override
  Future<List<Bead>> searchBeads(String query, {required int limit}) async {
    final args = searchArgs(query, limit);
    return readBeads(args, await _call(args));
  }

  @override
  Future<int> sling(List<String> args) async {
    final arguments = ['sling', ...args];
    try {
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        mode: ProcessStartMode.inheritStdio,
      );
      return await process.exitCode;
    } on ProcessException catch (error) {
      throw GcTransportException(
        '${gcWords(arguments)} could not start: ${error.message}',
      );
    }
  }

  /// Runs gc [args] and completes with what it printed on stdout; throws
  /// when gc cannot start or exits non-zero.
  Future<String> _call(List<String> args) async {
    final result = await _start(args);
    if (result.exitCode != 0) {
      throw gcFailure(args, result.exitCode, result.stderr as String);
    }
    return result.stdout as String;
  }

  /// Runs gc [args]; throws a [GcTransportException] when it cannot start.
  Future<ProcessResult> _start(List<String> args) async {
    try {
      return await _runner(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } on ProcessException catch (error) {
      throw GcTransportException(
        '${gcWords(args)} could not start: ${error.message}',
      );
    }
  }
}

/// The [GcRunner] that spawns the process: [Process.run], with its stdout
/// and stderr decoded as UTF-8. It is how [SubprocessGcClient] runs `gc` by
/// default, and how the judge's ops run `git`, `gh`, `sh` and `bash`.
Future<ProcessResult> processRun(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) => Process.run(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);
