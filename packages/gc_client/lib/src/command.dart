import 'dart:convert';

import 'exceptions.dart';
import 'model.dart';

// The gc command lines both transports share, and how gc's answers and
// failures are read. The command lines are the bash seat's at 9222c74:
// bead_json, set_meta, close_pass, close_fail and mail_human
// (assets/scripts/lib/common.sh), the release and the hook claims
// (assets/scripts/judge.sh), the root list (assets/scripts/lib/telemetry.sh),
// the search (assets/scripts/ops/anchors.sh) and the convoy read
// (assets/scripts/ops/prepare.sh). The failure rule is gc's own, read from
// gascity at 4f698fe2 (cmd/gc/cmd_bd.go, cmd/gc/bd_env.go).

/// `gc bd show <id> --json`
List<String> showArgs(String id) => ['bd', 'show', id, '--json'];

/// `gc bd update <id> --set-metadata <key>=<value> ...`, one flag per entry
/// in the order of [metadata]; an [ArgumentError] when [metadata] is empty or
/// a key is empty or holds a `=`.
List<String> metadataArgs(String id, Map<String, String> metadata) {
  if (metadata.isEmpty) {
    throw ArgumentError.value(metadata, 'metadata', 'sets no key');
  }
  for (final key in metadata.keys) {
    if (key.isEmpty || key.contains('=')) {
      throw ArgumentError.value(key, 'metadata', 'is not a metadata key');
    }
  }
  return [
    'bd',
    'update',
    id,
    for (final MapEntry(:key, :value) in metadata.entries) ...[
      '--set-metadata',
      '$key=$value',
    ],
  ];
}

/// `gc bd update <id> --append-notes <text>`
List<String> notesArgs(String id, String text) => [
  'bd',
  'update',
  id,
  '--append-notes',
  text,
];

/// `gc bd update <id> --set-metadata gc.outcome=pass --status closed`, or for
/// a [Failed] outcome `gc.outcome=fail`, `gc.failure_class=<class>` and
/// `gc.failure_reason=<reason>` before `--status closed`, the reason as
/// [failureReason] writes it.
List<String> closeArgs(String id, Outcome outcome) => [
  'bd',
  'update',
  id,
  ...switch (outcome) {
    Passed() => ['--set-metadata', 'gc.outcome=pass'],
    Failed(:final failureClass, :final reason) => [
      '--set-metadata',
      'gc.outcome=fail',
      '--set-metadata',
      'gc.failure_class=${failureClass.name}',
      '--set-metadata',
      'gc.failure_reason=${failureReason(reason)}',
    ],
  },
  '--status',
  'closed',
];

/// `gc bd update <id> --status <status> --assignee '' --force`
List<String> releaseArgs(String id, String status) => [
  'bd',
  'update',
  id,
  '--status',
  status,
  '--assignee',
  '',
  '--force',
];

/// `gc convoy status <id> --json`
List<String> convoyArgs(String id) => ['convoy', 'status', id, '--json'];

/// `gc mail send <to> -s <subject> -m <body>`
List<String> mailArgs(String to, String subject, String body) => [
  'mail',
  'send',
  to,
  '-s',
  subject,
  '-m',
  body,
];

/// `gc hook --claim --json`, or `gc hook --claim --drain-ack --json`
List<String> hookArgs({required bool drainAck}) => [
  'hook',
  '--claim',
  if (drainAck) '--drain-ack',
  '--json',
];

/// `gc bd list --all --metadata-field gc.root_bead_id=<root>`, then
/// `--limit 0 --brief --skip-labels --flat --json`
List<String> listArgs(String rootId) => [
  'bd',
  'list',
  '--all',
  '--metadata-field',
  'gc.root_bead_id=$rootId',
  '--limit',
  '0',
  '--brief',
  '--skip-labels',
  '--flat',
  '--json',
];

/// `gc bd search <query> --json --limit <limit>`
List<String> searchArgs(String query, int limit) => [
  'bd',
  'search',
  query,
  '--json',
  '--limit',
  '$limit',
];

/// A failure reason as `close_fail` writes it: each newline a space, cut to
/// its first 400 characters.
String failureReason(String reason) {
  final flat = reason.replaceAll('\n', ' ');
  return flat.runes.length <= 400
      ? flat
      : String.fromCharCodes(flat.runes.take(400));
}

/// The words a message names gc call [args] by: `gc` and the arguments
/// before the first flag, as in `gc bd show bead-1` or `gc hook`.
String gcWords(List<String> args) =>
    ['gc', ...args.takeWhile((arg) => !arg.startsWith('-'))].join(' ');

final _banner = RegExp(r'^gc (bd|ready|convoy|mail):');

/// [stderr] without gc's informational banners, as judge.sh reads an op's
/// stderr: every line that starts `gc bd:`, `gc ready:`, `gc convoy:` or
/// `gc mail:` is dropped, and the last 400 characters of the rest are kept,
/// trimmed.
String withoutBanners(String stderr) {
  final kept = stderr
      .split('\n')
      .where((line) => !_banner.hasMatch(line))
      .join('\n')
      .trim();
  final runes = kept.runes.toList();
  return runes.length <= 400
      ? kept
      : String.fromCharCodes(runes.sublist(runes.length - 400));
}

/// The exit status `gc bd` gives when its managed Dolt server was unreachable
/// and a write was dropped (`bdSilentFallbackExitCode`).
const unreachableExit = 4;

/// What gc itself reads, in any case, as a bd transport failure
/// (`bdTransportRetryableError`).
const transportMarkers = [
  'server unreachable',
  'dial tcp',
  'connection refused',
  'broken pipe',
  'unexpected eof',
  'bad connection',
  'use of closed network connection',
  'auto-importing',
  'into empty database',
];

/// The failure of gc call [args], which exited [exitCode], not 0, with
/// [stderr]: a [GcTransportException] when gc was killed by a signal (a
/// negative [exitCode]), exited [unreachableExit], or [stderr] holds one of
/// [transportMarkers]; a [GcRefusal] otherwise. Its message is
/// `<gcWords> exited <exitCode>`, then `: ` and [stderr] [withoutBanners]
/// when that is not empty, and it keeps [stderr] itself as its `stderr`.
GcException gcFailure(List<String> args, int exitCode, String stderr) {
  final said = withoutBanners(stderr);
  final message =
      '${gcWords(args)} exited $exitCode${said.isEmpty ? '' : ': $said'}';
  final lower = stderr.toLowerCase();
  if (exitCode < 0 ||
      exitCode == unreachableExit ||
      transportMarkers.any(lower.contains)) {
    return GcTransportException(message, exitCode: exitCode, stderr: stderr);
  }
  return GcRefusal(message, exitCode: exitCode, stderr: stderr);
}

/// The failure of gc call [args], which exited 0 and printed [stdout] that
/// is not the answer it asked for: `<gcWords> printed unexpected output:`
/// and [stdout], trimmed and cut to 200 characters, or `(empty)`.
GcTransportException unexpectedOutput(List<String> args, String stdout) {
  final out = stdout.trim();
  final shown = out.isEmpty
      ? '(empty)'
      : out.runes.length <= 200
      ? out
      : '${String.fromCharCodes(out.runes.take(200))}...';
  return GcTransportException(
    '${gcWords(args)} printed unexpected output: $shown',
    exitCode: 0,
  );
}

/// [stdout] decoded as JSON, or null when it is not JSON.
Object? decodeJson(String stdout) {
  try {
    return jsonDecode(stdout);
  } on FormatException {
    return null;
  }
}

/// The bead `gc bd show --json` printed for call [args]: the first element of
/// its array, or the object itself; a [GcTransportException] when there is
/// none.
Bead readBead(List<String> args, String stdout) {
  final json = decodeJson(stdout);
  final first = json is List<Object?> && json.isNotEmpty ? json.first : json;
  return Bead.fromJson(first) ?? (throw unexpectedOutput(args, stdout));
}

/// The beads of a `gc bd list --json` answer (its `issues`) or of a
/// `gc bd search --json` answer (an array) for call [args]; a
/// [GcTransportException] when [stdout] is neither or an item is no bead.
List<Bead> readBeads(List<String> args, String stdout) {
  final json = decodeJson(stdout);
  final items = json is Map<String, Object?>
      ? json['issues'] ?? const <Object?>[]
      : json;
  if (items is! List<Object?>) throw unexpectedOutput(args, stdout);
  return [
    for (final item in items)
      Bead.fromJson(item) ?? (throw unexpectedOutput(args, stdout)),
  ];
}

/// The convoy `gc convoy status --json` printed for call [args]; a
/// [GcTransportException] when [stdout] is not one.
Convoy readConvoy(String convoyId, List<String> args, String stdout) =>
    Convoy.fromJson(convoyId, decodeJson(stdout)) ??
    (throw unexpectedOutput(args, stdout));
