import 'dart:collection';
import 'dart:io';

import 'command.dart';
import 'exceptions.dart';
import 'gc_client.dart';
import 'model.dart';

/// An in-process [GcClient] for tests. It answers from a fixture directory
/// laid out as the bash fake gc (`tests/lib/fake-gc.sh`) reads its
/// `GC_FIXTURES`, fails where that fake fails, with the same stderr read the
/// same way, and records every store write and mail in [mutations] without
/// ever applying one, so a later read still serves the fixture.
///
/// * [showBead] serves `<fixtures>/<id>.json`, an array holding the bead or
///   the bead object itself.
/// * [convoyStatus] serves `<fixtures>/convoy-<id>.json`.
/// * [listByRoot] serves `<fixtures>/list-<root>.json` and [searchBeads]
///   `<fixtures>/search-<query>.json`, each an empty answer when the file is
///   missing; a `.fail` file beside it fails the read with its text as
///   stderr.
/// * A missing bead or convoy fixture fails with the fake's own words.
/// * A write to an id in [refuseWrites] is recorded, then refused.
/// * [claimHook] answers with [claims] in order: a [HookClaim] is returned
///   and a [GcException] thrown; once they run out it drains with reason
///   `no_work`, acknowledged when it was asked to be.
/// * [sling] records a [Slung] and answers [slingExitCode], as the bash fake
///   logs `sling <args>` and exits `FAKE_GC_SLING_RC`.
final class FakeGcClient implements GcClient {
  /// Creates the fake over the fixture directory [fixtures]. Each of [claims]
  /// must be a [HookClaim] or a [GcException]; anything else is an
  /// [ArgumentError].
  FakeGcClient(
    this.fixtures, {
    Iterable<Object> claims = const [],
    this.refuseWrites = const {},
    this.slingExitCode = 0,
  }) : _claims = Queue.of(claims) {
    for (final claim in _claims) {
      if (claim is! HookClaim && claim is! GcException) {
        throw ArgumentError.value(
          claim,
          'claims',
          'is neither a HookClaim nor a GcException',
        );
      }
    }
  }

  /// The fixture directory, as `GC_FIXTURES` names it to the bash fake.
  final String fixtures;

  /// The bead ids whose writes are refused, as `FAKE_GC_FAIL_UPDATE` refuses
  /// them in the bash fake.
  final Set<String> refuseWrites;

  /// The exit status [sling] answers with, as `FAKE_GC_SLING_RC` sets the
  /// bash fake's.
  final int slingExitCode;

  /// Every store write and mail so far, in call order.
  final List<GcMutation> mutations = [];

  final Queue<Object> _claims;

  @override
  Future<Bead> showBead(String id) async {
    final args = showArgs(id);
    final file = File('$fixtures/$id.json');
    if (!file.existsSync()) {
      throw gcFailure(
        args,
        1,
        'fake-gc: no fixture for bead $id (looked in ${file.path})\n',
      );
    }
    return readBead(args, file.readAsStringSync());
  }

  @override
  Future<void> updateMetadata(String id, Map<String, String> metadata) =>
      _write(id, metadataArgs(id, metadata), MetadataUpdated(id, metadata));

  @override
  Future<void> appendNotes(String id, String text) =>
      _write(id, notesArgs(id, text), NotesAppended(id, text));

  @override
  Future<void> closeBead(String id, Outcome outcome) => _write(
    id,
    closeArgs(id, outcome),
    BeadClosed(id, switch (outcome) {
      Passed() => outcome,
      Failed(:final failureClass, :final reason) => Failed(
        failureClass,
        failureReason(reason),
      ),
    }),
  );

  @override
  Future<void> release(String id, {required String status}) =>
      _write(id, releaseArgs(id, status), BeadReleased(id, status));

  @override
  Future<Convoy> convoyStatus(String convoyId) async {
    final args = convoyArgs(convoyId);
    final file = File('$fixtures/convoy-$convoyId.json');
    if (!file.existsSync()) {
      throw gcFailure(
        args,
        1,
        'fake-gc: no fixture for convoy $convoyId (looked in ${file.path})\n',
      );
    }
    return readConvoy(convoyId, args, file.readAsStringSync());
  }

  @override
  Future<void> mail(String to, String subject, String body) async {
    mutations.add(MailSent(to, subject, body));
  }

  @override
  Future<HookClaim> claimHook({bool drainAck = false}) async {
    mutations.add(HookClaimed(drainAck: drainAck));
    if (_claims.isEmpty) {
      return HookDrain(reason: 'no_work', drainAcknowledged: drainAck);
    }
    final claim = _claims.removeFirst();
    if (claim is GcException) throw claim;
    return claim as HookClaim;
  }

  @override
  Future<List<Bead>> listByRoot(String rootId) async =>
      _read(listArgs(rootId), 'list-$rootId', '{"issues":[]}\n');

  @override
  Future<List<Bead>> searchBeads(String query, {required int limit}) async =>
      _read(searchArgs(query, limit), 'search-$query', '[]\n');

  @override
  Future<int> sling(List<String> args) async {
    mutations.add(Slung(args));
    return slingExitCode;
  }

  /// The beads of fixture `<name>.json`, or of [missing] when there is none;
  /// fails as gc exiting 1 when `<name>.fail` exists.
  List<Bead> _read(List<String> args, String name, String missing) {
    final fail = File('$fixtures/$name.fail');
    if (fail.existsSync()) throw gcFailure(args, 1, fail.readAsStringSync());
    final file = File('$fixtures/$name.json');
    return readBeads(
      args,
      file.existsSync() ? file.readAsStringSync() : missing,
    );
  }

  /// Records [mutation]; then refuses it, as `gc bd update` exiting 1, when
  /// [id] is in [refuseWrites].
  Future<void> _write(String id, List<String> args, GcMutation mutation) async {
    mutations.add(mutation);
    if (refuseWrites.contains(id)) throw gcFailure(args, 1, '');
  }
}

/// A store write or mail a [FakeGcClient] recorded.
sealed class GcMutation {
  const GcMutation();
}

/// [GcClient.updateMetadata] set [metadata] on bead [id].
final class MetadataUpdated extends GcMutation {
  /// Records [metadata], in its order, set on bead [id].
  MetadataUpdated(this.id, Map<String, String> metadata)
    : metadata = Map.unmodifiable(metadata);

  /// The bead written to.
  final String id;

  /// The keys and values set, in the order they were set.
  final Map<String, String> metadata;

  @override
  bool operator ==(Object other) =>
      other is MetadataUpdated &&
      other.id == id &&
      other.metadata.length == metadata.length &&
      _pairs(other.metadata).join('\n') == _pairs(metadata).join('\n');

  @override
  int get hashCode => Object.hash(id, Object.hashAll(_pairs(metadata)));

  @override
  String toString() => 'MetadataUpdated($id, $metadata)';
}

/// [GcClient.appendNotes] appended [text] to bead [id].
final class NotesAppended extends GcMutation {
  /// Records [text] appended to bead [id].
  const NotesAppended(this.id, this.text);

  /// The bead written to.
  final String id;

  /// The text appended.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is NotesAppended && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);

  @override
  String toString() => 'NotesAppended($id, $text)';
}

/// [GcClient.closeBead] closed bead [id] with [outcome], a failure's reason
/// as the store receives it: on one line, at most 400 characters.
final class BeadClosed extends GcMutation {
  /// Records bead [id] closed with [outcome].
  const BeadClosed(this.id, this.outcome);

  /// The bead closed.
  final String id;

  /// The outcome it was closed with.
  final Outcome outcome;

  @override
  bool operator ==(Object other) =>
      other is BeadClosed && other.id == id && other.outcome == outcome;

  @override
  int get hashCode => Object.hash(id, outcome);

  @override
  String toString() => 'BeadClosed($id, $outcome)';
}

/// [GcClient.release] handed bead [id] back with [status].
final class BeadReleased extends GcMutation {
  /// Records bead [id] released with [status].
  const BeadReleased(this.id, this.status);

  /// The bead released.
  final String id;

  /// The status restored.
  final String status;

  @override
  bool operator ==(Object other) =>
      other is BeadReleased && other.id == id && other.status == status;

  @override
  int get hashCode => Object.hash(id, status);

  @override
  String toString() => 'BeadReleased($id, $status)';
}

/// [GcClient.mail] mailed [subject] and [body] to [to].
final class MailSent extends GcMutation {
  /// Records [subject] and [body] mailed to [to].
  const MailSent(this.to, this.subject, this.body);

  /// The recipient.
  final String to;

  /// The subject.
  final String subject;

  /// The body.
  final String body;

  @override
  bool operator ==(Object other) =>
      other is MailSent &&
      other.to == to &&
      other.subject == subject &&
      other.body == body;

  @override
  int get hashCode => Object.hash(to, subject, body);

  @override
  String toString() => 'MailSent($to, $subject, $body)';
}

/// [GcClient.claimHook] was called, with [drainAck].
final class HookClaimed extends GcMutation {
  /// Records a claim, acknowledging a drain when [drainAck] is true.
  const HookClaimed({this.drainAck = false});

  /// Whether the claim asked gc to acknowledge a drain.
  final bool drainAck;

  @override
  bool operator ==(Object other) =>
      other is HookClaimed && other.drainAck == drainAck;

  @override
  int get hashCode => drainAck.hashCode;

  @override
  String toString() => 'HookClaimed(drainAck: $drainAck)';
}

/// [GcClient.sling] ran `gc sling` with [args].
final class Slung extends GcMutation {
  /// Records `gc sling` run with [args], in their order.
  Slung(List<String> args) : args = List.unmodifiable(args);

  /// The arguments after `gc sling`, in order.
  final List<String> args;

  @override
  bool operator ==(Object other) =>
      other is Slung &&
      other.args.length == args.length &&
      [
        for (var i = 0; i < args.length; i++) other.args[i] == args[i],
      ].every((same) => same);

  @override
  int get hashCode => Object.hashAll(args);

  @override
  String toString() => 'Slung($args)';
}

Iterable<String> _pairs(Map<String, String> metadata) => [
  for (final MapEntry(:key, :value) in metadata.entries) '$key=$value',
];
