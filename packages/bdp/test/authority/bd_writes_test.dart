// Writes through the bd authority against a real bd store in proxied-server
// mode: each is seen both through the Scope and by a human's own bd list,
// beside what another actor wrote. Skipped, naming why, where no bd runs or
// the store's version stamp does not name it.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';

import 'package:bdp/bd.dart';
import 'package:bdp/bdp.dart';
import 'package:test/test.dart';

import '../support/real_bd.dart';
import '../support/scope.dart';

typedef _Opened = ({BdScopeAuthority authority, RecordingCli bd});

void main() {
  late StampedStore? store;
  late String? absence;
  _Opened? opened;

  setUpAll(() async {
    (store, absence) = await StampedStore.create();
  });

  tearDownAll(() async => store?.delete());

  tearDown(() async {
    await opened?.authority.close();
    opened = null;
  });

  /// An authority over the store, or null with the test skipped naming why.
  Future<_Opened?> open() async {
    final cli = await stampedCli(store, absence);
    if (cli == null) return null;
    final bd = RecordingCli(cli);
    final authority = await BdScopeAuthority.open(
      bd: bd,
      scope: scope,
      interval: const Duration(milliseconds: 100),
    );
    return opened = (authority: authority, bd: bd);
  }

  String url(String id) => '${scope}beads/${Uri.encodeComponent(id)}';

  /// The bead [id] as a human's own `bd list --all --json` shows it.
  Future<Json> humanRow(String id) async {
    final rows = await human(store!, [
      'list',
      '--all',
      '--flat',
      '--limit',
      '0',
      '--json',
    ]);
    return (rows! as List<Object?>).cast<Json>().singleWhere(
      (row) => row['id'] == id,
    );
  }

  Future<AuthorityReceipt> update(
    BdScopeAuthority authority,
    String id,
    List<Json> change, {
    required String key,
  }) => authority.mutate('update-bead-properties', {
    'bead': url(id),
    'change': change,
  }, idempotencyKey: key);

  test('a metadata change merges per key and keeps the key another actor '
      'set', () async {
    final o = await open();
    if (o == null) return;
    final id = await humanCreate(store!, 'metadata');
    await human(store!, [
      'update',
      '--set-metadata=theirs=kept',
      '--json',
      '--',
      id,
    ]);
    await o.authority.refresh();
    final receipt = await update(o.authority, id, [
      {'op': 'add', 'path': '/metadata/mine', 'value': 'added'},
      {'op': 'add', 'path': '/metadata/count', 'value': 2},
    ], key: 'merge');
    expect(receipt.status, 'completed', reason: '${receipt.json}');
    expect(o.bd.writes, [
      [
        'update',
        '--set-metadata=count=2',
        '--set-metadata=mine=added',
        '--json',
        '--',
        id,
      ],
    ]);
    expect((await humanRow(id))['metadata'], {
      'theirs': 'kept',
      'mine': 'added',
      'count': 2,
    });
    final served = await o.authority.readBead(url(id));
    expect(served.properties['metadata'], {
      'theirs': 'kept',
      'mine': 'added',
      'count': 2,
    });
  });

  test('a notes change that extends the notes is appended and keeps the '
      'note another actor wrote', () async {
    final o = await open();
    if (o == null) return;
    final id = await humanCreate(store!, 'notes');
    await human(store!, [
      'update',
      '--append-notes=theirs',
      '--json',
      '--',
      id,
    ]);
    await o.authority.refresh();
    final receipt = await update(o.authority, id, [
      {'op': 'replace', 'path': '/notes', 'value': 'theirs\nmine'},
    ], key: 'append');
    expect(receipt.status, 'completed', reason: '${receipt.json}');
    expect(o.bd.writes.single, contains('--append-notes=mine'));
    expect((await humanRow(id))['notes'], 'theirs\nmine');
    expect(
      (await o.authority.readBead(url(id))).properties['notes'],
      'theirs\nmine',
    );
  });

  test('a notes change that does not extend the notes, a change of the '
      'whole metadata map and a property bd has no write verb for each fail '
      'validation-failed and leave bd unchanged', () async {
    final o = await open();
    if (o == null) return;
    final id = await humanCreate(store!, 'refused');
    await human(store!, [
      'update',
      '--append-notes=theirs',
      '--set-metadata=theirs=kept',
      '--json',
      '--',
      id,
    ]);
    await o.authority.refresh();
    final before = await humanRow(id);
    for (final (index, change) in <List<Json>>[
      [
        {'op': 'replace', 'path': '/notes', 'value': 'mine'},
      ],
      [
        {
          'op': 'replace',
          'path': '/metadata',
          'value': {'mine': 'v'},
        },
      ],
      [
        {'op': 'remove', 'path': '/metadata'},
      ],
      [
        {'op': 'replace', 'path': '/updated_at', 'value': 'someday'},
      ],
    ].indexed) {
      final receipt = await update(o.authority, id, change, key: 'r$index');
      expect(receipt.status, 'failed', reason: '$change');
      expect(receipt.problem!['code'], 'validation-failed');
    }
    expect(o.bd.writes, isEmpty);
    expect(jsonEncode(await humanRow(id)), jsonEncode(before));
  });

  // bd 1.3.2 runs no ship in proxied-server mode, the mode every store here
  // is made in: on a closed bead the label adds land in the human's own list
  // and the ship comes back as bd's own refusal, carried unchanged.
  test('a closed human bead gains an ordinary label and the export label '
      'through bd label add, seen in the human\'s own list, and the ship bd '
      'refuses in proxied-server mode is the write\'s refusal', () async {
    final o = await open();
    if (o == null) return;
    final id = await humanCreate(store!, 'shipped');
    await human(store!, ['close', '--reason=done', '--json', '--', id]);
    await o.authority.refresh();
    final receipt = await update(o.authority, id, [
      {'op': 'add', 'path': '/labels/-', 'value': 'ready'},
      {'op': 'add', 'path': '/labels/-', 'value': 'provides:$id'},
    ], key: 'ship');
    expect(o.bd.writes, [
      ['label', 'add', '--json', '--', id, 'ready'],
      ['label', 'add', '--json', '--', id, 'export:$id'],
      ['ship', '--json', '--', id],
    ]);
    expect(receipt.status, 'failed', reason: '${receipt.json}');
    expect(receipt.problem!['title'], 'bd refused the write');
    expect(receipt.problem!['detail'], contains('proxied-server'));
    final labels = (await humanRow(id))['labels']! as List<Object?>;
    expect(labels, containsAll(['ready', 'export:$id']));
    expect(labels, isNot(contains('provides:$id')));
  });

  test('a provides label on an open human bead is refused with bd\'s reason, '
      'never forced, and leaves no provides label', () async {
    final o = await open();
    if (o == null) return;
    final id = await humanCreate(store!, 'unshipped');
    await o.authority.refresh();
    final receipt = await update(o.authority, id, [
      {'op': 'add', 'path': '/labels/-', 'value': 'provides:$id'},
    ], key: 'refused-ship');
    expect(receipt.status, 'failed', reason: '${receipt.json}');
    expect(receipt.problem!['title'], 'bd refused the write');
    expect(
      receipt.problem!['detail'],
      isA<String>().having((detail) => detail.isNotEmpty, 'non-empty', isTrue),
    );
    for (final call in o.bd.calls) {
      expect(call, isNot(contains('--force')), reason: '$call');
    }
    final labels = [...?(await humanRow(id))['labels'] as List<Object?>?];
    expect(
      labels.whereType<String>().where(
        (label) => label.startsWith('provides:'),
      ),
      isEmpty,
    );
  });

  test('a change of status to closed goes through bd close', () async {
    final o = await open();
    if (o == null) return;
    final id = await humanCreate(store!, 'closing');
    await o.authority.refresh();
    final receipt = await update(o.authority, id, [
      {'op': 'replace', 'path': '/status', 'value': 'closed'},
      {'op': 'add', 'path': '/close_reason', 'value': 'done'},
    ], key: 'close');
    expect(receipt.status, 'completed', reason: '${receipt.json}');
    expect(o.bd.writes, [
      ['close', '--reason=done', '--json', '--', id],
    ]);
    final row = await humanRow(id);
    expect(row['status'], 'closed');
    expect(row['close_reason'], 'done');
  });

  test('a gate created over a human\'s bead blocks it in the human\'s own '
      'list, a retry finds it, and its close through the Scope is bd gate '
      'resolve, seen closed by the human', () async {
    final o = await open();
    if (o == null) return;
    final work = await humanCreate(store!, 'gated');
    await o.authority.refresh();
    const key = 'https://station.test/execution/beads/attempt-1/gate';
    final body = {
      'type': o.authority.beadType,
      'properties': {
        'issue_type': 'gate',
        'await_id': key,
        'blocks': work,
        'reason': 'the breaker tripped',
      },
    };
    final opened = await o.authority.mutate(
      'create-bead',
      body,
      idempotencyKey: 'gate',
    );
    expect(opened.status, 'completed', reason: '${opened.json}');
    expectSchema(opened.json, 'mutationReceipt');
    expect(o.bd.writes.single.take(2), ['gate', 'create']);
    final gate =
        ((opened.results.single['resource']! as Json)['properties']!
                as Json)['id']!
            as String;
    final blocked = await humanRow(work);
    expect(
      (blocked['dependencies']! as List<Object?>).cast<Json>().map(
        (dependency) => dependency['depends_on_id'],
      ),
      contains(gate),
    );
    final again = await o.authority.mutate(
      'create-bead',
      body,
      idempotencyKey: 'gate-again',
    );
    expect(again.status, 'completed', reason: '${again.json}');
    expect(
      ((again.results.single['resource']! as Json)['properties']!
          as Json)['id'],
      gate,
    );
    expect(o.bd.writes, hasLength(1), reason: 'a retry opens no second gate');
    final resolved = await update(o.authority, gate, [
      {'op': 'replace', 'path': '/status', 'value': 'closed'},
      {'op': 'add', 'path': '/close_reason', 'value': 'the station closed it'},
    ], key: 'resolve');
    expect(resolved.status, 'completed', reason: '${resolved.json}');
    expectSchema(resolved.json, 'mutationReceipt');
    expect(o.bd.writes.last, [
      'gate',
      'resolve',
      '--reason=the station closed it',
      '--',
      gate,
    ]);
    final gates = (await human(store!, bdListArguments))! as List<Object?>;
    expect(
      gates.cast<Json>().singleWhere((row) => row['id'] == gate)['status'],
      'closed',
    );
  });

  test('the guarded text update over a human\'s bead is seen whole in the '
      'human\'s own list, beside the notes the human wrote', () async {
    final o = await open();
    if (o == null) return;
    final id = await humanCreate(store!, 'refined');
    await human(store!, [
      'update',
      '--description=first draft',
      '--append-notes=theirs',
      '--json',
      '--',
      id,
    ]);
    await o.authority.refresh();
    final revision = (await o.authority.readBead(url(id))).revision.value;
    final receipt = await o.authority.mutate('update-bead-properties', {
      'bead': url(id),
      'expectedRevision': revision,
      'change': [
        {'op': 'add', 'path': '/description', 'value': 'decided'},
        {'op': 'add', 'path': '/design', 'value': 'Step 1. Do it.'},
        {'op': 'add', 'path': '/acceptance_criteria', 'value': 'AC1: holds.'},
      ],
    }, idempotencyKey: 'text');
    expect(receipt.status, 'completed', reason: '${receipt.json}');
    expectSchema(receipt.json, 'mutationReceipt');
    expect(o.bd.writes, [
      [
        'update',
        '--description=decided',
        '--design=Step 1. Do it.',
        '--acceptance=AC1: holds.',
        '--json',
        '--',
        id,
      ],
    ]);
    final row = await humanRow(id);
    expect(row['description'], 'decided');
    expect(row['design'], 'Step 1. Do it.');
    expect(row['acceptance_criteria'], 'AC1: holds.');
    expect(row['notes'], 'theirs');
  });

  test(
    'a create with no metadata is one bd call, and one carrying metadata '
    'is the create under its external ref, then one merging update',
    () async {
      final o = await open();
      if (o == null) return;
      final plain = await o.authority.mutate('create-bead', {
        'type': o.authority.beadType,
        'properties': {'title': 'plain'},
      }, idempotencyKey: 'plain');
      expect(plain.status, 'completed', reason: '${plain.json}');
      expect(o.bd.writes, hasLength(1));
      expect(o.bd.writes.single, contains('--external-ref=bdp:plain:0'));
      final carried = await o.authority.mutate('batch', {
        'operations': [
          {
            'operation': 'createBead',
            'name': 'carried',
            'type': o.authority.beadType,
            'properties': {
              'title': 'carried',
              'metadata': {'k': 'v'},
            },
          },
        ],
      }, idempotencyKey: 'meta');
      expect(carried.status, 'completed', reason: '${carried.json}');
      final writes = o.bd.writes.skip(1).toList();
      expect(writes, hasLength(2));
      expect(writes.first.first, 'create');
      expect(writes.first, contains('--external-ref=bdp:meta:carried'));
      final id = writes.last.last;
      expect(writes.last, ['update', '--set-metadata=k=v', '--json', '--', id]);
      final row = await humanRow(id);
      expect(row['external_ref'], 'bdp:meta:carried');
      expect(row['metadata'], {'k': 'v'});
    },
  );

  test(
    'a create whose merge fails stays findable by its external ref, and '
    'a retry under the same key merges instead of creating it again',
    () async {
      final o = await open();
      if (o == null) return;
      var failing = true;
      o.bd.intercept = (arguments) {
        if (failing &&
            arguments.first == 'update' &&
            arguments.any(
              (argument) => argument.startsWith('--set-metadata='),
            )) {
          failing = false;
          return BdOutput(
            exitCode: 1,
            stdout: jsonEncode({'error': 'injected merge failure'}),
          );
        }
        return null;
      };
      final body = {
        'type': o.authority.beadType,
        'properties': {
          'title': 'findable',
          'metadata': {'k': 'v'},
        },
      };
      const ref = 'bdp:findable:0';
      final failed = await o.authority.mutate(
        'create-bead',
        body,
        idempotencyKey: 'findable',
      );
      expect(failed.status, 'failed');
      expectSchema(failed.json, 'mutationReceipt');
      final problem = failed.problem!;
      expect(problem['operationIndex'], 0);
      final byRef = await human(store!, [
        'list',
        '--all',
        '--flat',
        '--limit',
        '0',
        '--external-ref=$ref',
        '--json',
      ]);
      expect(byRef, hasLength(1));
      final id = ((byRef! as List<Object?>).single! as Json)['id']! as String;
      expect(problem['instance'], url(id));
      expect(
        problem['detail'],
        allOf(
          contains(ref),
          contains('the create of $id'),
          contains('stood and the merge of its metadata did not'),
          contains('injected merge failure'),
        ),
      );
      final retried = await o.authority.mutate(
        'create-bead',
        body,
        idempotencyKey: 'findable',
      );
      expect(retried.status, 'completed', reason: '${retried.json}');
      expect(retried.results.single['outcome'], 'created');
      expect((retried.results.single['resource']! as Json)['id'], url(id));
      expect(o.bd.writes.where((call) => call.first == 'create'), hasLength(1));
      final again = await human(store!, [
        'list',
        '--all',
        '--flat',
        '--limit',
        '0',
        '--external-ref=$ref',
        '--json',
      ]);
      expect(again, hasLength(1));
      expect(((again! as List<Object?>).single! as Json)['metadata'], {
        'k': 'v',
      });
    },
  );
}
