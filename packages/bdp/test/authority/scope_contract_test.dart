// One Scope contract, run over the SQLite authority and over the bd
// authority in front of a real bd store in proxied-server mode, so a
// consumer of either sees one Scope. The bd half runs only where a bd runs
// and the store's version stamp names it; elsewhere each of its tests is
// skipped, naming why.
@Timeout(Duration(minutes: 3))
library;

import 'package:bdp/bd.dart';
import 'package:bdp/bdp.dart';
import 'package:bdp/testing.dart';
import 'package:test/test.dart';

import '../support/real_bd.dart';
import '../support/scope.dart';

/// What the contract needs of a Scope under test, whichever authority
/// serves it.
abstract interface class ScopeHarness {
  /// The authority, as the HTTP handler serves it.
  AuthorityScope get authority;

  /// The authority in process.
  LocalScope get local;

  /// A client over HTTP, answered in process by `authorityHandler`.
  ScopeClient get client;

  /// The handler's HTTP client, for the wire's own headers.
  HandlerClient get http;

  /// The Type every seeded bead is created under.
  String get beadType;

  /// The Link Type a seeded dependency is served under.
  String get dependencyType;

  /// The bd write calls made so far; the SQLite authority makes none.
  int get writeCalls;

  /// Makes a bead titled [title] and answers its canonical URL, once the
  /// Scope serves it.
  Future<String> seedBead(String title);

  /// Makes [holder] depend on [target] and answers the Link's canonical
  /// URL, once the Scope serves it.
  Future<String> seedDependency(String holder, String target);

  /// Changes [bead] as another actor would.
  Future<void> editOutside(String bead);

  /// Waits until the Scope serves every change made outside it.
  Future<void> settle();

  Future<void> close();
}

final class SqliteHarness implements ScopeHarness {
  SqliteHarness() {
    _authority
      ..installType({
        'id': beadType,
        'name': 'Bead',
        'describes': 'bead',
        'conformsTo': <String>[],
      })
      ..installType({
        'id': dependencyType,
        'name': 'Blocks',
        'describes': 'link',
        'conformsTo': <String>[],
        'source': {
          'conformsTo': [beadType],
          'external': 'none',
        },
        'target': {
          'conformsTo': [beadType],
        },
      });
    http = HandlerClient(authorityHandler(_authority));
  }

  final _authority = ScopeAuthority.memory(scope: scope);
  late ScopeClient _client;
  var _keys = 0;

  /// Discovers the client over HTTP.
  Future<SqliteHarness> start() async {
    _client = await ScopeClient.discover(Uri.parse(scope), httpClient: http);
    return this;
  }

  @override
  AuthorityScope get authority => _authority;

  @override
  LocalScope get local => _authority;

  @override
  ScopeClient get client => _client;

  @override
  late final HandlerClient http;

  @override
  String get beadType => '${scope}types/bead';

  @override
  String get dependencyType => '${scope}types/dependency/blocks';

  @override
  int get writeCalls => 0;

  @override
  Future<String> seedBead(String title) async {
    final receipt = _authority.mutate('create-bead', {
      'type': beadType,
      'properties': {'title': title, 'metadata': <String, Object?>{}},
    }, idempotencyKey: 'seed-${_keys++}');
    expect(receipt.status, 'completed', reason: '${receipt.json}');
    return (receipt.results.single['resource']! as Json)['id']! as String;
  }

  @override
  Future<String> seedDependency(String holder, String target) async {
    final receipt = _authority.mutate('create-link', {
      'type': dependencyType,
      'source': holder,
      'target': target,
    }, idempotencyKey: 'seed-${_keys++}');
    expect(receipt.status, 'completed', reason: '${receipt.json}');
    return (receipt.results.single['resource']! as Json)['id']! as String;
  }

  @override
  Future<void> editOutside(String bead) async {
    final receipt = _authority.mutate('update-bead-properties', {
      'bead': bead,
      'change': [
        {'op': 'add', 'path': '/metadata/outside', 'value': 'e${_keys++}'},
      ],
    }, idempotencyKey: 'outside-${_keys++}');
    expect(receipt.status, 'completed', reason: '${receipt.json}');
  }

  @override
  Future<void> settle() async {}

  @override
  Future<void> close() async => _authority.close();
}

final class BdHarness implements ScopeHarness {
  BdHarness._(this._store, this._cli, this._authority) {
    http = HandlerClient(authorityHandler(_authority));
  }

  /// A harness over [store], or null with the test skipped naming why.
  static Future<BdHarness?> open(StampedStore? store, String? absence) async {
    final cli = await stampedCli(store, absence);
    if (cli == null) return null;
    final recording = RecordingCli(cli);
    final authority = await BdScopeAuthority.open(
      bd: recording,
      scope: scope,
      interval: const Duration(milliseconds: 100),
    );
    final harness = BdHarness._(store!, recording, authority);
    harness._client = await ScopeClient.discover(
      Uri.parse(scope),
      httpClient: harness.http,
    );
    return harness;
  }

  final StampedStore _store;
  final RecordingCli _cli;
  final BdScopeAuthority _authority;
  late ScopeClient _client;
  var _edits = 0;

  @override
  AuthorityScope get authority => _authority;

  @override
  LocalScope get local => _authority;

  @override
  ScopeClient get client => _client;

  @override
  late final HandlerClient http;

  @override
  String get beadType => _authority.beadType;

  @override
  String get dependencyType => _authority.linkType('blocks');

  @override
  int get writeCalls => _cli.writes.length;

  String _id(String url) =>
      Uri.decodeComponent(url.substring('${scope}beads/'.length));

  @override
  Future<String> seedBead(String title) async {
    final id = await humanCreate(_store, title);
    await settle();
    return '${scope}beads/${Uri.encodeComponent(id)}';
  }

  @override
  Future<String> seedDependency(String holder, String target) async {
    await human(_store, ['dep', 'add', _id(holder), _id(target), '--json']);
    await settle();
    return '${scope}links/${Uri.encodeComponent(_id(holder))}/blocks/'
        '${Uri.encodeComponent(_id(target))}';
  }

  @override
  Future<void> editOutside(String bead) async {
    await human(_store, [
      'update',
      '--set-metadata=outside=e${_edits++}',
      '--json',
      '--',
      _id(bead),
    ]);
  }

  @override
  Future<void> settle() => _authority.refresh();

  @override
  Future<void> close() => _authority.close();
}

TypeMatcher<BdpProblemException> _clientProblem(String code) =>
    isA<BdpProblemException>().having(
      (exception) => exception.problem.code,
      'code',
      code,
    );

int _operationsOf(ScopeHarness harness) =>
    ((harness.authority.discoveryDocument().body['limits']!
                as Json)['transaction']!
            as Json)['operations']!
        as int;

void main() {
  late StampedStore? store;
  late String? absence;

  setUpAll(() async {
    (store, absence) = await StampedStore.create();
  });

  tearDownAll(() async => store?.delete());

  final harnesses = <String, Future<ScopeHarness?> Function()>{
    'the SQLite authority': () => SqliteHarness().start(),
    'the bd authority over a real proxied-server store': () =>
        BdHarness.open(store, absence),
  };

  for (final MapEntry(key: name, value: make) in harnesses.entries) {
    group(name, () {
      ScopeHarness? harness;

      setUp(() async => harness = await make());

      tearDown(() async => harness?.close());

      /// The harness, or null when the test is skipped.
      ScopeHarness? scoped() => harness;

      test('discovery validates as Transactional and advertises its '
          'transaction limit', () async {
        final h = scoped();
        if (h == null) return;
        final discovery = h.authority.discoveryDocument().body;
        expectSchema(discovery, 'transactionalDiscovery');
        expect(_operationsOf(h), h is BdHarness ? 1 : greaterThan(1));
        expect(
          h.client.discovery.limits?.transaction?.operations,
          _operationsOf(h),
        );
      });

      test('a Bead reads by canonical URL with an ETag, and a missing one is '
          'resource-not-found', () async {
        final h = scoped();
        if (h == null) return;
        final bead = await h.seedBead('read me');
        final record = await h.client.readBead(bead);
        expect(record.id, bead);
        expect((await h.local.readBead(bead)).revision, record.revision);
        final response = await h.http.get(Uri.parse(bead));
        expect(response.statusCode, 200);
        expect(response.headers['etag'], '"${record.revision.value}"');
        final missing = '${scope}beads/t-missing';
        await expectLater(
          h.client.readBead(missing),
          throwsA(_clientProblem('resource-not-found')),
        );
        await expectLater(
          h.local.readBead(missing),
          throwsA(_clientProblem('resource-not-found')),
        );
      });

      test('Bead pages run in canonical-uri order, and a continuation fails '
          'cursor-expired once the store changed', () async {
        final h = scoped();
        if (h == null) return;
        final seeded = [
          for (final title in ['one', 'two', 'three']) await h.seedBead(title),
        ];
        final ids = <String>[];
        var page = await h.client.beads(const BeadQuery(limit: 1));
        ids.addAll(page.items.map((bead) => bead.id));
        while (page.next != null) {
          page = await h.client.nextBeads(page.next!);
          ids.addAll(page.items.map((bead) => bead.id));
        }
        expect(ids, [...ids]..sort());
        expect(ids, containsAll(seeded));
        final first = await h.client.beads(const BeadQuery(limit: 1));
        await h.editOutside(seeded.first);
        await h.settle();
        await expectLater(
          h.client.nextBeads(first.next!),
          throwsA(_clientProblem('cursor-expired')),
        );
      });

      test('a dependency is an incident Link of both beads and in the links '
          'collection, and the Type inventory holds both Types', () async {
        final h = scoped();
        if (h == null) return;
        final holder = await h.seedBead('holder');
        final target = await h.seedBead('target');
        final link = await h.seedDependency(holder, target);
        for (final bead in [holder, target]) {
          final incident = await h.client.incidentLinks(bead);
          expect(incident.items.map((l) => l.id), contains(link));
        }
        final links = await h.local.allLinks().toList();
        final served = links.singleWhere((l) => l.id == link);
        expect(served.type, h.dependencyType);
        final types = await h.client.types();
        expect(
          types.items.map((type) => type.id),
          containsAll([h.beadType, h.dependencyType]),
        );
      });

      test('a single-operation batch is answered by a receipt, and a stale '
          'expectedRevision by revision-mismatch', () async {
        final h = scoped();
        if (h == null) return;
        final bead = await h.seedBead('written');
        final receipt = await h.authority.mutate('batch', {
          'operations': [
            {
              'operation': 'updateBeadProperties',
              'bead': bead,
              'change': [
                {'op': 'add', 'path': '/metadata/k', 'value': 'v'},
              ],
            },
          ],
        }, idempotencyKey: 'single');
        expect(receipt.status, 'completed', reason: '${receipt.json}');
        expectSchema(receipt.json, 'mutationReceipt');
        final read = await h.client.readBead(bead);
        expect((read.properties['metadata']! as Map)['k'], 'v');
        final stale = await h.client.batch([
          UpdateBeadProperties(
            bead: bead,
            change: PropertyChange([AddOp('/metadata/k', 'w')]),
            expectedRevision: Revision('stale'),
          ),
        ], idempotencyKey: IdempotencyKey('stale'));
        expect(stale.status, ReceiptStatus.failed);
        expect(stale.problem?.code, 'revision-mismatch');
        final raw = h.authority.receipt(
          stale.id.substring('${scope}receipts/'.length),
        );
        expectSchema(raw.body, 'mutationReceipt');
      });

      test('a two-operation batch is what the transaction limit says: the '
          'SQLite authority rolls it back whole, the bd authority refuses it '
          'before admission and binds no key', () async {
        final h = scoped();
        if (h == null) return;
        final first = await h.seedBead('first');
        final second = await h.seedBead('second');
        final two = [
          UpdateBeadProperties(
            bead: first,
            change: PropertyChange([AddOp('/metadata/both', 'x')]),
          ),
          UpdateBeadProperties(
            bead: second,
            change: PropertyChange([AddOp('/metadata/both', 'x')]),
            expectedRevision: Revision('stale'),
          ),
        ];
        final writes = h.writeCalls;
        if (_operationsOf(h) >= 2) {
          final receipt = await h.client.batch(
            two,
            idempotencyKey: IdempotencyKey('two'),
          );
          expect(receipt.status, ReceiptStatus.failed);
          expect(receipt.problem?.code, 'revision-mismatch');
          final read = await h.client.readBead(first);
          expect(
            (read.properties['metadata']! as Map).containsKey('both'),
            isFalse,
          );
        } else {
          await expectLater(
            h.client.batch(two, idempotencyKey: IdempotencyKey('two')),
            throwsA(
              _clientProblem('limit-exceeded').having(
                (exception) => exception.problem.limit,
                'limit',
                'transaction.operations',
              ),
            ),
          );
          expect(h.writeCalls, writes);
          final one = await h.client.batch([
            two.first,
          ], idempotencyKey: IdempotencyKey('two'));
          expect(one.status, ReceiptStatus.completed);
        }
      });

      test('an edit made outside the server arrives over the changefeed as '
          'a change group', () async {
        final h = scoped();
        if (h == null) return;
        final bead = await h.seedBead('watched');
        final start = await h.client.changes(const ChangefeedStart.now());
        await h.editOutside(bead);
        await h.settle();
        final page = await h.client.changes(ChangefeedStart.after(start.after));
        expect(page.groups, isNotEmpty);
        expect(
          page.groups
              .expand((group) => group.changes)
              .whereType<Upsert>()
              .map((change) => change.resource.id),
          contains(bead),
        );
      });
    });
  }
}
