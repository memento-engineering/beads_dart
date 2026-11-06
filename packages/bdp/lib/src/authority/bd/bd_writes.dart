/// One operation turned into the bd calls that write it, decided before any
/// call runs.
///
/// A bd store is written by many actors, so no call replaces a field or map
/// another actor also writes: metadata is merged per key, notes are
/// appended, a status moves through bd's own verbs, and a free-text field
/// is written by the create that makes the bead and by the one guarded text
/// update, which sets description, design and acceptance together at an
/// expected revision, and by nothing else. A create that carries metadata is
/// two calls, the create carrying an external ref and then the update that
/// merges the metadata, so a bead whose merge failed stays findable by that
/// ref.
library;

import 'dart:convert';

import '../../problem.dart' show ProblemDetails;
import '../json_text.dart';
import '../operations.dart';
import '../patch.dart';
import '../problem.dart';

// The titles of the problems a write through the bd authority answers, by
// which [bdWriteFailureOf] tells apart those that share a code.

/// A key that is not a valid Idempotency-Key.
const bdKeyTitle = 'Idempotency-Key is not a valid key';

/// A target that names no operation.
const bdTargetTitle = 'No such operation target';

/// An operation the authority does not serve.
const bdUnservedTitle = 'Operation is not served by this authority';

/// A key already bound to another request.
const bdKeyBoundTitle = 'Idempotency key is bound to a different request';

/// A batch of more operations than one transaction carries.
const bdTooManyTitle = 'Too many operations';

/// A store that could not be read whole before the write.
const bdUnreadTitle = 'The bd store could not be read before the write';

/// A number the Scope cannot hold.
const bdNumberTitle = 'Number literal is not admissible';

/// A change bd has no write for, refused before any call.
const bdNoWriteTitle = 'bd has no write for this change';

/// A change that does not apply to the bead's properties.
const bdPatchTitle = 'Property Change cannot apply';

/// A create that supplies its bead's id.
const bdSuppliedIdTitle = 'bd allocates every bead id';

/// A bead or a gate's bead the read does not serve.
const bdNoResourceTitle = 'No such Resource';

/// A create of a Type that is not installed.
const bdTypeTitle = 'Type is not installed';

/// A create of a Type that describes Links.
const bdLinkTypeTitle = 'Resource state is not admissible';

/// A create whose external ref more than one bead holds.
const bdRefTakenTitle = 'More than one bead holds the external ref';

/// A gate's create whose key more than one gate holds.
const bdGateTakenTitle = 'More than one gate is held under the key';

/// An expected revision the bead is no longer at: nothing was written.
const bdMovedTitle = 'Resource is not at the expected revision';

/// A bd that could not be run.
const bdUnrunTitle = 'bd could not be run';

/// A call bd refused, its detail bd's own explanation.
const bdRejectedTitle = 'bd refused the write';

/// A create bd printed no id for.
const bdNoIdTitle = 'bd create named no bead';

/// A create that stood while the merge of its metadata did not.
const bdStoodTitle = 'The create stood and the merge of its metadata did not';

/// A write the whole reads after it never served.
const bdUnconfirmedTitle = 'bd did not confirm the write';

/// What a failed write through the bd authority was, as
/// [bdWriteFailureOf] reads its receipt's problem.
enum BdWriteFailure {
  /// Refused before any bd call: the change is one bd has no write for.
  refused,

  /// bd refused the call; the message is bd's own explanation, whole.
  rejected,

  /// The bead moved past the expected revision; nothing was written.
  moved,

  /// bd took the write and the whole reads after it never served it; the
  /// instance is the bead's URL.
  unconfirmed,

  /// A create stood and the merge of its metadata did not; the instance is
  /// the bead's URL.
  stood,

  /// Anything else: a bead the read does not serve, a key or ref two beads
  /// hold, a Type not installed, a bd that could not be run, a create that
  /// named no bead.
  failed,
}

/// What the failed write whose receipt carries [problem] was, a message
/// saying why, and the URL of the bead it names when it names one.
///
/// A refusal's message is its detail, else its first diagnostic's, else its
/// title; a rejection's is bd's own explanation whole; every other one is
/// its detail, else its title.
({BdWriteFailure kind, String message, String? instance}) bdWriteFailureOf(
  ProblemDetails problem,
) {
  final kind = switch ((problem.code, problem.title)) {
    ('validation-failed', bdRejectedTitle) => BdWriteFailure.rejected,
    ('validation-failed', _) => BdWriteFailure.refused,
    ('revision-mismatch', bdMovedTitle) => BdWriteFailure.moved,
    ('revision-mismatch', bdUnconfirmedTitle) => BdWriteFailure.unconfirmed,
    ('revision-mismatch', bdStoodTitle) => BdWriteFailure.stood,
    _ => BdWriteFailure.failed,
  };
  final message =
      problem.detail ??
      (kind == BdWriteFailure.refused
          ? problem.diagnostics?.firstOrNull?.message
          : null) ??
      problem.title ??
      problem.code;
  return (kind: kind, message: message, instance: problem.instance);
}

/// The operation fails with [problem] before any bd call runs.
final class BdWriteRefused implements Exception {
  /// A refusal with [problem].
  const BdWriteRefused(this.problem);

  /// The problem the failed receipt carries.
  final AuthorityProblem problem;
}

/// The fields of a served bead that do not yet hold what a write authored,
/// by name; empty once the write is confirmed.
typedef BdDiffering = List<String> Function(JsonMap served);

/// The free-text fields bd writes only whole: the create that makes the bead
/// sets them, and the one guarded text update sets [bdGuardedTextFields]
/// together; no other update replaces them.
const bdWholeTextFields = [
  'title',
  'description',
  'design',
  'acceptance_criteria',
];

/// The texts the guarded text update sets together, by the property that
/// carries each, with the flag of `bd update` that writes it, in the order
/// the call names them.
const bdGuardedTextFields = {
  'description': 'description',
  'design': 'design',
  'acceptance_criteria': 'acceptance',
};

/// The fields an update writes through one flag of `bd update`, by the
/// property that carries each.
const bdScalarFlags = {
  'priority': 'priority',
  'issue_type': 'type',
  'assignee': 'assignee',
  'external_ref': 'external-ref',
};

/// The properties a create may carry.
const bdCreateProperties = {
  ...bdWholeTextFields,
  'notes',
  'priority',
  'issue_type',
  'assignee',
  'external_ref',
  'metadata',
};

/// The properties a gate's create carries, every one of them a non-empty
/// text: its `issue_type`, `gate`; the key it is found again by; the bd id
/// of the bead it blocks; and the reason it is opened for. `blocks` and
/// `reason` are the arguments of bd's gate verb, and no read serves them.
const bdGateCreateProperties = ['issue_type', 'await_id', 'blocks', 'reason'];

/// What bd puts before a gate's reason, the last paragraph of the gate's
/// description.
const bdGateReasonLead = 'Reason: ';

/// The fields of the served beads, by bd id, that do not yet hold what a
/// write of the bead [id] authored, by name; empty once it is confirmed.
typedef BdServedDiffering =
    List<String> Function(String id, Map<String, JsonMap> served);

/// The one call of a gate's create, the key it is found again by, the bead
/// it blocks, and how its read-back is confirmed.
typedef BdGateCreatePlan = ({
  String key,
  String blocks,
  List<String> create,
  BdServedDiffering differing,
});

/// The calls of one update, in order, and how its read-back is confirmed.
typedef BdUpdatePlan = ({List<List<String>> calls, BdDiffering differing});

/// The calls of one create: the create itself, the metadata it merges after
/// it, and how its read-back is confirmed.
typedef BdCreatePlan = ({
  String ref,
  List<String> create,
  Map<String, String> metadata,
  BdDiffering differing,
});

/// The bd calls that apply [operation] to the bead [id], whose served
/// properties are [current].
///
/// A change that is exactly one `add` or `replace` at each of
/// [bdGuardedTextFields] is the guarded text update: one `bd update` setting
/// all three, made only at an expected revision, which the authority checks
/// against its whole read before the call. A metadata key the change names
/// is merged even when the current properties already hold it, so a merge
/// asked for is always one bd makes. A change to `status` `closed` is
/// `bd gate resolve` for a gate, `bd close` when it carries a
/// `close_reason`, and `bd update --status=closed` otherwise.
///
/// Throws [BdWriteRefused] for a change bd has no write verb for, before any
/// call: any other change naming a whole free-text field, a whole metadata
/// map or the whole properties, a notes change that does not extend the
/// current notes, and any property no flag writes.
BdUpdatePlan planBdUpdate(
  UpdateProperties operation,
  String id,
  JsonMap current,
) {
  for (final change in operation.change) {
    final path = change['path']! as String;
    if (path.isEmpty || path == '/metadata') {
      throw _invalid(
        operation,
        '/change',
        path.isEmpty
            ? 'a change of the whole properties replaces what other actors '
                  'wrote; change one property at a time'
            : 'a change of the whole metadata map replaces keys other '
                  'actors set; change one key at a time',
      );
    }
  }
  if (_guardedText(operation, id) case final plan?) return plan;
  for (final change in operation.change) {
    final key = _topToken(change['path']! as String);
    if (bdWholeTextFields.contains(key)) {
      throw _invalid(
        operation,
        '/change',
        '$key is free text other actors also write: bd writes it whole only '
            'by the create that makes the bead, and by the one guarded text '
            'update of description, design and acceptance together at an '
            'expected revision',
      );
    }
  }
  final named = {
    for (final change in operation.change)
      if (change['op'] != 'remove') ?_metadataEntry(change['path']! as String),
  };
  final base = {...current};
  if (!base.containsKey('metadata') &&
      operation.change.any(
        (change) => (change['path']! as String).startsWith('/metadata/'),
      )) {
    // A read that carries no metadata says nothing of its keys; a per-key
    // change merges into whatever bd holds.
    base['metadata'] = <String, Object?>{};
  }
  final JsonMap next;
  try {
    next = applyPatch(base, operation.change);
  } on PatchFailure catch (failure) {
    throw BdWriteRefused(
      AuthorityProblem(
        'validation-failed',
        title: bdPatchTitle,
        pointer: '${operation.pointer}/change',
        diagnostics: [
          {
            'instanceLocation': failure.instanceLocation,
            'message': failure.message,
          },
        ],
      ),
    );
  }
  final gate = base['issue_type'] == 'gate';
  final flags = <String>[];
  final checks = <BdDiffering>[];
  List<String>? status;
  final keys = {...base.keys, ...next.keys}.toList()..sort();
  for (final key in keys) {
    final had = base.containsKey(key);
    final has = next.containsKey(key);
    if (had == has &&
        jsonEquals(base[key], next[key]) &&
        (key != 'metadata' || named.isEmpty)) {
      continue;
    }
    final after = next[key];
    if (bdScalarFlags[key] case final flag?) {
      if (!has) throw _invalid(operation, '/change', 'bd cannot remove $key');
      flags.add('--$flag=${_scalar(operation, key, after)}');
      checks.add((served) => [if (!jsonEquals(served[key], after)) key]);
      continue;
    }
    switch (key) {
      case 'notes':
        final before = switch (base['notes']) {
          final String text => text,
          _ => '',
        };
        if (after is! String || !after.startsWith(before)) {
          throw _invalid(
            operation,
            '/change',
            'a notes change appends to the current notes and never '
                'replaces them',
          );
        }
        var rest = after.substring(before.length);
        if (before.isNotEmpty && rest.startsWith('\n')) {
          rest = rest.substring(1);
        }
        if (rest.isEmpty) {
          throw _invalid(
            operation,
            '/change',
            'the notes change appends nothing',
          );
        }
        flags.add('--append-notes=$rest');
        checks.add((served) => [if (!_holdsNote(served, rest)) 'notes']);
      case 'metadata':
        if (after is! Map<String, Object?>) {
          throw _invalid(
            operation,
            '/change',
            'metadata stays a map, merged one key at a time',
          );
        }
        final before = switch (base['metadata']) {
          final Map<String, Object?> map => map,
          _ => const <String, Object?>{},
        };
        final entries = {...before.keys, ...after.keys}.toList()..sort();
        for (final entry in entries) {
          final merged = named.contains(entry) && after.containsKey(entry);
          if (!merged &&
              before.containsKey(entry) == after.containsKey(entry) &&
              jsonEquals(before[entry], after[entry])) {
            continue;
          }
          _metadataKey(operation, entry);
          if (!after.containsKey(entry)) {
            flags.add('--unset-metadata=$entry');
            checks.add(
              (served) => [
                if (served['metadata'] case final Map<String, Object?> map
                    when map.containsKey(entry))
                  'metadata.$entry',
              ],
            );
          } else {
            final value = after[entry];
            flags.add(
              '--set-metadata=$entry=${bdMetadataValue(operation, entry, value)}',
            );
            checks.add(
              (served) => [
                if (!_holds(served['metadata'], entry, value))
                  'metadata.$entry',
              ],
            );
          }
        }
      case 'status':
        if (after is! String || after.isEmpty) {
          throw _invalid(operation, '/change', 'status is a non-empty text');
        }
        final reason = switch (next['close_reason']) {
          final String reason
              when reason.isNotEmpty &&
                  !jsonEquals(base['close_reason'], reason) =>
            reason,
          _ => null,
        };
        status = switch (after) {
          'closed' when gate => [
            'gate',
            'resolve',
            if (reason != null) '--reason=$reason',
            '--',
            id,
          ],
          'closed' when reason != null => [
            'close',
            '--reason=$reason',
            '--json',
            '--',
            id,
          ],
          _ => ['update', '--status=$after', '--json', '--', id],
        };
        checks.add((served) => [if (served['status'] != after) 'status']);
      case 'close_reason':
        if (next['status'] != 'closed' || base['status'] == 'closed') {
          throw _invalid(
            operation,
            '/change',
            'close_reason is written only by the change that closes the bead',
          );
        }
        if (after is! String || after.isEmpty) {
          throw _invalid(operation, '/change', 'close_reason is a text');
        }
        // bd keeps a gate's reason where its gate verb keeps it, so a gate's
        // close is confirmed by its status alone.
        if (!gate) {
          checks.add(
            (served) => [if (served['close_reason'] != after) 'close_reason'],
          );
        }
      default:
        throw _invalid(operation, '/change', 'bd has no write verb for $key');
    }
  }
  final calls = [
    if (flags.isNotEmpty) ['update', ...flags, '--json', '--', id],
    ?status,
  ];
  _refuseNul(operation, calls);
  return (
    calls: calls,
    differing: (served) => [for (final check in checks) ...check(served)],
  );
}

/// The guarded text update of the bead [id] when [operation]'s change is
/// exactly one `add` or `replace` at each of [bdGuardedTextFields]; null
/// when it names some other set of paths.
///
/// Throws [BdWriteRefused] when it is that change and carries no expected
/// revision, or a value that is not a text.
BdUpdatePlan? _guardedText(UpdateProperties operation, String id) {
  final change = operation.change;
  if (change.length != bdGuardedTextFields.length) return null;
  final written = <String, Object?>{};
  for (final op in change) {
    final key = _topToken(op['path']! as String);
    if (op['path'] != '/$key' ||
        !bdGuardedTextFields.containsKey(key) ||
        written.containsKey(key) ||
        (op['op'] != 'add' && op['op'] != 'replace')) {
      return null;
    }
    written[key] = op['value'];
  }
  if (operation.expectedRevision == null) {
    throw _invalid(
      operation,
      '/change',
      'the whole-text update of description, design and acceptance is made '
          'only at an expected revision',
    );
  }
  final texts = <String, String>{};
  for (final key in bdGuardedTextFields.keys) {
    final value = written[key];
    if (value is! String) {
      throw _invalid(operation, '/change', '$key is a text');
    }
    texts[key] = value;
  }
  final call = [
    'update',
    for (final MapEntry(:key, value: flag) in bdGuardedTextFields.entries)
      '--$flag=${texts[key]}',
    '--json',
    '--',
    id,
  ];
  _refuseNul(operation, [call]);
  return (
    calls: [call],
    // A read that does not carry a text field served it empty.
    differing: (served) => [
      for (final MapEntry(:key, value: text) in texts.entries)
        if (switch (served[key]) {
              final String held => held,
              _ => '',
            } !=
            text)
          key,
    ],
  );
}

/// The first token of the JSON Pointer [path], unescaped: the property a
/// change at [path] writes.
String _topToken(String path) {
  final token = path.split('/').elementAtOrNull(1) ?? '';
  return token.replaceAll('~1', '/').replaceAll('~0', '~');
}

/// The metadata key a change at [path] writes alone, unescaped; null when
/// [path] is not one key of the metadata map.
String? _metadataEntry(String path) {
  final tokens = path.split('/');
  if (tokens.length != 3 || tokens[1] != 'metadata') return null;
  return tokens[2].replaceAll('~1', '/').replaceAll('~0', '~');
}

/// The bd calls that create the bead [operation] asks for under the
/// idempotency key [key], when its Type is the bead Type.
///
/// Its external ref is the `external_ref` property when it carries one, and
/// otherwise `bdp:<key>:<operation name>`, the operation's index standing
/// for a name it does not declare. Throws [BdWriteRefused] before any call
/// for a property a create cannot carry.
BdCreatePlan planBdCreate(CreateBead operation, String key) {
  if (operation.id != null) throw _suppliedId(operation);
  final properties = operation.properties;
  for (final property in properties.keys) {
    if (!bdCreateProperties.contains(property)) {
      throw _invalid(
        operation,
        '/properties/${pointerToken(property)}',
        'a create cannot carry $property',
      );
    }
  }
  String? text(String property, {bool required = false}) {
    final value = properties[property];
    if (value == null && !required && !properties.containsKey(property)) {
      return null;
    }
    if (value is! String || (required && value.isEmpty)) {
      throw _invalid(
        operation,
        '/properties/$property',
        required ? '$property is a non-empty text' : '$property is a text',
      );
    }
    return value;
  }

  final title = text('title', required: true)!;
  final issueType = text('issue_type') ?? 'task';
  final priority = switch (properties['priority']) {
    null when !properties.containsKey('priority') => 2,
    final int priority => priority,
    _ => throw _invalid(
      operation,
      '/properties/priority',
      'priority is an integer',
    ),
  };
  final optional = {
    for (final (property, flag) in const [
      ('description', 'description'),
      ('design', 'design'),
      ('acceptance_criteria', 'acceptance'),
      ('assignee', 'assignee'),
      ('notes', 'notes'),
    ])
      if (text(property) case final value? when value.isNotEmpty)
        property: (flag, value),
  };
  final ref =
      text('external_ref') ?? 'bdp:$key:${operation.name ?? operation.index}';
  if (ref.isEmpty) {
    throw _invalid(
      operation,
      '/properties/external_ref',
      'external_ref is a non-empty text',
    );
  }
  final metadata = switch (properties['metadata']) {
    null when !properties.containsKey('metadata') => const <String, Object?>{},
    final Map<String, Object?> map => map,
    _ => throw _invalid(operation, '/properties/metadata', 'metadata is a map'),
  };
  final flags = {
    for (final MapEntry(key: entry, :value) in metadata.entries)
      _metadataKey(operation, entry): bdMetadataValue(operation, entry, value),
  };
  final create = [
    'create',
    '--title=$title',
    '--type=$issueType',
    '--priority=$priority',
    for (final (flag, value) in optional.values) '--$flag=$value',
    '--external-ref=$ref',
    '--json',
  ];
  _refuseNul(operation, [
    create,
    [for (final MapEntry(:key, :value) in flags.entries) '$key=$value'],
  ]);
  return (
    ref: ref,
    create: create,
    metadata: flags,
    differing: (served) => [
      if (served['title'] != title) 'title',
      if (served['issue_type'] != issueType) 'issue_type',
      if (!jsonEquals(served['priority'], priority)) 'priority',
      if (served['external_ref'] != ref) 'external_ref',
      for (final MapEntry(key: property, value: (_, value)) in optional.entries)
        if (property == 'notes'
            ? !_holdsNote(served, value)
            : served[property] != value)
          property,
      for (final MapEntry(key: entry, :value) in metadata.entries)
        if (!_holds(served['metadata'], entry, value)) 'metadata.$entry',
    ],
  );
}

/// The bd call that creates the gate [operation] asks for, when its Type is
/// the bead Type and its `issue_type` is `gate`: `bd gate create` blocking
/// the bead `blocks`, for `reason`, under the key `await_id`.
///
/// Its read-back holds once the gate is served as a gate under that key,
/// with a description ending in its reason, and the bead it blocks lists a
/// dependency on it. Throws [BdWriteRefused] before any call for a supplied
/// id, a property a gate's create cannot carry, and a missing or empty one.
BdGateCreatePlan planBdGateCreate(CreateBead operation) {
  if (operation.id != null) throw _suppliedId(operation);
  final properties = operation.properties;
  for (final property in properties.keys) {
    if (!bdGateCreateProperties.contains(property)) {
      throw _invalid(
        operation,
        '/properties/${pointerToken(property)}',
        "a gate's create cannot carry $property",
      );
    }
  }
  String text(String property) => switch (properties[property]) {
    final String value when value.isNotEmpty => value,
    _ => throw _invalid(
      operation,
      '/properties/$property',
      "a gate's create carries $property, a non-empty text",
    ),
  };
  final key = text('await_id');
  final blocks = text('blocks');
  final reason = text('reason');
  final create = [
    'gate',
    'create',
    '--blocks=$blocks',
    '--type=human',
    '--reason=$reason',
    '--await-id=$key',
    '--json',
  ];
  _refuseNul(operation, [create]);
  return (
    key: key,
    blocks: blocks,
    create: create,
    differing: (id, served) => [
      ...switch (served[id]) {
        null => const ['the gate itself'],
        final gate => [
          if (gate['issue_type'] != 'gate') 'issue_type',
          if (gate['await_id'] != key) 'await_id',
          if (!switch (gate['description']) {
            final String description => description.endsWith(
              '$bdGateReasonLead$reason',
            ),
            _ => false,
          })
            'reason',
        ],
      },
      if (!switch (served[blocks]?['dependencies']) {
        final List<Object?> dependencies => dependencies.any(
          (dependency) =>
              dependency is Map<String, Object?> &&
              dependency['depends_on_id'] == id,
        ),
        _ => false,
      })
        'dependencies of $blocks',
    ],
  );
}

/// The `--set-metadata` value of [value] at [key]: a text as it is, a number
/// or boolean as its JSON literal.
///
/// bd reads a value that spells a number or boolean as that number or
/// boolean, so a text that spells one is refused, as are null, a map and a
/// list, which bd cannot hold under one key.
String bdMetadataValue(Operation operation, String key, Object? value) {
  switch (value) {
    case final String text:
      final Object? read;
      try {
        read = jsonDecode(text);
      } on FormatException {
        return text;
      }
      if (read == null || read is num || read is bool) {
        throw _invalid(
          operation,
          '/change',
          'metadata $key is a text bd would read as $read',
        );
      }
      return text;
    case final num number:
      return jsonEncode(number);
    case final bool flag:
      return '$flag';
    default:
      throw _invalid(
        operation,
        '/change',
        'metadata $key is a text, a number or a boolean',
      );
  }
}

String _metadataKey(Operation operation, String key) {
  if (key.isEmpty || key.contains('=')) {
    throw _invalid(
      operation,
      '/change',
      'metadata key "$key" is empty or holds "="',
    );
  }
  return key;
}

String _scalar(Operation operation, String key, Object? value) =>
    switch ((key, value)) {
      ('priority', final int priority) => '$priority',
      ('priority', _) => throw _invalid(
        operation,
        '/change',
        'priority is an integer',
      ),
      (_, final String text) when text.isNotEmpty => text,
      _ => throw _invalid(operation, '/change', '$key is a non-empty text'),
    };

bool _holdsNote(JsonMap served, String note) => switch (served['notes']) {
  final String notes => notes.contains(note),
  _ => false,
};

bool _holds(Object? metadata, String key, Object? written) =>
    metadata is Map<String, Object?> &&
    metadata.containsKey(key) &&
    jsonEquals(metadata[key], written);

void _refuseNul(Operation operation, List<List<String>> calls) {
  for (final call in calls) {
    for (final argument in call) {
      if (argument.contains('\u0000')) {
        throw _invalid(operation, '', 'bd takes no argument holding NUL');
      }
    }
  }
}

BdWriteRefused _suppliedId(Operation operation) => BdWriteRefused(
  AuthorityProblem(
    'validation-failed',
    title: bdSuppliedIdTitle,
    pointer: '${operation.pointer}/id',
    diagnostics: [
      {'message': 'bd allocates every bead id, so a create supplies none'},
    ],
  ),
);

BdWriteRefused _invalid(Operation operation, String member, String message) =>
    BdWriteRefused(
      AuthorityProblem(
        'validation-failed',
        title: bdNoWriteTitle,
        detail: message,
        pointer: '${operation.pointer}$member',
        diagnostics: [
          {'message': message},
        ],
      ),
    );
