import 'dart:io';

import 'package:bdp/bdp.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../support/http.dart';
import '../support/scope.dart';

/// The `http-contracts` cases this authority cannot stage, with the reason.
/// Every other case runs below against a live authority.
const _outOfSubset = {
  'refusal-before-conditional-authentication':
      'no authentication: every caller is a principal',
  'refusal-before-conditional-expired-detail':
      'receipt-page premise: no receipt-page URL is ever issued, and a '
      "receipt's own URL serves its compact form after expiry",
  'refusal-before-conditional-erasure-expiry': 'version erasure is out',
  'refusal-before-conditional-service-failure':
      'one in-process store: there is no transient unavailability to stage',
  'manifest-erasure-expiry': 'version erasure is out',
  'manifest-service-failure-before-expiry':
      'one in-process store: there is no transient unavailability to stage',
  'receipt-page-failover': 'no replicas',
  'receipt-page-restart-withheld': 'authorization views are out: one view',
  'receipt-page-restart-erased': 'version erasure is out',
  'refusal-before-conditional-retracted-receipt':
      'receipts are never retracted',
  'unknown-key-rate-limit-unacceptable': 'no rate limiting',
};

/// One authority over a file, with the Resources, receipts, checkpoint and
/// snapshot handle the cases address.
final class _World {
  _World(this.directory) : clock = TestClock() {
    _open();
    installWorkTypes(authority);
    item = createTask(authority, 'beads/item');
    receipt = authority
        .batchJson(sampleBatch('sample'), idempotencyKey: 'sample')
        .json;
    failed = authority.createBeadJson({
      'id': 'beads/item',
      'type': taskType,
      'properties': {'title': 'taken'},
    }, idempotencyKey: 'failed').json;
    checkpoint =
        (groupsOf(authority.changePage(after: 'genesis')).first['checkpoint'])!
            as String;
    snapshot = Uri.parse(
      authority.snapshotDocument().body['id']! as String,
    ).queryParameters['snapshot']!;
  }

  final Directory directory;
  final TestClock clock;
  late ScopeAuthority authority;
  late Handler handler;
  late Json item;
  late Json receipt;
  late Json failed;
  late String checkpoint;
  late String snapshot;

  void _open() {
    authority = ScopeAuthority.file(
      '${directory.path}/scope.db',
      scope: scope,
      clock: clock.call,
    );
    handler = authorityHandler(authority);
  }

  /// Closes and reopens the authority over the same file.
  void restart() {
    authority.close();
    _open();
  }

  /// A valid batch of this Scope, distinct per [tag].
  List<Json> sampleBatch(String tag) => [
    {
      'operation': 'createBead',
      'name': 'created',
      'type': taskType,
      'properties': {'title': 'batch $tag'},
    },
    {
      'operation': 'createLink',
      'type': blocksType,
      'source': '@created',
      'target': 'beads/item',
    },
  ];

  String tokenOf(Json receipt) => (receipt['id']! as String).split('/').last;
}

void main() {
  late Directory directory;
  late _World world;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('bdp-http-contracts-');
    world = _World(directory);
  });

  tearDown(() {
    world.authority.close();
    directory.deleteSync(recursive: true);
  });

  final cases = (fixture('http-contracts')['cases']! as List).cast<Json>();

  test('every case is run or named as out of the subset', () {
    final ids = {for (final c in cases) c['id']};
    expect(ids.containsAll(_outOfSubset.keys), isTrue);
    expect(cases, hasLength(76));
  });

  for (final c in cases) {
    final id = c['id']! as String;
    final skip = _outOfSubset[id];
    test(id, skip: skip, () async {
      final context = c['context']! as Json;
      final request = c['request']! as Json;
      final expected = c['response']! as Json;
      final effects = c['effects']! as Json;
      final refusal = context['ordinaryRefusal'] as String?;
      final admission = context['admission'] as Json?;
      var authority = world.authority;

      // The premise, then the target this Scope addresses for the case's
      // kind.
      String receiptToken = world.tokenOf(world.receipt);
      switch (refusal) {
        case 'undisclosed-target':
          receiptToken = 'rcpt-0';
        case 'forgotten-failed-receipt':
          receiptToken = world.tokenOf(world.failed);
          world.clock.now = world.clock.now.add(const Duration(days: 8));
        case 'prior-epoch-receipt':
          authority.reinitialize();
        case 'timed-expiry':
          world.clock.now = world.clock.now.add(const Duration(hours: 1));
      }
      if ((context['recovery'] as Json?)?['event'] == 'restart' &&
          refusal == null) {
        world.restart();
        authority = world.authority;
      }
      final kind = c['kind']! as String;
      final fixtureTarget = request['target']! as String;
      final target = switch (kind) {
        'resource' => 'beads/item',
        'resource-events' => 'beads/item?view=events',
        'receipt' || 'receipt-page' => 'receipts/$receiptToken',
        'changes' => 'changes/?after=${world.checkpoint}',
        'events' => 'events/',
        'snapshot' when fixtureTarget == 'snapshot' => 'snapshot',
        'snapshot' =>
          'snapshot?snapshot=${refusal == 'unknown' || refusal == 'undisclosed' ? 'nope' : world.snapshot}',
        'mutation' => fixtureTarget,
        _ => fail('unmapped kind $kind'),
      };

      // Mutations carry this Scope's sample request, prepared for the
      // narrated key state.
      Object? body;
      final headers = localizeHeaders(request['headers']! as Json, authority);
      if (kind == 'mutation') {
        final sample = target == 'operations/create-bead'
            ? {
                'type': taskType,
                'properties': {'title': 'sample'},
              }
            : {'operations': world.sampleBatch('mutation')};
        body = refusal == 'malformed-request' ? request['body'] : sample;
        if (admission?['keyState'] == 'retained') {
          // A conflicting key was bound to a different request.
          final prior = context['ordinaryStatus'] == 409
              ? {'operations': world.sampleBatch('other')}
              : sample;
          final response = await sendTo(
            world.handler,
            'POST',
            target,
            headers: {...headers, 'accept': 'application/json'},
            body: prior,
          );
          expect(response.statusCode, 200);
        }
      }
      // Resource preconditions name the fixture's illustrative entity tag.
      final entityTag = context['entityTag'] as String?;
      if (entityTag != null) {
        for (final field in ['if-match', 'if-none-match']) {
          final value = headers[field];
          if (value == null) continue;
          headers[field] = value.replaceAll(
            entityTag,
            '"${world.item['revision']}"',
          );
        }
      }

      final before = authority.observe().position;
      final response = await sendTo(
        world.handler,
        request['method']! as String,
        target,
        headers: headers,
        body: body,
      );

      expect(response.statusCode, expected['status']);
      expectFixtureHeaders(response, expected['headers']! as Json, reason: id);
      for (final field in [
        'bdp-scope-epoch',
        'bdp-authorization-view',
        'bdp-scope-position',
      ]) {
        expect(response.headers[field], isNotEmpty, reason: field);
      }
      if (expected['ended'] == true) {
        final text = await response.readAsString();
        final bodyless =
            request['method'] == 'HEAD' ||
            const {304, 406, 412}.contains(expected['status']);
        expect(text.isEmpty, bodyless, reason: 'body presence');
      }

      // Effects: nothing admitted unless the case says so, and a refused
      // unknown key stays unbound.
      final changed = authority.observe().position != before;
      expect(changed, (effects['stateChanges']! as int) > 0, reason: 'state');
      if (kind == 'mutation' &&
          admission?['keyState'] == 'unknown' &&
          admission?['keyBoundAfter'] == false) {
        final retry = await sendTo(
          world.handler,
          'POST',
          target,
          headers: {...headers, 'accept': 'application/json'},
          body: body,
        );
        expect((await jsonOf(retry))['status'], 'completed');
      }
    });
  }
}
