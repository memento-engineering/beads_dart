import 'package:meta/meta.dart';

import 'changefeed.dart';
import 'records.dart';
import 'snapshot.dart';
import 'tokens.dart';

/// Why a replica refused a snapshot, a page or a change group.
enum ReplicationFault {
  /// The input belongs to another Scope.
  foreignScope,

  /// The input belongs to another Scope epoch: a fresh snapshot is needed.
  foreignEpoch,

  /// The input is projected for another Authorization View: a fresh
  /// snapshot is needed.
  foreignView,

  /// The group does not continue from the replica's position: a gap, a
  /// duplicate or a reordering.
  positionMismatch,

  /// The group names one Resource in more than one `changes` entry.
  duplicateChange,

  /// A source's inline owned Link disagrees with the Link's own record.
  ownedLinkDisagreement,

  /// A Link's in-Scope endpoint Bead is absent from the projection.
  missingEndpoint,

  /// A version an erasure record names is still held as live state.
  erasedStateRetained,
}

/// A replica refused input as an authority fault or a fence; nothing was
/// applied.
final class ReplicationException implements Exception {
  /// A refusal for [fault].
  const ReplicationException(this.fault, this.message);

  /// The kind of refusal.
  final ReplicationFault fault;

  /// What was wrong.
  final String message;

  @override
  String toString() => 'ReplicationException(${fault.name}): $message';
}

/// The current state of one Authorization View of a Scope, folded from a
/// snapshot and the changefeed groups after it.
///
/// A replica is a value: [apply] returns the next replica or throws, so a
/// refused group leaves the previous replica untouched and a group is
/// applied whole or not at all.
@immutable
final class Replica {
  Replica._({
    required this.scope,
    required this.scopeEpoch,
    required this.authorizationView,
    required this.position,
    required this.checkpoint,
    required Map<String, BeadRecord> beads,
    required Map<String, LinkRecord> links,
  }) : beads = Map.unmodifiable(beads),
       links = Map.unmodifiable(links);

  /// Installs a snapshot whose complete Bead and Link streams — the
  /// manifest's first pages plus every continuation — are [beads] and
  /// [links].
  ///
  /// Refuses a snapshot whose inline owned Links disagree with the Link
  /// stream, whose Link has an absent in-Scope endpoint, or that still holds
  /// a version its erasure ledger names.
  factory Replica.fromSnapshot(
    SnapshotManifest manifest, {
    required List<BeadRecord> beads,
    required List<LinkRecord> links,
  }) {
    final replica = Replica._(
      scope: manifest.scope,
      scopeEpoch: manifest.scopeEpoch,
      authorizationView: manifest.authorizationView,
      position: manifest.scopePosition,
      checkpoint: manifest.checkpoint,
      beads: {for (final bead in beads) bead.id: bead},
      links: {for (final link in links) link.id: link},
    );
    for (final bead in replica.beads.values) {
      replica._verifyInline(bead);
    }
    for (final link in replica.links.values) {
      replica._verifyEndpoints(link);
    }
    for (final erasure in manifest.erasures) {
      replica._verifyErased(erasure);
    }
    return replica;
  }

  /// The canonical Scope URL.
  final String scope;

  /// The epoch this replica belongs to.
  final ScopeEpoch scopeEpoch;

  /// The view this replica projects.
  final AuthorizationView authorizationView;

  /// The Scope position of the last applied group or snapshot.
  final ScopePosition position;

  /// The durable cursor: the checkpoint of the last applied group, or the
  /// snapshot's.
  final Checkpoint checkpoint;

  /// Live Beads by canonical URL.
  final Map<String, BeadRecord> beads;

  /// Live Links by canonical URL.
  final Map<String, LinkRecord> links;

  /// Applies every group of a finite changefeed page, in order.
  Replica applyPage(ChangefeedPage page) {
    if (page.scope != scope) {
      throw ReplicationException(
        ReplicationFault.foreignScope,
        'page for ${page.scope} applied to $scope',
      );
    }
    _verifyFence(page.scopeEpoch, page.authorizationView);
    return page.groups.fold(this, (replica, group) => replica.apply(group));
  }

  /// Applies one change group atomically and advances to its checkpoint.
  ///
  /// The result keeps the invariants a snapshot install checks: inline owned
  /// Links agree with their records, every live Link's in-Scope endpoints are
  /// present (including Links the group did not touch whose endpoint Bead it
  /// tombstoned), and no erased version stays live.
  Replica apply(ChangeGroup group) {
    _verifyFence(group.scopeEpoch, group.authorizationView);
    if (group.previousPosition != position) {
      throw ReplicationException(
        ReplicationFault.positionMismatch,
        'group at ${group.position} follows ${group.previousPosition}, '
        'but the replica is at $position',
      );
    }
    if (group.projectionAdvance) {
      return _advance(group, beads: beads, links: links);
    }

    final nextBeads = Map.of(beads);
    final nextLinks = Map.of(links);
    final seen = <String>{};
    final upsertedBeads = <BeadRecord>[];
    final touchedLinks = <String, LinkRecord?>{};
    final removedBeads = <String>{};
    for (final change in group.changes) {
      if (!seen.add(change.id)) {
        throw ReplicationException(
          ReplicationFault.duplicateChange,
          '${change.id} appears twice in group ${group.position}',
        );
      }
      switch (change) {
        case Upsert(resource: final BeadRecord bead):
          nextBeads[bead.id] = bead;
          upsertedBeads.add(bead);
        case Upsert(resource: final LinkRecord link):
          nextLinks[link.id] = link;
          touchedLinks[link.id] = link;
        case Tombstone(resourceKind: ResourceKind.bead, :final identity):
          nextBeads.remove(identity.id);
          removedBeads.add(identity.id);
        case Tombstone(resourceKind: ResourceKind.link, :final identity):
          touchedLinks[identity.id] = links[identity.id];
          nextLinks.remove(identity.id);
      }
    }

    final next = _advance(group, beads: nextBeads, links: nextLinks);
    for (final bead in upsertedBeads) {
      next._verifyInline(bead);
    }
    for (final MapEntry(key: id, value: link) in touchedLinks.entries) {
      final source = link == null ? null : next.beads[link.source.uri];
      if (source != null) next._verifyInline(source);
      if (next.links[id] case final live?) next._verifyEndpoints(live);
    }
    // Deleting a Bead does not cascade: a Link the group left live that
    // still names a removed Bead would dangle.
    if (removedBeads.isNotEmpty) {
      for (final link in next.links.values) {
        if (removedBeads.contains(link.source.uri) ||
            removedBeads.contains(link.target.uri)) {
          next._verifyEndpoints(link);
        }
      }
    }
    for (final erasure in group.erasures) {
      next._verifyErased(erasure);
    }
    return next;
  }

  Replica _advance(
    ChangeGroup group, {
    required Map<String, BeadRecord> beads,
    required Map<String, LinkRecord> links,
  }) => Replica._(
    scope: scope,
    scopeEpoch: scopeEpoch,
    authorizationView: authorizationView,
    position: group.position,
    checkpoint: group.checkpoint,
    beads: beads,
    links: links,
  );

  void _verifyFence(ScopeEpoch epoch, AuthorizationView view) {
    if (epoch != scopeEpoch) {
      throw ReplicationException(
        ReplicationFault.foreignEpoch,
        'epoch $epoch applied to a replica of epoch $scopeEpoch',
      );
    }
    if (view != authorizationView) {
      throw ReplicationException(
        ReplicationFault.foreignView,
        'view $view applied to a replica of view $authorizationView',
      );
    }
  }

  void _verifyInline(BeadRecord bead) {
    for (final owned in bead.ownedLinks?.values ?? const <List<LinkRecord>>[]) {
      for (final inline in owned) {
        if (links[inline.id] != inline) {
          throw ReplicationException(
            ReplicationFault.ownedLinkDisagreement,
            '${bead.id} inlines ${inline.id}@${inline.revision}, which '
            'disagrees with the Link record',
          );
        }
      }
    }
  }

  void _verifyEndpoints(LinkRecord link) {
    for (final endpoint in [link.source, link.target]) {
      if (endpoint.uri.startsWith(scope) && !beads.containsKey(endpoint.uri)) {
        throw ReplicationException(
          ReplicationFault.missingEndpoint,
          '${link.id} names ${endpoint.uri}, which is not in the projection',
        );
      }
    }
  }

  void _verifyErased(ErasureRecord erasure) {
    final held =
        beads[erasure.subject]?.revision ?? links[erasure.subject]?.revision;
    if (held == erasure.revision) {
      throw ReplicationException(
        ReplicationFault.erasedStateRetained,
        '${erasure.subject}@${erasure.revision} is erased but still live',
      );
    }
  }
}
