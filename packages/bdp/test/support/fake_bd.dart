// A bd that answers from memory, for tests that need no bd on the PATH. It
// keeps rows as `bd list --json` prints them, answers the verbs the bd
// authority calls, its gate, label and ship verbs among them, the way bd 1.3
// prints them, and records every call.
import 'dart:convert';

import 'package:bdp/bd.dart';

typedef Row = Map<String, Object?>;

/// A scripted bd over an in-memory store.
final class FakeBd implements BdCli {
  /// The rows `bd list --json` prints, in id order.
  final List<Row> rows = [];

  /// What `bd config list --json` prints.
  Map<String, Object?> config = {'issue_prefix': 't'};

  /// The line `bd version` prints.
  String versionLine = 'bd version 1.3.2 (fake)';

  /// Every call's arguments, in order.
  final List<List<String>> calls = [];

  /// Answers a call before the store does; null passes it on.
  BdOutput? Function(List<String> arguments)? intercept;

  var _next = 0;

  /// The calls that write: every one but `list`, `config` and `version`.
  List<List<String>> get writes => [
    for (final call in calls)
      if (!const {'list', 'config', 'version'}.contains(call.first)) call,
  ];

  /// Adds a bead as another actor would, answering its row.
  Row add(String id, {String title = 'A bead', Map<String, Object?>? also}) {
    final row = <String, Object?>{
      'id': id,
      'title': title,
      'status': 'open',
      'priority': 2,
      'issue_type': 'task',
      'updated_at': '2026-10-26T12:00:00Z',
      'dependency_count': 0,
      ...?also,
    };
    rows
      ..add(row)
      ..sort((a, b) => (a['id']! as String).compareTo(b['id']! as String));
    return row;
  }

  /// The row of [id].
  Row row(String id) => rows.singleWhere((row) => row['id'] == id);

  @override
  Future<BdOutput> run(List<String> arguments) async {
    for (final argument in arguments) {
      if (argument.contains('\u0000')) {
        throw ArgumentError.value(arguments, 'arguments', 'holds NUL');
      }
    }
    calls.add(List.of(arguments));
    if (intercept?.call(arguments) case final answer?) return answer;
    return switch (arguments.first) {
      'version' => BdOutput(exitCode: 0, stdout: '$versionLine\n'),
      'config' => _ok(config),
      'list' => _list(arguments),
      'create' => _create(arguments),
      'update' => _update(arguments),
      'close' => _close(arguments),
      'gate' => _gate(arguments),
      'label' => _label(arguments),
      'ship' => _ship(arguments),
      _ => _error('unknown command "${arguments.first}"'),
    };
  }

  /// `bd label add`, refusing the `provides:` prefix bd reserves to its ship
  /// verb, in bd 1.3.2's own words.
  BdOutput _label(List<String> arguments) {
    if (arguments.elementAtOrNull(1) != 'add') {
      return _error('unknown label command');
    }
    final id = _subject(arguments);
    final label = arguments.last;
    final found = rows.where((row) => row['id'] == id).firstOrNull;
    if (found == null) return _error('issue not found: $id');
    if (label.startsWith('provides:')) {
      return _error(
        "'provides:' labels are reserved for cross-project capabilities. "
        "Hint: use 'bd ship ${label.substring('provides:'.length)}' instead",
      );
    }
    _addLabel(found, label);
    return _ok([
      {'status': 'added', 'issue_id': id, 'label': label},
    ]);
  }

  /// `bd ship`: labels the closed bead holding `export:<cap>` with
  /// `provides:<cap>`, an open one only under `--force`.
  BdOutput _ship(List<String> arguments) {
    final capability = _subject(arguments);
    final holder = rows
        .where(
          (row) => [
            ...?row['labels'] as List<Object?>?,
          ].contains('export:$capability'),
        )
        .firstOrNull;
    if (holder == null) {
      return _error('no issue found with export:$capability label');
    }
    if (holder['status'] != 'closed' && !arguments.contains('--force')) {
      return _error(
        'issue ${holder['id']} is not closed (status: ${holder['status']})',
      );
    }
    _addLabel(holder, 'provides:$capability');
    return _ok({
      'status': 'shipped',
      'capability': capability,
      'issue_id': holder['id'],
    });
  }

  void _addLabel(Row row, String label) {
    final labels = [...?row['labels'] as List<Object?>?];
    if (!labels.contains(label)) labels.add(label);
    row['labels'] = labels;
    _touch(row);
  }

  static BdOutput _ok(Object? json) =>
      BdOutput(exitCode: 0, stdout: jsonEncode(json));

  /// bd's error envelope on stdout, stderr empty.
  static BdOutput _error(String error) =>
      BdOutput(exitCode: 1, stdout: jsonEncode({'error': error}));

  static String? _flag(List<String> arguments, String flag) {
    for (final argument in arguments) {
      if (argument.startsWith('--$flag=')) {
        return argument.substring(flag.length + 3);
      }
    }
    return null;
  }

  static List<String> _flags(List<String> arguments, String flag) => [
    for (final argument in arguments)
      if (argument.startsWith('--$flag=')) argument.substring(flag.length + 3),
  ];

  static String? _subject(List<String> arguments) {
    final at = arguments.indexOf('--');
    return at < 0 || at == arguments.length - 1 ? null : arguments[at + 1];
  }

  BdOutput _list(List<String> arguments) {
    final ref = _flag(arguments, 'external-ref');
    return _ok([
      for (final row in rows)
        if (ref == null || row['external_ref'] == ref) row,
    ]);
  }

  String _nextId() => 't-${(_next++).toRadixString(36).padLeft(3, '0')}';

  /// `bd gate create`, printing the gate as one object, and `bd gate
  /// resolve`, printing plain text, as bd 1.3 does.
  BdOutput _gate(List<String> arguments) {
    switch (arguments.elementAtOrNull(1)) {
      case 'create':
        final work = _flag(arguments, 'blocks');
        final blocked = rows.where((row) => row['id'] == work).firstOrNull;
        if (blocked == null) return _error('issue not found: $work');
        final id = _nextId();
        final gate = add(
          id,
          title: 'Gate: human',
          also: {
            'issue_type': 'gate',
            'await_type': _flag(arguments, 'type') ?? 'human',
            'await_id': ?_flag(arguments, 'await-id'),
            'description':
                'Ad-hoc gate blocking $work\n\n'
                'Reason: ${_flag(arguments, 'reason') ?? ''}',
          },
        );
        final dependencies = [
          ...?blocked['dependencies'] as List<Object?>?,
          {'issue_id': work, 'depends_on_id': id, 'type': 'blocks'},
        ];
        blocked
          ..['dependencies'] = dependencies
          ..['dependency_count'] = dependencies.length;
        _touch(blocked);
        return _ok(gate);
      case 'resolve':
        final id = _subject(arguments);
        final found = rows.where((row) => row['id'] == id).firstOrNull;
        if (found == null) return _error('issue not found: $id');
        found['status'] = 'closed';
        if (_flag(arguments, 'reason') case final reason?) {
          found['close_reason'] = reason;
        }
        _touch(found);
        return BdOutput(exitCode: 0, stdout: 'Gate $id resolved\n');
      default:
        return _error('unknown gate command');
    }
  }

  BdOutput _create(List<String> arguments) {
    final id = _nextId();
    final row = add(
      id,
      title: _flag(arguments, 'title') ?? '',
      also: {
        'issue_type': _flag(arguments, 'type') ?? 'task',
        'priority': int.parse(_flag(arguments, 'priority') ?? '2'),
        'description': ?_flag(arguments, 'description'),
        'design': ?_flag(arguments, 'design'),
        'acceptance_criteria': ?_flag(arguments, 'acceptance'),
        'notes': ?_flag(arguments, 'notes'),
        'assignee': ?_flag(arguments, 'assignee'),
        'external_ref': ?_flag(arguments, 'external-ref'),
      },
    );
    return _ok(row);
  }

  BdOutput _update(List<String> arguments) {
    final id = _subject(arguments);
    final found = rows.where((row) => row['id'] == id).firstOrNull;
    if (found == null) return _error('issue not found: $id');
    for (final (flag, key) in const [
      ('title', 'title'),
      ('description', 'description'),
      ('design', 'design'),
      ('acceptance', 'acceptance_criteria'),
      ('type', 'issue_type'),
      ('assignee', 'assignee'),
      ('external-ref', 'external_ref'),
      ('status', 'status'),
    ]) {
      if (_flag(arguments, flag) case final value?) found[key] = value;
    }
    if (_flag(arguments, 'priority') case final value?) {
      found['priority'] = int.parse(value);
    }
    if (_flag(arguments, 'append-notes') case final text?) {
      final notes = found['notes'] as String? ?? '';
      found['notes'] = notes.isEmpty ? text : '$notes\n$text';
    }
    final metadata = {...?found['metadata'] as Map<String, Object?>?};
    for (final entry in _flags(arguments, 'set-metadata')) {
      final at = entry.indexOf('=');
      final text = entry.substring(at + 1);
      Object? value;
      try {
        value = jsonDecode(text);
      } on FormatException {
        value = text;
      }
      metadata[entry.substring(0, at)] = value;
    }
    for (final key in _flags(arguments, 'unset-metadata')) {
      metadata.remove(key);
    }
    if (metadata.isEmpty) {
      found.remove('metadata');
    } else {
      found['metadata'] = metadata;
    }
    _touch(found);
    return _ok([found]);
  }

  BdOutput _close(List<String> arguments) {
    final id = _subject(arguments);
    final found = rows.where((row) => row['id'] == id).firstOrNull;
    if (found == null) return _error('issue not found: $id');
    found['status'] = 'closed';
    if (_flag(arguments, 'reason') case final reason?) {
      found['close_reason'] = reason;
    }
    _touch(found);
    return _ok([found]);
  }

  var _tick = 0;

  void _touch(Row row) => row['updated_at'] =
      '2026-10-26T12:${(++_tick).toString().padLeft(2, '0')}:00Z';
}
