import 'package:meta/meta.dart';

import 'json.dart';

/// The supervisor's health (`GET /health`, `SupervisorHealthOutputBody`).
@immutable
final class SupervisorHealth {
  const SupervisorHealth({
    required this.status,
    required this.version,
    required this.uptime,
    required this.citiesTotal,
    required this.citiesRunning,
    this.buildId,
    this.startup,
  });

  factory SupervisorHealth.fromJson(Object? json) {
    final r = JsonFields.of(json, 'health');
    return SupervisorHealth(
      status: r.string('status'),
      version: r.string('version'),
      uptime: Duration(seconds: r.integer('uptime_sec')),
      citiesTotal: r.integer('cities_total'),
      citiesRunning: r.integer('cities_running'),
      buildId: r.optionalString('build_id'),
      startup: switch (r.optionalObject('startup')) {
        final startup? => SupervisorStartup._(startup),
        null => null,
      },
    );
  }

  /// `ok` when the supervisor is healthy.
  final String status;

  /// The gc version the supervisor runs, e.g. `1.5.1`.
  final String version;

  final Duration uptime;

  final int citiesTotal;

  final int citiesRunning;

  final String? buildId;

  final SupervisorStartup? startup;
}

/// How far the supervisor's startup has come (`SupervisorStartup`).
@immutable
final class SupervisorStartup {
  SupervisorStartup._(JsonFields r)
    : ready = r.boolean('ready'),
      phase = r.optionalString('phase'),
      phasesCompleted = r.strings('phases_completed');

  final bool ready;

  /// The phase it is in, e.g. `running`.
  final String? phase;

  final List<String> phasesCompleted;
}

/// A city the supervisor manages (`GET /v0/cities`, `CityInfo`).
@immutable
final class CityInfo {
  const CityInfo({
    required this.name,
    required this.path,
    required this.running,
    this.status,
    this.error,
  });

  factory CityInfo.fromJson(Object? json) {
    final r = JsonFields.of(json, 'city');
    return CityInfo(
      name: r.string('name'),
      path: r.string('path'),
      running: r.boolean('running'),
      status: r.optionalString('status'),
      error: r.optionalString('error'),
    );
  }

  /// The name every per-city route is addressed by.
  final String name;

  /// The city's directory on the supervisor's host.
  final String path;

  final bool running;

  final String? status;

  /// Why the city is not running, when the supervisor knows.
  final String? error;
}

/// A city's status (`GET /v0/city/{name}/status`, `StatusBody`).
///
/// The counts are typed; the rest of the body (per-agent, per-rig and store
/// detail) is in [json].
@immutable
final class CityStatus {
  CityStatus._(JsonFields r)
    : json = r.json,
      name = r.string('name'),
      path = r.string('path'),
      version = r.optionalString('version'),
      uptime = Duration(seconds: r.integer('uptime_sec')),
      suspended = r.boolean('suspended'),
      running = r.integer('running'),
      agents = AgentCounts._(r.object('agents')),
      rigs = RigCounts._(r.object('rigs')),
      work = WorkCounts._(r.object('work')),
      mail = MailCounts._(r.object('mail')),
      beadsVersion = r.optionalString('beads_version'),
      doltVersion = r.optionalString('dolt_version'),
      partial = r.optionalBoolean('partial') ?? false,
      partialErrors = r.strings('partial_errors');

  factory CityStatus.fromJson(Object? json) =>
      CityStatus._(JsonFields.of(json, 'status'));

  /// The whole body as the server wrote it.
  final Map<String, Object?> json;

  final String name;

  final String path;

  final String? version;

  final Duration uptime;

  final bool suspended;

  /// The number of sessions running.
  final int running;

  final AgentCounts agents;

  final RigCounts rigs;

  final WorkCounts work;

  final MailCounts mail;

  final String? beadsVersion;

  final String? doltVersion;

  /// Whether some part of the status could not be read; [partialErrors] says
  /// which. The counts that were read are still exact.
  final bool partial;

  final List<String> partialErrors;
}

/// `StatusAgentCounts`.
@immutable
final class AgentCounts {
  AgentCounts._(JsonFields r)
    : total = r.integer('total'),
      running = r.integer('running'),
      suspended = r.integer('suspended'),
      quarantined = r.integer('quarantined');

  final int total;
  final int running;
  final int suspended;
  final int quarantined;
}

/// `StatusRigCounts`.
@immutable
final class RigCounts {
  RigCounts._(JsonFields r)
    : total = r.integer('total'),
      suspended = r.integer('suspended');

  final int total;
  final int suspended;
}

/// `StatusWorkCounts`.
@immutable
final class WorkCounts {
  WorkCounts._(JsonFields r)
    : open = r.integer('open'),
      ready = r.integer('ready'),
      inProgress = r.integer('in_progress');

  final int open;
  final int ready;
  final int inProgress;
}

/// `StatusMailCounts`.
@immutable
final class MailCounts {
  MailCounts._(JsonFields r)
    : total = r.integer('total'),
      unread = r.integer('unread');

  final int total;
  final int unread;
}

/// One entry of a city's event log, from a page of it or its stream
/// (`TypedEventStreamEnvelope`).
///
/// [type] names the event (`bead.created`, `order.completed`, ...) and fixes
/// the shape of [payload], which is kept as the server wrote it.
@immutable
final class GcEvent {
  GcEvent._(JsonFields r)
    : json = r.json,
      seq = r.integer('seq'),
      type = r.string('type'),
      ts = r.instant('ts'),
      actor = r.string('actor'),
      subject = r.optionalString('subject'),
      message = r.optionalString('message'),
      runId = r.optionalString('run_id'),
      sessionId = r.optionalString('session_id'),
      stepId = r.optionalString('step_id'),
      payload = r.optionalObject('payload')?.json ?? const {};

  factory GcEvent.fromJson(Object? json) =>
      GcEvent._(JsonFields.of(json, 'event'));

  /// The envelope as the server wrote it, its workflow projection included.
  final Map<String, Object?> json;

  /// The event's position in the city's log: strictly increasing.
  final int seq;

  final String type;

  final DateTime ts;

  /// Who or what caused it, e.g. `controller`.
  final String actor;

  /// What it is about, e.g. a bead id or an order name.
  final String? subject;

  final String? message;

  final String? runId;

  final String? sessionId;

  final String? stepId;

  final Map<String, Object?> payload;

  @override
  String toString() => 'GcEvent($seq $type $subject)';
}

/// One page of a city's event log, newest first (`ListBodyWireEvent`).
@immutable
final class EventPage {
  EventPage._(JsonFields r)
    : events = [for (final item in r.list('items')) GcEvent.fromJson(item)],
      total = r.integer('total'),
      nextCursor = switch (r.optionalString('next_cursor')) {
        '' => null,
        final cursor => cursor,
      },
      partial = r.optionalBoolean('partial') ?? false,
      partialErrors = r.strings('partial_errors');

  factory EventPage.fromJson(Object? json) =>
      EventPage._(JsonFields.of(json, 'events'));

  final List<GcEvent> events;

  /// The number of events in the log that match the query.
  final int total;

  /// The cursor of the next, older page; null on the last page.
  final String? nextCursor;

  final bool partial;

  final List<String> partialErrors;
}
