// The authority serves, and the client parses, one set of shapes: every
// operation answered in process through the authority's own LocalScope must
// decode to the same value as the one ScopeClient decodes from the HTTP
// handler, with no socket in between.
import 'dart:async';

import 'package:bdp/bdp.dart';
import 'package:bdp/testing.dart';
import 'package:test/test.dart';

import '../support/scope.dart';

/// A task Bead creation the typed client builds.
CreateBead task(String id, {String title = 'Specify BDP mutation'}) =>
    CreateBead(
      id: 'beads/$id',
      type: taskType,
      properties: {'title': title, 'status': 'open'},
    );

void main() {
  late TestClock clock;
  late ScopeAuthority authority;
  late LocalScope local;
  late ScopeClient remote;

  setUp(() async {
    clock = TestClock();
    authority = memoryAuthority(clock);
    local = authority;
    remote = await ScopeClient.discover(
      Uri.parse(scope),
      httpClient: HandlerClient(authorityHandler(authority)),
    );
  });

  tearDown(() => authority.close());

  /// Both paths' answers to [read], which must be equal and are returned.
  Future<T> same<T>(Future<T> Function(LocalScope scope) read) async {
    final inProcess = await read(local);
    final overHttp = await read(remote);
    expect(inProcess, overHttp);
    return inProcess;
  }

  /// The problem both paths raise for [read], which must agree.
  Future<BdpProblemException> sameProblem(
    Future<Object?> Function(LocalScope scope) read,
  ) async {
    Future<BdpProblemException> problemOf(LocalScope scope) async {
      try {
        await read(scope);
      } on BdpProblemException catch (problem) {
        return problem;
      }
      fail('expected a problem');
    }

    final inProcess = await problemOf(local);
    final overHttp = await problemOf(remote);
    expect(inProcess.status, overHttp.status);
    expect(inProcess.problem, overHttp.problem);
    return inProcess;
  }

  test('discovery decodes to the same Transactional document', () async {
    final discovery = await same((scope) async => scope.discovery);
    expect(discovery.profile, Profile.transactional);
    expect(discovery.scope, scope);
  });

  test('discovery advertises the request body bound the HTTP binding '
      'enforces, and the client reads it', () async {
    final discovery = await same((scope) async => scope.discovery);
    expect(
      discovery.limits?.request?.bodyBytes,
      ScopeAuthority.maximumBodyBytes,
    );
    expect(remote.discovery.limits?.request?.bodyBytes, 1 << 20);
  });

  test(
    'a write through either path reads back identically through both',
    () async {
      final created = await local.createBead(
        task('task-1'),
        idempotencyKey: IdempotencyKey('one'),
      );
      final receipt = (created as ReceiptResponse).receipt;
      expect(receipt.status, ReceiptStatus.completed);
      expect(await same((scope) => scope.readReceipt(receipt.id)), receipt);

      final bead = await same((scope) => scope.readBead('beads/task-1'));
      expect(bead.properties['title'], 'Specify BDP mutation');

      final updated = await remote.batch([
        UpdateBeadProperties(
          bead: bead.id,
          expectedRevision: bead.revision,
          change: PropertyChange([PatchOp.replace('/status', 'closed')]),
        ),
        task('task-2'),
      ], idempotencyKey: IdempotencyKey('two'));
      expect(updated.status, ReceiptStatus.completed);
      expect(await same((scope) => scope.readReceipt(updated.id)), updated);
      expect(
        (await same((scope) => scope.readBead(bead.id))).properties['status'],
        'closed',
      );
    },
  );

  test('an identical retry through the other path returns the same '
      'receipt', () async {
    final first = await local.batch([
      task('task-1'),
    ], idempotencyKey: IdempotencyKey('retry'));
    final again = await remote.batch([
      task('task-1'),
    ], idempotencyKey: IdempotencyKey('retry'));
    expect(again, first);
  });

  test('collections and incident Links page identically, continuations '
      'included', () async {
    for (final id in ['a', 'b', 'c']) {
      await local.createBead(task(id), idempotencyKey: IdempotencyKey(id));
    }
    await local.createLink(
      CreateLink(
        type: blocksType,
        source: const UriReference('beads/a'),
        target: const UriReference('beads/b'),
      ),
      idempotencyKey: IdempotencyKey('link'),
    );
    final first = await same(
      (scope) => scope.beads(const BeadQuery(type: taskType, limit: 2)),
    );
    expect(first.items, hasLength(2));
    final second = await same((scope) => scope.nextBeads(first.next!));
    expect(second.items.single.id, endsWith('beads/c'));
    expect(second.next, isNull);

    expect(await same((scope) => scope.allBeads().toList()), hasLength(3));
    final links = await same((scope) => scope.links());
    expect(links.items.single.source.uri, endsWith('beads/a'));
    final incident = await same(
      (scope) => scope.incidentLinks(
        'beads/b',
        direction: LinkDirection.inbound,
        limit: 1,
      ),
    );
    expect(incident.items.single, links.items.single);
    expect(await same((scope) => scope.types()), isA<Page<TypeSummary>>());
  });

  test('the Type inventory pages in canonical-uri order both ways', () async {
    final first = await same((scope) => scope.types(limit: 3));
    expect(first.items.map((t) => t.id), [blocksType, citesType, decisionType]);
    final rest = await same((scope) => scope.nextTypes(first.next!));
    expect(rest.items.map((t) => t.id), [taskType]);
    expect(rest.next, isNull);
    final all = await same((scope) => scope.types());
    expect(all.items.map((t) => t.id), [
      blocksType,
      citesType,
      decisionType,
      taskType,
    ]);
    // A continuation does not survive a change to the pinned Types.
    final paged = await local.types(limit: 1);
    authority.installType({
      'id': 'https://work.example/types/aaa',
      'name': 'First',
      'describes': 'bead',
    });
    final problem = await sameProblem((scope) => scope.nextTypes(paged.next!));
    expect(problem.problem.code, 'cursor-expired');
  });

  test('the finite changefeed decodes the same groups from genesis, from a '
      'checkpoint and from now', () async {
    for (final id in ['a', 'b', 'c']) {
      await local.createBead(task(id), idempotencyKey: IdempotencyKey(id));
    }
    final genesis = await same(
      (scope) => scope.changes(ChangefeedStart.genesis()),
    );
    expect(genesis.groups, hasLength(3));
    final later = await same(
      (scope) =>
          scope.changes(ChangefeedStart.after(genesis.groups[0].checkpoint)),
    );
    expect(later.groups, genesis.groups.sublist(1));
    final now = await same(
      (scope) => scope.changes(const ChangefeedStart.now()),
    );
    expect(now.groups, isEmpty);
    expect(now.after, genesis.groups.last.checkpoint);
  });

  test('a history of every change kind decodes to the same groups both '
      'ways, tombstones included', () async {
    await local.batch([
      task('a'),
      task('b'),
      CreateLink(
        id: 'links/a-blocks-b',
        type: blocksType,
        source: const UriReference('beads/a'),
        target: const UriReference('beads/b'),
      ),
    ], idempotencyKey: IdempotencyKey('build'));
    final link = await local.readLink('links/a-blocks-b');
    await remote.batch([
      DeleteLink(link: link.id, expectedRevision: link.revision),
      const DeleteBead(bead: 'beads/b'),
    ], idempotencyKey: IdempotencyKey('tear'));
    final page = await same(
      (scope) => scope.changes(ChangefeedStart.genesis()),
    );
    expect(page.groups.last.changes.whereType<Tombstone>(), hasLength(2));
    expect(
      page.groups.expand((group) => group.events).map((event) => event.type),
      containsAll([
        EventType.created,
        EventType.linked,
        EventType.unlinked,
        EventType.deleted,
      ]),
    );
    final replica = await local.bootstrap();
    expect((await remote.bootstrap()).beads, replica.beads);
    expect(replica.beads.keys.single, endsWith('beads/a'));
  });

  test('a receipt past its retention decodes to the same compact form both '
      'ways', () async {
    final created = await local.batch([
      task('a'),
    ], idempotencyKey: IdempotencyKey('a'));
    clock.now = clock.now.add(const Duration(days: 8));
    final expired = await same((scope) => scope.readReceipt(created.id));
    expect(expired.detail, ReceiptDetail.expired);
    expect(expired.allocated!.single.id, endsWith('beads/a'));
  });

  test('a snapshot bootstraps the same replica both ways', () async {
    await local.createBead(task('a'), idempotencyKey: IdempotencyKey('a'));
    final inProcess = await local.bootstrap();
    final overHttp = await remote.bootstrap();
    expect(inProcess.checkpoint, overHttp.checkpoint);
    expect(inProcess.beads, overHttp.beads);
    expect(inProcess.links, overHttp.links);
  });

  test('a live follow delivers the same groups in process and over SSE, and '
      'they fold into the same replica', () async {
    await local.createBead(task('a'), idempotencyKey: IdempotencyKey('a'));
    final start = await local.bootstrap();

    final arrivals = <String, List<ChangeGroup>>{'local': [], 'remote': []};
    final both = Completer<void>();
    ChangefeedSubscription followed(String name, LocalScope scope) =>
        scope.follow(ChangefeedStart.after(start.checkpoint), (group) async {
          arrivals[name]!.add(group);
          if (arrivals.values.every((groups) => groups.length == 2) &&
              !both.isCompleted) {
            both.complete();
          }
        });
    final inProcess = followed('local', local);
    final overSse = followed('remote', remote);

    await local.createBead(task('b'), idempotencyKey: IdempotencyKey('b'));
    await remote.batch([task('c')], idempotencyKey: IdempotencyKey('c'));
    await both.future;
    await inProcess.cancel();
    await overSse.cancel();

    expect(arrivals['local'], arrivals['remote']);
    final folded = arrivals['local']!.fold(start, (r, g) => r.apply(g));
    expect(folded.beads.keys, hasLength(3));
    expect(folded.checkpoint, arrivals['remote']!.last.checkpoint);
  });

  test('refusals carry the same problem both ways', () async {
    final missing = await sameProblem((scope) => scope.readBead('beads/none'));
    expect(missing.code, 'resource-not-found');
    expect(missing.status, 404);

    final selector = await sameProblem(
      (scope) => scope.beads(
        BeadQuery(selector: Selector(r'$[?@.properties.status == "open"]')),
      ),
    );
    expect(selector.code, 'invalid-parameter');

    await local.createBead(task('a'), idempotencyKey: IdempotencyKey('a'));
    final conflict = await sameProblem(
      (scope) => scope.batch([task('b')], idempotencyKey: IdempotencyKey('a')),
    );
    expect(conflict.code, 'idempotency-conflict');
  });

  test('an admitted failure is a failed receipt with the same problem both '
      'ways', () async {
    await local.createBead(task('a'), idempotencyKey: IdempotencyKey('a'));
    final bead = await local.readBead('beads/a');
    final stale = Revision('${bead.revision.value}x');
    Future<MutationReceipt> staleWrite(LocalScope scope, String key) =>
        scope.batch([
          UpdateBeadProperties(
            bead: bead.id,
            expectedRevision: stale,
            change: PropertyChange([PatchOp.replace('/title', 'moved')]),
          ),
        ], idempotencyKey: IdempotencyKey(key));
    final inProcess = await staleWrite(local, 'stale-local');
    final overHttp = await staleWrite(remote, 'stale-remote');
    expect(inProcess.status, ReceiptStatus.failed);
    expect(inProcess.problem!.code, 'revision-mismatch');
    expect(inProcess.problem, overHttp.problem);
  });

  test('a follow from a foreign checkpoint ends with cursor-expired both '
      'ways', () async {
    Future<Object?> endOf(LocalScope scope) async {
      final subscription = scope.follow(
        ChangefeedStart.after(Checkpoint('elsewhere_9')),
        (_) async {},
      );
      try {
        await subscription.done;
      } on Object catch (error) {
        return error;
      }
      return null;
    }

    final inProcess = await endOf(local);
    final overHttp = await endOf(remote);
    expect(inProcess, isA<BdpProblemException>());
    expect(overHttp, isA<BdpProblemException>());
    expect(
      (inProcess! as BdpProblemException).problem,
      (overHttp! as BdpProblemException).problem,
    );
    expect((inProcess as BdpProblemException).code, 'cursor-expired');
  });

  test('the in-process Scope serves installed Type Descriptors', () async {
    final descriptor = await local.readTypeDescriptor(taskType);
    expect(descriptor.id, taskType);
    expect(descriptor.describes, ResourceKind.bead);
  });
}
