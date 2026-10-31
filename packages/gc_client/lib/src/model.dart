import 'dart:convert';

/// A bead as the store shows it: the fields a seat reads, and its metadata.
final class Bead {
  /// Creates bead [id]; a field the store does not show is empty.
  const Bead({
    required this.id,
    this.title = '',
    this.description = '',
    this.design = '',
    this.acceptanceCriteria = '',
    this.notes = '',
    this.status = '',
    this.issueType = '',
    this.startedAt,
    this.closedAt,
    this.metadata = const {},
  });

  /// Reads one bead object as `gc bd show --json` (inside its array),
  /// `gc bd list --json` and `gc bd search --json` print it; null when [json]
  /// is not an object with a non-empty string `id`.
  static Bead? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final metadata = json['metadata'];
    return Bead(
      id: id,
      title: _string(json['title']),
      description: _string(json['description']),
      design: _string(json['design']),
      acceptanceCriteria: _string(json['acceptance_criteria']),
      notes: _string(json['notes']),
      status: _string(json['status']),
      issueType: _string(json['issue_type']),
      startedAt: _stringOrNull(json['started_at']),
      closedAt: _stringOrNull(json['closed_at']),
      metadata: {
        if (metadata is Map<String, Object?>)
          for (final MapEntry(:key, :value) in metadata.entries)
            if (value != null) key: value is String ? value : jsonEncode(value),
      },
    );
  }

  /// The bead's id.
  final String id;

  /// The title.
  final String title;

  /// The description.
  final String description;

  /// The design.
  final String design;

  /// The acceptance criteria (`acceptance_criteria`).
  final String acceptanceCriteria;

  /// The notes.
  final String notes;

  /// The status, such as `open`, `in_progress` or `closed`.
  final String status;

  /// The issue type (`issue_type`), such as `task`.
  final String issueType;

  /// When the bead was started (`started_at`), as the store prints it.
  final String? startedAt;

  /// When the bead was closed (`closed_at`), as the store prints it.
  final String? closedAt;

  /// The metadata, each value as text: a string as itself, any other value
  /// as its JSON text (`1`, `true`, `["a","b"]`). A `null` value is left out.
  final Map<String, String> metadata;
}

/// A convoy as `gc convoy status --json` shows it: its id and its children.
final class Convoy {
  /// Creates convoy [id] with the bead ids of its [children].
  const Convoy({required this.id, required this.children});

  /// Reads convoy [convoyId] from the object `gc convoy status --json`
  /// prints; null when [json] is not an object, or its `children` is not
  /// absent, null or a list of objects that each carry a non-empty string
  /// `id`.
  static Convoy? fromJson(String convoyId, Object? json) {
    if (json is! Map<String, Object?>) return null;
    final children = json['children'] ?? const <Object?>[];
    if (children is! List<Object?>) return null;
    final ids = <String>[];
    for (final child in children) {
      final id = child is Map<String, Object?> ? child['id'] : null;
      if (id is! String || id.isEmpty) return null;
      ids.add(id);
    }
    return Convoy(id: convoyId, children: ids);
  }

  /// The convoy's id.
  final String id;

  /// The bead ids of the convoy's children, in the order gc lists them.
  final List<String> children;

  /// The id of the convoy's only child, or null when it has none or several:
  /// the bead a one-bead convoy carries.
  String? get soleChild => children.length == 1 ? children.single : null;
}

/// What `gc hook --claim --json` answers: [HookWork] or [HookDrain].
sealed class HookClaim {
  const HookClaim(this.reason);

  /// Reads the result object `gc hook --claim --json` prints; null when
  /// [json] is not one: an object with `ok: true` and an `action` of `work`,
  /// with a non-empty string `bead_id`, or of `drain`.
  static HookClaim? fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['ok'] != true) return null;
    final reason = _string(json['reason']);
    switch (json['action']) {
      case 'work':
        final beadId = json['bead_id'];
        if (beadId is! String || beadId.isEmpty) return null;
        return HookWork(
          beadId: beadId,
          assignee: _string(json['assignee']),
          reason: reason,
          route: _stringOrNull(json['route']),
          rootBeadId: _stringOrNull(json['root_bead_id']),
        );
      case 'drain':
        return HookDrain(
          reason: reason,
          drainAcknowledged: json['drain_acknowledged'] == true,
        );
    }
    return null;
  }

  /// Why gc answered so, such as `claimed`, `existing_assignment` or
  /// `no_work`.
  final String reason;
}

/// A routed work item claimed for the session: bead [beadId].
final class HookWork extends HookClaim {
  /// Creates the claim of [beadId] by [assignee], for [reason].
  const HookWork({
    required this.beadId,
    required this.assignee,
    required String reason,
    this.route,
    this.rootBeadId,
  }) : super(reason);

  /// The claimed bead.
  final String beadId;

  /// Who holds the claim.
  final String assignee;

  /// The route the bead was claimed on, when gc names one.
  final String? route;

  /// The root of the claimed bead's workflow, when gc names one.
  final String? rootBeadId;

  @override
  bool operator ==(Object other) =>
      other is HookWork &&
      other.beadId == beadId &&
      other.assignee == assignee &&
      other.reason == reason &&
      other.route == route &&
      other.rootBeadId == rootBeadId;

  @override
  int get hashCode => Object.hash(beadId, assignee, reason, route, rootBeadId);

  @override
  String toString() =>
      'HookWork($beadId, assignee: $assignee, reason: $reason, '
      'route: $route, rootBeadId: $rootBeadId)';
}

/// No work for the session: it should drain.
final class HookDrain extends HookClaim {
  /// Creates the drain answer for [reason].
  const HookDrain({required String reason, this.drainAcknowledged = false})
    : super(reason);

  /// Whether gc acknowledged the drain, which it does only for `--drain-ack`.
  final bool drainAcknowledged;

  @override
  bool operator ==(Object other) =>
      other is HookDrain &&
      other.reason == reason &&
      other.drainAcknowledged == drainAcknowledged;

  @override
  int get hashCode => Object.hash(reason, drainAcknowledged);

  @override
  String toString() =>
      'HookDrain(reason: $reason, drainAcknowledged: $drainAcknowledged)';
}

/// How a step bead closes: [Passed] or [Failed].
sealed class Outcome {
  const Outcome();
}

/// The step passed: `gc.outcome=pass`.
final class Passed extends Outcome {
  /// Creates the pass outcome.
  const Passed();

  @override
  bool operator ==(Object other) => other is Passed;

  @override
  int get hashCode => (Passed).hashCode;

  @override
  String toString() => 'Passed()';
}

/// The step failed: `gc.outcome=fail`, its [failureClass] and its [reason].
final class Failed extends Outcome {
  /// Creates the failure of [failureClass] for [reason].
  const Failed(this.failureClass, this.reason);

  /// Whether a retry may pass (`gc.failure_class`).
  final FailureClass failureClass;

  /// Why the step failed (`gc.failure_reason`).
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is Failed &&
      other.failureClass == failureClass &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(failureClass, reason);

  @override
  String toString() => 'Failed(${failureClass.name}, $reason)';
}

/// Whether a failed step may pass when it is run again.
enum FailureClass {
  /// `hard`: run again, the step fails the same way.
  hard,

  /// `transient`: run again, the step may pass.
  transient,
}

String _string(Object? value) => value is String ? value : '';

String? _stringOrNull(Object? value) => value is String ? value : null;
