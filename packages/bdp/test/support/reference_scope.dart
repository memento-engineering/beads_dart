import 'package:bdp/bdp.dart';

import 'fake_http.dart';
import 'fixtures.dart';

/// An offline Read-profile authority serving the reference-domain fixture:
/// its Type inventory, its external-endpoint Links, and the one Bead they
/// share, `beads/demo-f`.
final class ReferenceScope {
  ReferenceScope(this.scope)
    : domain = fixture('reference-domain/reference-domain.json');

  final String scope;
  final Map<String, Object?> domain;

  late final FakeHttpClient client = FakeHttpClient(_handle);

  List<Map<String, Object?>> get typeSummaries => [
    for (final entry in [
      ...domain['beadTypes']! as List<Object?>,
      ...domain['linkTypes']! as List<Object?>,
    ])
      entry! as Map<String, Object?>,
  ]..sort((a, b) => (a['id']! as String).compareTo(b['id']! as String));

  List<Map<String, Object?>> get externalLinks => [
    for (final entry in domain['externalEndpointLinks']! as List<Object?>)
      entry! as Map<String, Object?>,
  ];

  /// The canonical spelling of a fixture reference: in-Scope local IDs
  /// resolve against the Scope; external URIs are preserved.
  Object canonical(Object reference) => switch (reference) {
    final String uri when uri.startsWith('beads/') => '$scope$uri',
    final String uri => uri,
    final Map<String, Object?> pinned => {
      'uri': canonical(pinned['uri']!),
      'revision': pinned['revision'],
    },
    _ => throw ArgumentError(reference),
  };

  Map<String, Object?> linkRecord(Map<String, Object?> entry) => {
    'id': '$scope${entry['localId']}',
    'type': entry['type'],
    'revision': entry['revision'],
    'attribution': ?entry['attribution'],
    'source': canonical(entry['source']!),
    'target': canonical(entry['target']!),
    'properties': entry['properties'],
  };

  Map<String, Object?> get demoF => {
    'id': '${scope}beads/demo-f',
    'type': 'https://work.example/types/decision',
    'revision': 'demo-f-r1',
    'properties': {'title': 'F'},
    'ownedLinks': <String, Object?>{
      'https://work.example/types/cites': <Object?>[],
      'https://work.example/types/relates': <Object?>[],
    },
  };

  FakeResponse _handle(RecordedRequest request) {
    final base =
        '${request.url.scheme}://${request.url.authority}${request.url.path}';
    final path = base.startsWith(scope) ? base.substring(scope.length) : null;
    final query = request.url.queryParameters;
    return switch (path) {
      '' => FakeResponse(
        204,
        headers: {
          'link': '<bdp.json>; rel="service-desc"; type="application/json"',
        },
      ),
      'bdp.json' => FakeResponse.json(200, {
        'bdpVersion': '0',
        'profile': 'read',
        'scope': scope,
        'beads': '${scope}beads/',
        'links': '${scope}links/',
        'types': '${scope}types/',
        'limits': {
          'page': {'defaultItems': 50, 'maximumItems': 200},
        },
      }),
      'types/' => _typesPage(query),
      'beads/demo-f' when query['view'] == 'links' => _incident(query),
      'beads/demo-f' when query.isEmpty => FakeResponse.json(200, demoF),
      final String id when id.startsWith('links/') && query.isEmpty => _link(
        id,
      ),
      _ => notFound,
    };
  }

  FakeResponse _typesPage(Map<String, String> query) {
    final all = typeSummaries;
    final limit = int.parse(query['limit'] ?? '50');
    final offset = int.parse(query['cursor'] ?? '0');
    final end = (offset + limit).clamp(0, all.length);
    return FakeResponse.json(200, {
      'items': all.sublist(offset, end),
      'next': end < all.length
          ? '${scope}types/?limit=$limit&cursor=$end'
          : null,
    });
  }

  FakeResponse _incident(Map<String, String> query) {
    final bead = '${scope}beads/demo-f';
    final direction = query['direction'] ?? 'both';
    bool uriIs(Object? reference) =>
        (reference is Map ? reference['uri'] : reference) == bead;
    final items = [
      for (final entry in externalLinks)
        if ((direction != 'outbound' && uriIs(canonical(entry['target']!))) ||
            (direction != 'inbound' && uriIs(canonical(entry['source']!))))
          linkRecord(entry),
    ]..sort((a, b) => (a['id']! as String).compareTo(b['id']! as String));
    return FakeResponse.json(200, {'items': items, 'next': null});
  }

  FakeResponse _link(String id) {
    for (final entry in externalLinks) {
      if (entry['localId'] == id) {
        return FakeResponse.json(200, linkRecord(entry));
      }
    }
    return notFound;
  }
}

/// The uniform not-found problem.
final FakeResponse notFound = FakeResponse.json(404, {
  'type': '${problemTypePrefix}not-found',
  'code': 'resource-not-found',
  'retry': 'after-state-change',
  'status': 404,
});
