// The bd authority over a real bd store whose events journal is on: it
// follows the journal, a quiet store is never listed, and a human's create
// reaches the changefeed through the journal. Skipped, naming why, where no
// bd runs or the store's version stamp does not name it.
@Timeout(Duration(minutes: 3))
library;

import 'package:bdp/bd.dart';
import 'package:test/test.dart';

import '../support/real_bd.dart';
import '../support/scope.dart';

typedef _Opened = ({BdScopeAuthority authority, RecordingCli bd});

void main() {
  late StampedStore? store;
  late String? absence;

  setUpAll(() async {
    (store, absence) = await StampedStore.create();
    if (store case final on?) {
      await human(on, ['config', 'set', 'events-journal', 'true']);
    }
  });

  tearDownAll(() async => store?.delete());

  /// An authority over the store, polling every 100 ms on a clock that
  /// never moves, so no safety read runs; null with the test skipped naming
  /// why.
  Future<_Opened?> open() async {
    final cli = await stampedCli(store, absence);
    if (cli == null) return null;
    final bd = RecordingCli(cli);
    final authority = await BdScopeAuthority.open(
      bd: bd,
      scope: scope,
      interval: const Duration(milliseconds: 100),
      clock: TestClock().call,
    );
    addTearDown(authority.close);
    return (authority: authority, bd: bd);
  }

  int count(RecordingCli bd, String verb, {int from = 0}) =>
      bd.calls.skip(from).where((call) => call.first == verb).length;

  /// Waits, at most ten seconds, until [bd] has run [n] more `bd events
  /// tail` calls.
  Future<void> ticks(RecordingCli bd, int n) async {
    final target = count(bd, 'events') + n;
    final waited = Stopwatch()..start();
    while (count(bd, 'events') < target) {
      if (waited.elapsed > const Duration(seconds: 10)) {
        fail('waited ten seconds for $n journal ticks');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('opens following the journal', () async {
    final o = await open();
    if (o == null) return;
    expect(o.authority.followsJournal, isTrue);
    expect(o.bd.calls.first, ['config', 'get', 'events-journal', '--json']);
  });

  test('a quiet run of ticks makes no bd list', () async {
    final o = await open();
    if (o == null) return;
    final opened = o.bd.calls.length;
    await ticks(o.bd, 5);
    expect(count(o.bd, 'list', from: opened), 0);
  });

  test("a human's bd create reaches the changefeed through the journal, by "
      'exactly one bd list', () async {
    final o = await open();
    if (o == null) return;
    await ticks(o.bd, 1);
    final mark =
        o.authority.changePage(startNow: true).body['after']! as String;
    final before = o.bd.calls.length;
    final id = await humanCreate(store!, 'through the journal');
    final url = '${scope}beads/${Uri.encodeComponent(id)}';
    await o.authority
        .watch(after: mark)
        .firstWhere(
          (group) => (group['events']! as List<Object?>).cast<Json>().any(
            (event) => event['type'] == 'created' && event['subject'] == url,
          ),
        )
        .timeout(const Duration(seconds: 5));
    await ticks(o.bd, 3);
    expect(count(o.bd, 'list', from: before), 1);
  });
}
