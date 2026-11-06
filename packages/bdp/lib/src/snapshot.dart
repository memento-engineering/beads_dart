import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'changefeed.dart';
import 'json.dart';
import 'records.dart';
import 'tokens.dart';

/// A Scope snapshot manifest: one transaction-consistent projection
/// anchored at one position, with the first page of each typed stream.
@immutable
final class SnapshotManifest {
  /// A manifest.
  SnapshotManifest({
    required this.id,
    required this.scope,
    required this.scopeEpoch,
    required this.authorizationView,
    required this.scopePosition,
    required this.checkpoint,
    required this.expiresAt,
    required List<ErasureRecord> erasures,
    required this.beads,
    required this.links,
  }) : erasures = List.unmodifiable(erasures);

  /// Decodes a manifest.
  factory SnapshotManifest.fromJson(Object? json, [String path = '']) {
    final r = JsonReader.of(json, path);
    return SnapshotManifest(
      id: r.string('id'),
      scope: r.string('scope'),
      scopeEpoch: r.decode('scopeEpoch', ScopeEpoch.fromJson),
      authorizationView: r.decode(
        'authorizationView',
        AuthorizationView.fromJson,
      ),
      scopePosition: r.decode('scopePosition', ScopePosition.fromJson),
      checkpoint: r.decode('checkpoint', Checkpoint.fromJson),
      expiresAt: r.string('expiresAt'),
      erasures: r.list('erasures', ErasureRecord.fromJson),
      beads: r.decode(
        'beads',
        (value, path) => Page.fromJson(value, path, BeadRecord.fromJson),
      ),
      links: r.decode(
        'links',
        (value, path) => Page.fromJson(value, path, LinkRecord.fromJson),
      ),
    );
  }

  /// The manifest handle URL.
  final String id;

  /// The canonical Scope URL.
  final String scope;

  /// The epoch the snapshot belongs to.
  final ScopeEpoch scopeEpoch;

  /// The view the snapshot projects.
  final AuthorizationView authorizationView;

  /// The position the snapshot is anchored at.
  final ScopePosition scopePosition;

  /// The exclusive changefeed cursor replay continues from.
  final Checkpoint checkpoint;

  /// When the handle stops being continuable, as served.
  final String expiresAt;

  /// The erasure ledger projected for the view.
  final List<ErasureRecord> erasures;

  /// The first page of the Bead stream.
  final Page<BeadRecord> beads;

  /// The first page of the Link stream.
  final Page<LinkRecord> links;

  /// The wire form.
  JsonObject toJson() => {
    'id': id,
    'scope': scope,
    'scopeEpoch': scopeEpoch.toJson(),
    'authorizationView': authorizationView.toJson(),
    'scopePosition': scopePosition.toJson(),
    'checkpoint': checkpoint.toJson(),
    'expiresAt': expiresAt,
    'erasures': [for (final erasure in erasures) erasure.toJson()],
    'beads': beads.toJson((bead) => bead.toJson()),
    'links': links.toJson((link) => link.toJson()),
  };

  @override
  bool operator ==(Object other) =>
      other is SnapshotManifest &&
      other.id == id &&
      other.scope == scope &&
      other.scopeEpoch == scopeEpoch &&
      other.authorizationView == authorizationView &&
      other.scopePosition == scopePosition &&
      other.checkpoint == checkpoint &&
      other.expiresAt == expiresAt &&
      other.beads == beads &&
      other.links == links &&
      const ListEquality<ErasureRecord>().equals(other.erasures, erasures);

  @override
  int get hashCode => Object.hash(
    id,
    scope,
    scopeEpoch,
    authorizationView,
    scopePosition,
    checkpoint,
    expiresAt,
    beads,
    links,
    const ListEquality<ErasureRecord>().hash(erasures),
  );
}
