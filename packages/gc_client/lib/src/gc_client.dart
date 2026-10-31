import 'exceptions.dart';
import 'model.dart';

/// A Gas City store and its mail, behind one seam: every store read, store
/// write and mail a deterministic seat makes goes through one of these
/// members.
///
/// A member completes with its answer, or fails with a
/// [GcTransportException] when the store could not be reached or answered
/// with something unreadable (transient: the same call may succeed later),
/// or with a [GcRefusal] when the store answered and refused (hard: the same
/// call will be refused again). The one exception is [sling], which
/// completes with gc's exit status whatever gc did, since gc has already told
/// the caller.
abstract interface class GcClient {
  /// The bead [id].
  Future<Bead> showBead(String id);

  /// Sets each key of [metadata] on bead [id] to its value, in the order of
  /// [metadata].
  ///
  /// Throws an [ArgumentError], before anything is written, when [metadata]
  /// is empty or one of its keys is empty or holds a `=`.
  Future<void> updateMetadata(String id, Map<String, String> metadata);

  /// Appends [text] to the notes of bead [id].
  Future<void> appendNotes(String id, String text);

  /// Closes bead [id] with [outcome]: it sets `gc.outcome`, and for a
  /// [Failed] outcome `gc.failure_class` and `gc.failure_reason`, the reason
  /// on one line (each newline a space) of at most 400 characters.
  Future<void> closeBead(String id, Outcome outcome);

  /// Hands claimed bead [id] back: restores its [status] and clears its
  /// assignee, overriding the live claim.
  Future<void> release(String id, {required String status});

  /// The convoy [convoyId] and its children.
  Future<Convoy> convoyStatus(String convoyId);

  /// Mails [subject] and [body] to [to].
  Future<void> mail(String to, String subject, String body);

  /// Claims one routed work item for the calling session, or reports that
  /// there is none. With [drainAck], a drain is acknowledged as well.
  Future<HookClaim> claimHook({bool drainAck = false});

  /// Every bead, open or closed, whose `gc.root_bead_id` is [rootId]: the
  /// steps of one workflow.
  Future<List<Bead>> listByRoot(String rootId);

  /// At most [limit] beads that match [query].
  Future<List<Bead>> searchBeads(String query, {required int limit});

  /// Runs `gc sling` with [args] and completes with gc's exit status: gc
  /// reads the caller's stdin and writes to the caller's stdout and stderr,
  /// as the shell's `exec` hands them over, so the caller sees what gc
  /// slung, or why it did not, as gc prints it.
  ///
  /// Fails with a [GcTransportException] only when gc cannot start.
  Future<int> sling(List<String> args);
}
