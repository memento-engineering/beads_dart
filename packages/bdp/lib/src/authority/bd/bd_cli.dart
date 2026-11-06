import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;
import 'package:meta/meta.dart';

/// The bd CLI as the bd authority runs it: one call, its argv, what it
/// printed.
abstract interface class BdCli {
  /// Runs `bd` with [arguments] and answers what it printed, whatever it
  /// exited with.
  @effect
  Future<BdOutput> run(List<String> arguments);
}

/// What a bd call printed: its [exitCode], [stdout] and [stderr].
@immutable
final class BdOutput {
  /// Output of a call that exited [exitCode].
  const BdOutput({required this.exitCode, this.stdout = '', this.stderr = ''});

  /// The exit code.
  final int exitCode;

  /// Everything printed on stdout.
  final String stdout;

  /// Everything printed on stderr.
  final String stderr;
}

/// A bd call that failed: bd's own [message], as [bdExplain] reads it.
final class BdFailure implements Exception {
  /// `bd [verb]` failed with [message].
  const BdFailure(this.verb, this.message);

  /// The bd command that failed: its arguments before the first flag.
  final String verb;

  /// What bd said.
  final String message;

  @override
  String toString() => 'bd $verb failed: $message';
}

/// Why the bd call that printed [output] failed: the JSON error envelope on
/// stdout first, then one on stderr, then stderr's text, then stdout's,
/// so a failure is never unexplained because one stream was empty.
///
/// An envelope is the whole text, or the first line of it, that is a JSON
/// object with a non-empty `error`; each `failed[].error` it lists is
/// joined after it.
String bdExplain(BdOutput output) =>
    _envelope(output.stdout) ??
    _envelope(output.stderr) ??
    _text(output.stderr) ??
    _text(output.stdout) ??
    'bd exited ${output.exitCode} and printed nothing';

String? _text(String text) => text.trim().isEmpty ? null : text.trim();

String? _envelope(String text) {
  for (final candidate in [text, ...const LineSplitter().convert(text)]) {
    final trimmed = candidate.trim();
    if (!trimmed.startsWith('{')) continue;
    final Object? json;
    try {
      json = jsonDecode(trimmed);
    } on FormatException {
      continue;
    }
    if (json case {'error': final String error} when error.isNotEmpty) {
      final failed = switch (json['failed']) {
        final List<Object?> failed => [
          for (final entry in failed)
            if (entry case {'error': final String detail}) detail,
        ],
        _ => const <String>[],
      };
      return [error, ...failed].join(': ');
    }
  }
  return null;
}

/// The bd command of [arguments]: its words before the first flag.
String bdVerbOf(List<String> arguments) =>
    arguments.takeWhile((argument) => !argument.startsWith('-')).join(' ');

/// Decoding what bd printed, over any [BdCli].
extension BdCalls on BdCli {
  /// Runs `bd` with [arguments] and decodes the JSON it printed on stdout.
  ///
  /// Throws a [BdFailure] when bd exits non-zero, explained by [bdExplain],
  /// or prints no JSON.
  @effect
  Future<Object?> json(List<String> arguments) async {
    final output = await run(arguments);
    final verb = bdVerbOf(arguments);
    if (output.exitCode != 0) throw BdFailure(verb, bdExplain(output));
    try {
      return jsonDecode(output.stdout);
    } on FormatException catch (error) {
      throw BdFailure(verb, 'printed no JSON: ${error.message}');
    }
  }

  /// The version bd reports: its `bd version` line, trimmed.
  @effect
  Future<String> version() async {
    final output = await run(const ['version']);
    if (output.exitCode != 0) throw BdFailure('version', bdExplain(output));
    final line = output.stdout.trim();
    if (line.isEmpty) throw const BdFailure('version', 'printed nothing');
    return line;
  }
}

/// The bd CLI over one store: [executable] run in [workspace], whose store
/// is `.beads` beneath it, writing as [actor].
///
/// Every call passes its arguments as argv, never through a shell, refuses
/// one holding NUL before anything runs, runs with only [environmentAllowlist]
/// of the parent's environment plus the store, the actor and bd's
/// non-interactive mode, and is killed when it runs past [bound]. Calls run
/// one at a time, in the order they were made.
final class BdProcessCli implements BdCli {
  /// The CLI at [executable] over the store in [workspace].
  BdProcessCli({
    required this.executable,
    required this.workspace,
    required this.actor,
    this.bound = const Duration(seconds: 60),
  });

  /// The parent's environment variables a call keeps; every other one is
  /// dropped, every `BEADS_*` one among them.
  static const environmentAllowlist = [
    'PATH',
    'HOME',
    'USER',
    'LOGNAME',
    'LANG',
    'LC_ALL',
    'TMPDIR',
  ];

  /// The bd executable: a path, or a name the parent's `PATH` resolves.
  final String executable;

  /// The directory whose `.beads` is the store.
  final String workspace;

  /// Who bd records the writes as.
  final String actor;

  /// How long one call may run.
  final Duration bound;

  Future<void> _tail = Future.value();

  /// The environment every call runs with.
  Map<String, String> get environment {
    final parent = Platform.environment;
    return {
      for (final key in environmentAllowlist) key: ?parent[key],
      'BEADS_DIR': '$workspace${Platform.pathSeparator}.beads',
      'BEADS_ACTOR': actor,
      'BD_NON_INTERACTIVE': '1',
      'NO_COLOR': '1',
    };
  }

  /// Runs `bd` with [arguments] after every call made before it.
  ///
  /// Throws an [ArgumentError] when an argument holds NUL, before anything
  /// runs, and a [BdFailure] when bd cannot be started or runs past
  /// [bound].
  @override
  @effect
  Future<BdOutput> run(List<String> arguments) {
    for (final argument in arguments) {
      if (argument.contains('\u0000')) {
        throw ArgumentError.value(
          bdVerbOf(arguments),
          'arguments',
          'an argument of bd ${bdVerbOf(arguments)} holds NUL',
        );
      }
    }
    final call = _after(_tail, arguments);
    _tail = _settled(call);
    return call;
  }

  static Future<void> _settled(Future<void> call) async {
    try {
      await call;
    } on Object {
      return;
    }
  }

  @effect
  Future<BdOutput> _after(Future<void> previous, List<String> arguments) async {
    await previous;
    return _call(arguments);
  }

  @effect
  Future<BdOutput> _call(List<String> arguments) async {
    final verb = bdVerbOf(arguments);
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workspace,
        environment: environment,
        includeParentEnvironment: false,
      );
    } on Object catch (error) {
      throw BdFailure(verb, 'could not start: $error');
    }
    unawaited(process.stdin.close());
    final stdout = _bytes(process.stdout);
    final stderr = _bytes(process.stderr);
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(bound);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw BdFailure(verb, 'ran past $bound and was killed');
    }
    try {
      return BdOutput(
        exitCode: exitCode,
        stdout: utf8.decode(await stdout),
        stderr: utf8.decode(await stderr),
      );
    } on FormatException catch (error) {
      throw BdFailure(verb, 'printed text that is not UTF-8: ${error.message}');
    }
  }

  /// Every byte [stream] carries; what it carried so far when it fails,
  /// which the exit code and the other stream then explain.
  static Future<List<int>> _bytes(Stream<List<int>> stream) async {
    final bytes = <int>[];
    try {
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }
    } on Object {
      return bytes;
    }
    return bytes;
  }
}
