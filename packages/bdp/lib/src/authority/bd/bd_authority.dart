import 'dart:async';
import 'dart:convert';

import 'package:genesis_foundation/genesis_foundation.dart' show effect;

import '../authority.dart';
import '../authority_scope.dart';
import '../identity.dart';
import '../json_text.dart';
import '../local.dart';
import '../operations.dart';
import '../problem.dart';
import '../types.dart';
import 'bd_cli.dart';
import 'bd_rows.dart';
import 'bd_writes.dart';

/// One bd store, read and written through bd's own CLI and JSON, served as a
/// BDP Scope (Transactional subset): in process as a `LocalScope`, and over
/// HTTP through `authorityHandler`.
///
/// **Reads.** Every Resource, page, incident-link view, snapshot, Event
/// Source and changefeed page is served from the last whole read of the
/// store: one `bd list` (and one control query when it lists nothing),
/// taken whole or not at all, never a per-bead read. The read is held in a
/// private in-memory [ScopeAuthority], the projection, so pages, cursors,
/// positions, checkpoints and the changefeed are that authority's. A read
/// that changes something is written into it as one batch, which is one
/// change group dated by the instant the read returned. The store is polled
/// every [interval] after each poll ends, in one of two modes chosen at
/// [open]. When the store's events journal is off, each poll is a whole
/// read. When it is on, each poll reads the journal past the last record
/// seen, and a whole read is taken only when the journal shows a record
/// past it, when its answer cannot be trusted (the call fails, a seq does
/// not rise, or the record last seen no longer reads back with its `ts`),
/// whereupon the journal's head is taken again first, or when no whole read
/// has begun for [safetyInterval]; before that safety read the setting is
/// read again, and a journal turned off drops the authority to polling with
/// whole reads. The journal only signals a change: every projection comes
/// from a whole read. While the last read could
/// not be taken whole, those reads answer `temporarily-unavailable` naming
/// why, until the next whole read; discovery, the Operation Directory, the
/// Type inventory, Type Descriptors and receipts are still served.
///
/// **Writes.** A batch holds one operation, as the discovery's transaction
/// limits advertise; a larger one is refused before admission as
/// `limit-exceeded`, binding no key. `create-bead` and
/// `update-bead-properties` are served; every other operation is refused as
/// `forbidden` before admission. Among them are the guarded text update,
/// which sets description, design and acceptance together at an expected
/// revision; a gate's create, a `create-bead` whose `issue_type` is `gate`,
/// run as `bd gate create` and found again by its key, never made twice;
/// and a gate's resolve, an update closing a gate, run as `bd gate resolve`.
/// Before each write the store is read whole and the operation's expected
/// revision checked against it; the operation then runs as the bd calls
/// `bd_writes.dart` plans for it, and is confirmed by whole reads taken
/// after it, every [confirmInterval] until the store holds every field the
/// write authored or [within] elapses. Reads and writes share one queue, so
/// no poll runs between a write's read before it and its read-back.
final class BdScopeAuthority
    with AuthorityLocalScope
    implements AuthorityScope {
  BdScopeAuthority._(
    this._bd,
    this._projection,
    this._clock, {
    required this.interval,
    required this.confirmInterval,
    required this.within,
    required this.receiptRetention,
    required this.changeBound,
  });

  /// Opens the store [bd] runs over as the Scope [scope]: reads whether its
  /// events journal is on, takes the journal's head when it is, takes the
  /// first whole read, and then polls every [interval] after each poll ends,
  /// until [close]. Every bd call the authority makes is the `config get
  /// events-journal` read of that setting, an `events tail` read of the
  /// journal, a whole read's list, its control query when the list is
  /// empty, or a write's calls; it never runs `bd version`.
  ///
  /// A first read that cannot be taken leaves the Scope unavailable until a
  /// later one is. Throws an [ArgumentError] when [scope] is not a canonical
  /// Scope URL. [clock] dates the change groups and receipts. [snapshotLifetime]
  /// is how long a snapshot's handle is kept, as discovery advertises it.
  /// [confirmInterval], [interval] when not given, is how long the whole
  /// reads that confirm a write wait between them, so a store read seldom
  /// still confirms a write promptly.
  @effect
  static Future<BdScopeAuthority> open({
    required BdCli bd,
    required String scope,
    Duration interval = const Duration(seconds: 2),
    Duration? confirmInterval,
    Duration within = const Duration(seconds: 10),
    Duration receiptRetention = const Duration(days: 7),
    Duration snapshotLifetime = const Duration(minutes: 5),
    int changes = 65536,
    DateTime Function()? clock,
  }) async {
    if (changes < 1) {
      throw ArgumentError.value(changes, 'changes', 'is not positive');
    }
    final readClock = _ReadClock(clock ?? DateTime.now);
    final projection = ScopeAuthority.memory(
      scope: scope,
      clock: readClock.call,
      receiptRetention: receiptRetention,
      snapshotLifetime: snapshotLifetime,
      maximumPageItems: changes,
      maximumOperations: changes,
    );
    projection.installType({
      'id': '${scope}types/bead',
      'name': 'bd bead',
      'description': 'A bead of the bd store; its issue type is a property.',
      'describes': 'bead',
      'conformsTo': <String>[],
    });
    final authority = BdScopeAuthority._(
      bd,
      projection,
      readClock,
      interval: interval,
      confirmInterval: confirmInterval ?? interval,
      within: within,
      receiptRetention: receiptRetention,
      changeBound: changes,
    );
    await authority._serial(() async {
      if (await authority._journalOn()) {
        authority._journal = true;
        await authority._baseline();
      }
      await authority._readWhole();
    });
    authority._schedule();
    return authority;
  }

  final BdCli _bd;
  final ScopeAuthority _projection;
  final _ReadClock _clock;

  /// How long after each poll ends the next begins: a whole read of the
  /// store when polling, a read of its events journal when following it.
  final Duration interval;

  /// How many [interval]s may pass in journal mode before a whole read is
  /// taken though the journal shows no change.
  static const safetyFactor = 30;

  /// The longest a whole read waits in journal mode: [interval] times
  /// [safetyFactor].
  Duration get safetyInterval => interval * safetyFactor;

  /// Whether the authority follows the store's events journal, reading the
  /// store whole only when it signals a change; false when it polls with
  /// whole reads.
  bool get followsJournal => _journal;

  /// How long the whole reads that confirm a write wait between them.
  final Duration confirmInterval;

  /// How long whole reads after a write wait for bd to serve it.
  final Duration within;

  /// How long a receipt's detail, and a failed receipt at all, is retained.
  final Duration receiptRetention;

  /// The most beads and links one read may change.
  final int changeBound;

  /// The page size discovery advertises by default.
  static const defaultPageItems = 50;

  /// The largest page discovery advertises; a larger `limit` is clamped.
  static const maximumPageItems = 200;

  /// The operations one transaction carries.
  static const maximumOperations = 1;

  /// The operations this authority serves; every other one is refused as
  /// `forbidden` before admission.
  static const servedOperations = {
    OperationKind.createBead,
    OperationKind.updateBeadProperties,
  };

  static final _keyPattern = RegExp(r'^[A-Za-z0-9_-]{1,256}$');

  /// The bead Type every bead is served under.
  String get beadType => '${address.scope}types/bead';

  /// The Link Type a bd dependency of [dependencyType] is served under.
  String linkType(String dependencyType) =>
      '${address.scope}types/dependency/${Uri.encodeComponent(dependencyType)}';

  /// Why the last read could not be taken whole, or null when it was.
  String? _unavailable = 'the first whole read of bd has not been taken';

  bool _closed = false;
  Timer? _timer;

  /// Whether the authority follows the store's events journal.
  bool _journal = false;

  /// The last journal seq seen, 0 when the journal held none at the
  /// baseline, and null when no baseline holds.
  int? _seq;

  /// The `ts` of the journal record at [_seq], null when [_seq] is 0.
  String? _anchor;

  /// When the last whole read began, on the authority's clock.
  DateTime? _lastWhole;
  Future<void> _tail = Future.value();

  /// The properties of each served bead, by bd id.
  Map<String, JsonMap> _served = {};

  /// Each served Link's Type, source and target, by its id.
  Map<String, _Link> _servedLinks = {};

  /// The served Link id of each dependency, by the id its first generation
  /// takes.
  Map<String, String> _linkIds = {};

  /// bd ids that left a read: a Scope never reuses an identity.
  final Set<String> _withheld = {};

  /// How many generations of each dependency's Link have been served, by
  /// the id its first generation takes.
  final Map<String, int> _generations = {};

  final Set<String> _linkTypes = {};
  int _reads = 0;
  int _transactions = 0;
  final Map<String, _Retained> _byToken = {};
  final Map<String, _Retained> _byKey = {};

  @override
  ScopeAddress get address => _projection.address;

  @override
  AuthorityTypeRegistry get typeRegistry => _projection.typeRegistry;

  @override
  String get epoch => _projection.epoch;

  /// Takes a whole read of the store now, after every read and write already
  /// queued, and answers once it is applied or refused.
  @effect
  Future<void> refresh() => _serial(_readWhole);

  /// Stops reading the store, waits for the read or write in flight, then
  /// ends every live [watch] stream and drops the projection.
  @override
  @effect
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await _serial(() async {});
    _projection.close();
  }

  // Polling.

  @effect
  void _schedule() {
    if (_closed) return;
    _timer = Timer(interval, _poll);
  }

  @effect
  void _poll() => unawaited(_pollThenSchedule());

  @effect
  Future<void> _pollThenSchedule() async {
    await _serial(_tick);
    _schedule();
  }

  /// One poll: a whole read when polling, and in journal mode a whole read
  /// only when the journal shows a record past [_seq], cannot be trusted, or
  /// no whole read has begun for [safetyInterval].
  @effect
  Future<void> _tick() async {
    if (_closed) return;
    if (!_journal) return _readWhole();
    final seq = _seq;
    if (seq == null) return _rebaseline();
    final (:records, floor: _) = await _journalTail(seq > 0 ? seq - 1 : 0);
    if (records == null) return _rebaseline();
    if (seq > 0) {
      final first = records.firstOrNull;
      if (first == null || first.seq != seq || first.ts != _anchor) {
        return _rebaseline();
      }
    }
    final fresh = seq > 0 ? records.skip(1) : records;
    if (fresh.isNotEmpty) {
      _seq = fresh.last.seq;
      _anchor = fresh.last.ts;
      return _readWhole();
    }
    if (_lastWhole case final last?
        when _clock.now().difference(last) < safetyInterval) {
      return;
    }
    if (!await _journalOn()) {
      _journal = false;
      _seq = null;
      _anchor = null;
    }
    return _readWhole();
  }

  /// Takes a fresh baseline of the journal, then a whole read.
  @effect
  Future<void> _rebaseline() async {
    await _baseline();
    await _readWhole();
  }

  /// Whether `bd config get events-journal` answers that the store's events
  /// journal is on; false when the call fails.
  @effect
  Future<bool> _journalOn() async {
    final BdOutput output;
    try {
      output = await _bd.run(const [
        'config',
        'get',
        'events-journal',
        '--json',
      ]);
    } on BdFailure {
      return false;
    }
    return output.exitCode == 0 && _on(output.stdout);
  }

  /// Whether [printed] says true: as the JSON boolean or text true, an
  /// object whose `value` is either, or the plain text true.
  static bool _on(String printed) {
    final Object? json;
    try {
      json = jsonDecode(printed);
    } on FormatException {
      return printed.trim() == 'true';
    }
    return switch (json) {
      true || 'true' || {'value': true || 'true'} => true,
      _ => false,
    };
  }

  /// Sets [_seq] and [_anchor] from the journal's head: its last record, or
  /// seq 0 and no anchor when it holds none. A head below a truncated
  /// journal's retained window is read from that window's floor. Any other
  /// failure leaves no baseline.
  @effect
  Future<void> _baseline() async {
    _seq = null;
    _anchor = null;
    var answer = await _journalTail(0);
    if (answer case (records: null, :final floor?)) {
      answer = await _journalTail(floor - 1);
    }
    final records = answer.records;
    if (records == null) return;
    _seq = records.lastOrNull?.seq ?? 0;
    _anchor = records.lastOrNull?.ts;
  }

  /// What `bd events tail --since=[since]` answered: its records, in seq
  /// order, or null with the floor of the retained window when bd refused
  /// [since] as below it. Records are null, and the floor too, when the
  /// call fails otherwise, a line is not a record with an integer `seq` and
  /// a text `ts`, or the seqs do not strictly rise.
  @effect
  Future<({List<_Record>? records, int? floor})> _journalTail(int since) async {
    const untrusted = (records: null, floor: null);
    final BdOutput output;
    try {
      output = await _bd.run(['events', 'tail', '--since=$since', '--json']);
    } on BdFailure {
      return untrusted;
    }
    if (output.exitCode != 0) {
      final Object? refusal;
      try {
        refusal = jsonDecode(output.stdout);
      } on FormatException {
        return untrusted;
      }
      return switch (refusal) {
        {'code': 'events_journal_truncated', 'floor': final int floor}
            when floor > 0 =>
          (records: null, floor: floor),
        _ => untrusted,
      };
    }
    final records = <_Record>[];
    for (final line in const LineSplitter().convert(output.stdout)) {
      if (line.trim().isEmpty) continue;
      final Object? json;
      try {
        json = jsonDecode(line);
      } on FormatException {
        return untrusted;
      }
      if (json case {
        'seq': final int seq,
        'ts': final String ts,
      } when records.isEmpty || seq > records.last.seq) {
        records.add((seq: seq, ts: ts));
      } else {
        return untrusted;
      }
    }
    return (records: records, floor: null);
  }

  /// Runs [task] after every task queued before it.
  @effect
  Future<T> _serial<T>(Future<T> Function() task) {
    final call = _after(_tail, task);
    _tail = _settled(call);
    return call;
  }

  @effect
  static Future<T> _after<T>(
    Future<void> previous,
    Future<T> Function() task,
  ) async {
    await previous;
    return task();
  }

  static Future<void> _settled(Future<Object?> call) async {
    try {
      await call;
    } on Object {
      return;
    }
  }

  // Reading the store.

  @effect
  Future<void> _readWhole() async {
    if (_closed) return;
    _lastWhole = _clock.now();
    final refusal = await _take();
    if (_closed) return;
    _unavailable = refusal;
  }

  /// Takes one whole read and applies it; answers why it could not be
  /// taken, or null.
  @effect
  Future<String?> _take() async {
    final Object? listed;
    try {
      listed = await _bd.json(bdListArguments);
    } on BdFailure catch (failure) {
      return 'bd list failed: ${failure.message}';
    }
    final returned = _clock.now();
    if (listed is! List<Object?>) return 'bd list answered no list';
    if (listed.isEmpty) {
      final Object? control;
      try {
        control = await _bd.json(bdControlArguments);
      } on BdFailure catch (failure) {
        return 'bd list read nothing, and the control query failed: '
            '${failure.message}';
      }
      if (control is! Map<String, Object?> || control.isEmpty) {
        return 'bd list read nothing, and the control query found no rows';
      }
    }
    final BdRead read;
    try {
      read = projectBdRows(listed);
    } on FormatException catch (refusal) {
      return refusal.message;
    }
    return _apply(read, returned);
  }

  /// Writes [read] into the projection as one batch dated [returned];
  /// answers why it could not be, or null.
  @effect
  String? _apply(BdRead read, DateTime returned) {
    final beads = {
      for (final MapEntry(:key, :value) in read.beads.entries)
        if (!_withheld.contains(key)) key: value,
    };
    for (final id in beads.keys) {
      if (ScopeAddress.idPathProblem(_segment(id)) case final problem?) {
        return 'bd id $id cannot be a Bead identity: $problem';
      }
    }
    final wanted = <String, _Link>{};
    for (final dependency in read.dependencies) {
      if (!beads.containsKey(dependency.holder)) continue;
      final base = _linkBase(dependency);
      if (ScopeAddress.idPathProblem(address.localId(base).substring(6))
          case final problem?) {
        return 'a dependency of ${dependency.holder} cannot be a Link '
            'identity: $problem';
      }
      wanted[base] = (
        type: linkType(dependency.type),
        source: _beadUrl(dependency.holder),
        target: beads.containsKey(dependency.target)
            ? _beadUrl(dependency.target)
            : 'urn:bd:${Uri.encodeComponent(dependency.target)}',
      );
    }
    final operations = <JsonMap>[];
    final linkIds = <String, String>{};
    final generations = <String, int>{};
    for (final MapEntry(key: base, value: id) in _linkIds.entries) {
      if (wanted[base] == _servedLinks[id]) {
        linkIds[base] = id;
      } else {
        operations.add({'operation': 'deleteLink', 'link': id});
      }
    }
    final gone = [
      for (final id in _served.keys)
        if (!beads.containsKey(id)) id,
    ];
    for (final id in gone) {
      operations.add({'operation': 'deleteBead', 'bead': _beadUrl(id)});
    }
    for (final MapEntry(key: id, value: properties) in beads.entries) {
      final served = _served[id];
      if (served == null) {
        operations.add({
          'operation': 'createBead',
          'id': _beadUrl(id),
          'type': beadType,
          'properties': properties,
        });
      } else if (!jsonEquals(served, properties)) {
        operations.add({
          'operation': 'updateBeadProperties',
          'bead': _beadUrl(id),
          'change': [
            {'op': 'replace', 'path': '', 'value': properties},
          ],
        });
      }
    }
    for (final MapEntry(key: base, value: link) in wanted.entries) {
      if (linkIds.containsKey(base)) continue;
      final generation = (_generations[base] ?? 0) + 1;
      final id = generation == 1 ? base : '$base/$generation';
      generations[base] = generation;
      linkIds[base] = id;
      operations.add({
        'operation': 'createLink',
        'id': id,
        'type': link.type,
        'source': link.source,
        'target': link.target,
        'properties': <String, Object?>{},
      });
    }
    if (operations.length > changeBound) {
      return 'the read changes ${operations.length} beads and links, past '
          'the bound of $changeBound';
    }
    final types = {for (final link in wanted.values) link.type};
    for (final type in types.difference(_linkTypes)) {
      final name = Uri.decodeComponent(type.split('/').last);
      try {
        _projection.installType({
          'id': type,
          'name': 'bd dependency $name',
          'description': 'A bd dependency of type $name.',
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
      } on ArgumentError catch (refusal) {
        return 'the Link Type of bd dependency $name cannot be installed: '
            '${refusal.message}';
      }
      _linkTypes.add(type);
    }
    if (operations.isNotEmpty) {
      final AuthorityReceipt receipt;
      try {
        receipt = _clock.at(
          returned,
          () => _projection.mutate('batch', {
            'operations': operations,
          }, idempotencyKey: 'read-${++_reads}'),
        );
      } on AuthorityProblem catch (problem) {
        return 'the read could not be applied: ${problem.title}';
      }
      if (receipt.status != 'completed') {
        final problem = receipt.problem;
        return 'the read could not be applied: ${problem?['title']}'
            '${problem?['detail'] == null ? '' : ': ${problem!['detail']}'}';
      }
    }
    _withheld.addAll(gone);
    _served = beads;
    _generations.addAll(generations);
    _linkIds = linkIds;
    _servedLinks = {
      for (final MapEntry(key: base, value: id) in linkIds.entries)
        id: wanted[base]!,
    };
    return null;
  }

  static String _segment(String id) => Uri.encodeComponent(id);

  String _beadUrl(String id) => '${address.beads}${_segment(id)}';

  String _linkBase(BdDependency dependency) =>
      '${address.links}${_segment(dependency.holder)}/'
      '${_segment(dependency.type)}/${_segment(dependency.target)}';

  /// The bd id of the served bead at [url], or null.
  String? _bdIdOf(String url) {
    if (!url.startsWith(address.beads)) return null;
    final String id;
    try {
      id = Uri.decodeComponent(url.substring(address.beads.length));
    } on ArgumentError {
      return null;
    }
    return _served.containsKey(id) && _beadUrl(id) == url ? id : null;
  }

  // Reads.

  /// [read], unless the last read could not be taken whole.
  T _whole<T>(T Function() read) {
    if (_unavailable case final why?) {
      throw AuthorityProblem(
        'temporarily-unavailable',
        title: 'The bd store could not be read whole',
        detail: why,
      );
    }
    return read();
  }

  static int? _clamp(int? limit) =>
      limit != null && limit > maximumPageItems ? maximumPageItems : limit;

  @override
  AuthorityRead observe() => _projection.observe();

  /// The projection's Transactional discovery document, advertising one
  /// operation per transaction and pages of [defaultPageItems] by default
  /// and [maximumPageItems] at most.
  @override
  AuthorityRead discoveryDocument() {
    final read = _projection.discoveryDocument();
    final body = jsonCopy(read.body)! as JsonMap;
    final limits = body['limits']! as JsonMap;
    limits['page'] = {
      'defaultItems': defaultPageItems,
      'maximumItems': maximumPageItems,
    };
    limits['transaction'] = {'operations': maximumOperations};
    return AuthorityRead(body, epoch: read.epoch, position: read.position);
  }

  @override
  AuthorityRead operationDirectory() => _projection.operationDirectory();

  @override
  AuthorityRead typeInventory({int? limit, String? cursor}) =>
      _projection.typeInventory(limit: _clamp(limit), cursor: cursor);

  @override
  AuthorityRead typeDescriptor(String id) => _projection.typeDescriptor(id);

  @override
  AuthorityRead resource(String reference) =>
      _whole(() => _projection.resource(reference));

  @override
  AuthorityRead collection(
    AuthorityResourceKind kind, {
    String? type,
    String? conformsTo,
    String? source,
    String? target,
    String? endpoint,
    int? limit,
    String? cursor,
  }) => _whole(
    () => _projection.collection(
      kind,
      type: type,
      conformsTo: conformsTo,
      source: source,
      target: target,
      endpoint: endpoint,
      limit: _clamp(limit),
      cursor: cursor,
    ),
  );

  @override
  AuthorityRead incidentLinkPage(
    String reference, {
    String direction = 'both',
    int? limit,
    String? cursor,
  }) => _whole(
    () => _projection.incidentLinkPage(
      reference,
      direction: direction,
      limit: _clamp(limit),
      cursor: cursor,
    ),
  );

  @override
  AuthorityRead changePage({
    String? after,
    bool startNow = false,
    int? limit,
  }) => _whole(
    () => _projection.changePage(
      after: after,
      startNow: startNow,
      limit: _clamp(limit),
    ),
  );

  /// The projection's changefeed: every group after [after], then each
  /// whole read's group as it is applied. A stream stays open while a read
  /// cannot be taken, and delivers the next whole read's group.
  @override
  @effect
  Stream<JsonMap> watch({String? after}) => _projection.watch(after: after);

  @override
  @effect
  AuthorityRead snapshotDocument() => _whole(_projection.snapshotDocument);

  @override
  AuthorityRead snapshotHandle(String token) =>
      _whole(() => _projection.snapshotHandle(token));

  @override
  AuthorityRead events({String? resource, String? after, int? limit}) => _whole(
    () => _projection.events(
      resource: resource,
      after: after,
      limit: _clamp(limit),
    ),
  );

  @override
  void requireMinimum({
    String? epoch,
    String? view,
    required String position,
    required AuthorityRead observed,
  }) => _projection.requireMinimum(
    epoch: epoch,
    view: view,
    position: position,
    observed: observed,
  );

  /// This authority's receipt at [token] for [principal]; another
  /// principal's, an unknown or a forgotten one is `resource-not-found`.
  @override
  AuthorityRead receipt(
    String token, {
    String principal = authorityAnonymousPrincipal,
  }) {
    final observed = _projection.observe();
    final retained = _byToken[token];
    final body = retained == null || retained.principal != principal
        ? null
        : _project(retained, _clock.now());
    if (body == null) {
      throw AuthorityProblem('resource-not-found', title: bdNoResourceTitle);
    }
    return AuthorityRead(
      body,
      epoch: observed.epoch,
      position: observed.position,
    );
  }

  /// The receipt as served at [now]: its detail until it expires, then the
  /// compact `expired` form for a completed receipt and nothing for a failed
  /// one.
  JsonMap? _project(_Retained retained, DateTime now) {
    final receipt = retained.receipt;
    if (!now.isAfter(retained.expiresAt)) return receipt;
    if (retained.status == 'failed') return null;
    return {
      for (final key in [
        'id', 'status', 'idempotencyKey', 'scopeEpoch', 'authorizationView', //
        'transaction', 'requiredPosition', 'effectPosition',
      ])
        if (receipt.containsKey(key)) key: receipt[key],
      'detail': 'expired',
      'allocated': [
        for (final entry in (receipt['results']! as List).cast<JsonMap>())
          if (entry['outcome'] == 'created')
            {
              'operationIndex': entry['operationIndex'],
              'operationName': ?entry['operationName'],
              'id': (entry['resource']! as JsonMap)['id'],
              'type': (entry['resource']! as JsonMap)['type'],
            },
      ],
    };
  }

  // Mutations.

  /// Submits [body] to the operation [target] as one Mutation Transaction
  /// of one operation, written through bd.
  ///
  /// Decides, in order: the key's spelling (`malformed-request`); an
  /// unserved target or operation (`forbidden`); the request's parse; the
  /// receipt retained under the principal and key (`idempotency-conflict`
  /// for another request, the receipt for the same one, but for a create
  /// whose merge failed, which runs again); more than one operation
  /// (`limit-exceeded`, binding no key); then, in the queue, a whole read
  /// before the write (`temporarily-unavailable` when it cannot be taken,
  /// binding no key), the write, and its confirmation.
  @override
  @effect
  Future<AuthorityReceipt> mutate(
    String target,
    Object? body, {
    required String idempotencyKey,
    String principal = authorityAnonymousPrincipal,
    Map<String, String> inadmissibleNumbers = const {},
    bool admitNew = true,
  }) async {
    if (!_keyPattern.hasMatch(idempotencyKey)) {
      throw AuthorityProblem('malformed-request', title: bdKeyTitle);
    }
    if (ScopeAuthority.unservedTargets.containsValue(target)) {
      throw _unserved(null);
    }
    final List<Operation> operations;
    if (target == 'batch') {
      operations = parseBatch(body, address);
    } else {
      final kind = OperationKind.byTarget(target);
      if (kind == null) {
        throw AuthorityProblem('resource-not-found', title: bdTargetTitle);
      }
      if (!servedOperations.contains(kind)) throw _unserved(null);
      operations = [parseSingleton(kind, body, address)];
    }
    for (final operation in operations) {
      if (!servedOperations.contains(operation.kind)) {
        throw _unserved(
          target == 'batch' ? '${operation.pointer}/operation' : null,
        );
      }
    }
    final fingerprint = semanticFingerprint(
      operations,
      inadmissibleNumbers: inadmissibleNumbers,
    );
    return _serial(
      () => _admit(
        operations,
        fingerprint: fingerprint,
        key: idempotencyKey,
        principal: principal,
        inadmissible: inadmissibleNumbers,
        admitNew: admitNew,
      ),
    );
  }

  @effect
  Future<AuthorityReceipt> _admit(
    List<Operation> operations, {
    required String fingerprint,
    required String key,
    required String principal,
    required Map<String, String> inadmissible,
    required bool admitNew,
  }) async {
    final now = _clock.now();
    final bound = '$principal\n$key';
    if (_byKey[bound] case final retained?) {
      if (retained.status == 'failed' && now.isAfter(retained.expiresAt)) {
        _byKey.remove(bound);
        _byToken.remove(retained.token);
      } else if (retained.fingerprint != fingerprint) {
        throw AuthorityProblem(
          'idempotency-conflict',
          title: bdKeyBoundTitle,
          instance: retained.receipt['id']! as String,
        );
      } else if (!retained.runsAgain) {
        return AuthorityReceipt(
          _project(retained, now)!,
          position: _projection.observe().position,
        );
      }
    }
    if (operations.length > maximumOperations) {
      throw AuthorityProblem(
        'limit-exceeded',
        title: bdTooManyTitle,
        detail: 'this authority writes one operation per transaction',
        limit: 'transaction.operations',
      );
    }
    if (!admitNew) throw const AuthorityNotAdmitted();
    await _readWhole();
    if (_unavailable case final why?) {
      throw AuthorityProblem(
        'temporarily-unavailable',
        title: bdUnreadTitle,
        detail: why,
      );
    }
    final operation = operations.single;
    final number = ++_transactions;
    final token = '$epoch-b$number';
    final before = _projection.observe().position;
    final core = <String, Object?>{
      'id': '${address.receipts}$token',
      'status': 'completed',
      'detail': 'available',
      'idempotencyKey': key,
      'scopeEpoch': epoch,
      'authorizationView': authorityViewToken,
      'transaction': 'b$number',
      'requiredPosition': before,
    };
    final expiresAt = now.add(receiptRetention);
    JsonMap receipt;
    var runsAgain = false;
    try {
      final (outcome, id) = await _write(operation, key, inadmissible);
      final after = _projection.observe().position;
      if (after != before) {
        core['requiredPosition'] = after;
        core['effectPosition'] = after;
      }
      receipt = {
        ...core,
        'results': [
          {
            'operationIndex': operation.index,
            'operationName': ?operation.name,
            'outcome': outcome,
            'resource': _projection.resource(_beadUrl(id)).body,
          },
        ],
        'next': null,
        'expiresAt': instant(expiresAt),
      };
    } on _Failed catch (failure) {
      runsAgain = failure.runsAgain;
      receipt = {
        ...core,
        'status': 'failed',
        'problem': failure.problem.toJson(
          operationIndex: operation.index,
          operationName: operation.name,
        ),
        'expiresAt': instant(expiresAt),
      };
    }
    final retained = _Retained(
      token: token,
      principal: principal,
      fingerprint: fingerprint,
      status: receipt['status']! as String,
      expiresAt: expiresAt,
      receipt: receipt,
      runsAgain: runsAgain,
    );
    _byToken[token] = retained;
    _byKey[bound] = retained;
    return AuthorityReceipt(receipt, position: _projection.observe().position);
  }

  /// Writes [operation] through bd and confirms it; answers its outcome and
  /// the bd id of its bead, or throws [_Failed].
  @effect
  Future<(String, String)> _write(
    Operation operation,
    String key,
    Map<String, String> inadmissible,
  ) async {
    final prefix = operation.pointer;
    final offending = [
      for (final pointer in inadmissible.keys)
        if (pointer == prefix || pointer.startsWith('$prefix/')) pointer,
    ];
    if (offending.isNotEmpty) {
      throw _Failed(
        AuthorityProblem(
          'validation-failed',
          title: bdNumberTitle,
          pointer: offending.first,
          diagnostics: [
            for (final pointer in offending)
              {
                'message':
                    'number at $pointer does not round-trip through binary64',
              },
          ],
        ),
      );
    }
    return switch (operation) {
      final UpdateProperties update => ('updated', await _update(update)),
      final CreateBead create => ('created', await _create(create, key)),
      _ => throw _Failed(_unserved(null)),
    };
  }

  @effect
  Future<String> _update(UpdateProperties operation) async {
    final id = switch (operation.subject) {
      CanonicalRef(:final url) => _bdIdOf(url),
      _ => null,
    };
    if (id == null) {
      throw _Failed(
        AuthorityProblem(
          'resource-not-found',
          title: bdNoResourceTitle,
          pointer: '${operation.pointer}/bead',
        ),
      );
    }
    final record = _projection.resource(_beadUrl(id)).body;
    if (operation.expectedRevision case final expected?
        when expected != record['revision']) {
      throw _Failed(
        AuthorityProblem(
          'revision-mismatch',
          title: bdMovedTitle,
          pointer: '${operation.pointer}/expectedRevision',
        ),
      );
    }
    final BdUpdatePlan plan;
    try {
      plan = planBdUpdate(
        operation,
        id,
        record['properties']! as JsonMap,
        served: _served,
      );
    } on BdWriteRefused catch (refusal) {
      throw _Failed(refusal.problem);
    }
    for (final call in plan.calls) {
      await _call(call, operation);
    }
    if (plan.calls.isNotEmpty) await _confirm(id, _one(plan.differing));
    return id;
  }

  @effect
  Future<String> _create(CreateBead operation, String key) async {
    if (operation.type != beadType) {
      throw _Failed(
        typeRegistry[operation.type] == null
            ? AuthorityProblem(
                'type-not-installed',
                title: bdTypeTitle,
                pointer: '${operation.pointer}/type',
              )
            : AuthorityProblem(
                'validation-failed',
                title: bdLinkTypeTitle,
                pointer: '${operation.pointer}/type',
                diagnostics: [
                  {'message': '${operation.type} describes links'},
                ],
              ),
      );
    }
    if (operation.properties['issue_type'] == 'gate') {
      return _createGate(operation);
    }
    final BdCreatePlan plan;
    try {
      plan = planBdCreate(operation, key);
    } on BdWriteRefused catch (refusal) {
      throw _Failed(refusal.problem);
    }
    final found = [
      for (final MapEntry(key: id, value: properties) in _served.entries)
        if (properties['external_ref'] == plan.ref) id,
    ];
    if (found.length > 1) {
      throw _Failed(
        AuthorityProblem(
          'identity-taken',
          title: bdRefTakenTitle,
          detail: 'bd holds ${found.join(', ')} under external ref ${plan.ref}',
          pointer: '${operation.pointer}/properties',
        ),
      );
    }
    final String id;
    if (found.isNotEmpty) {
      id = found.single;
    } else {
      final output = await _call(plan.create, operation);
      final created = _createdId(output);
      if (created == null) {
        throw _Failed(
          AuthorityProblem(
            'revision-mismatch',
            title: bdNoIdTitle,
            detail:
                'bd create under external ref ${plan.ref} printed no id; '
                'a retry under the same key finds the bead by that ref',
          ),
          runsAgain: true,
        );
      }
      id = created;
    }
    final served = _served[id];
    final merge = [
      for (final MapEntry(key: entry, :value) in plan.metadata.entries)
        if (served == null ||
            plan.differing(served).contains('metadata.$entry'))
          '--set-metadata=$entry=$value',
    ];
    if (merge.isNotEmpty) {
      final call = ['update', ...merge, '--json', '--', id];
      final BdOutput output;
      try {
        output = await _bd.run(call);
      } on BdFailure catch (failure) {
        throw _mergeFailed(id, plan.ref, failure.message);
      }
      if (output.exitCode != 0) {
        throw _mergeFailed(id, plan.ref, bdExplain(output));
      }
    }
    await _confirm(id, _one(plan.differing));
    return id;
  }

  /// Creates the gate [operation] asks for, or finds the one bd already
  /// holds under its key, whatever its status; answers its bd id.
  @effect
  Future<String> _createGate(CreateBead operation) async {
    final BdGateCreatePlan plan;
    try {
      plan = planBdGateCreate(operation);
    } on BdWriteRefused catch (refusal) {
      throw _Failed(refusal.problem);
    }
    final found = [
      for (final MapEntry(key: id, value: properties) in _served.entries)
        if (properties['issue_type'] == 'gate' &&
            properties['await_id'] == plan.key)
          id,
    ];
    if (found.length > 1) {
      throw _Failed(
        AuthorityProblem(
          'identity-taken',
          title: bdGateTakenTitle,
          detail: 'bd holds ${found.join(', ')} under await_id ${plan.key}',
          pointer: '${operation.pointer}/properties',
        ),
      );
    }
    if (!_served.containsKey(plan.blocks)) {
      throw _Failed(
        AuthorityProblem(
          'resource-not-found',
          title: bdNoResourceTitle,
          detail: 'bd serves no bead ${plan.blocks} for the gate to block',
          pointer: '${operation.pointer}/properties/blocks',
        ),
      );
    }
    final String id;
    if (found.isNotEmpty) {
      id = found.single;
    } else {
      final created = _createdId(await _call(plan.create, operation));
      if (created == null) {
        throw _Failed(
          AuthorityProblem(
            'revision-mismatch',
            title: bdNoIdTitle,
            detail:
                'bd gate create under await_id ${plan.key} printed no id; a '
                'retry under the same key finds the gate by that key',
          ),
          runsAgain: true,
        );
      }
      id = created;
    }
    await _confirm(id, plan.differing);
    return id;
  }

  _Failed _mergeFailed(String id, String ref, String why) => _Failed(
    AuthorityProblem(
      'revision-mismatch',
      title: bdStoodTitle,
      detail:
          'the create of $id under external ref $ref stood and the merge of '
          'its metadata did not: $why',
      instance: _beadUrl(id),
    ),
    runsAgain: true,
  );

  static String? _createdId(BdOutput output) {
    final Object? json;
    try {
      json = jsonDecode(output.stdout);
    } on FormatException {
      return null;
    }
    return switch (json) {
      {'id': final String id} when id.isNotEmpty => id,
      [{'id': final String id}] when id.isNotEmpty => id,
      _ => null,
    };
  }

  /// Runs [call], failing [operation] with bd's own explanation when bd
  /// refuses it.
  @effect
  Future<BdOutput> _call(List<String> call, Operation operation) async {
    final BdOutput output;
    try {
      output = await _bd.run(call);
    } on BdFailure catch (failure) {
      throw _Failed(
        AuthorityProblem(
          'revision-mismatch',
          title: bdUnrunTitle,
          detail: failure.message,
        ),
      );
    }
    if (output.exitCode != 0) {
      final explained = bdExplain(output);
      throw _Failed(
        AuthorityProblem(
          'validation-failed',
          title: bdRejectedTitle,
          detail: explained,
          pointer: operation.pointer.isEmpty ? null : operation.pointer,
          diagnostics: [
            {'message': explained},
          ],
        ),
      );
    }
    return output;
  }

  /// [differing] over the bead it confirms alone.
  static BdServedDiffering _one(BdDiffering differing) =>
      (id, served) => switch (served[id]) {
        null => const ['the bead itself'],
        final bead => differing(bead),
      };

  /// Takes whole reads every [confirmInterval] until the store holds every
  /// field [differing] checks of the write of the bead [id], or [within]
  /// elapses.
  @effect
  Future<void> _confirm(String id, BdServedDiffering differing) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      await _readWhole();
      final still = _unavailable == null
          ? differing(id, _served)
          : const ['the bead itself'];
      if (still.isEmpty) return;
      if (elapsed.elapsed >= within || _closed) {
        throw _Failed(
          AuthorityProblem(
            'revision-mismatch',
            title: bdUnconfirmedTitle,
            detail:
                'whole reads of bd for $within after the write of $id still '
                'differ in ${still.join(', ')}',
            instance: _beadUrl(id),
          ),
        );
      }
      await Future<void>.delayed(confirmInterval);
    }
  }

  static AuthorityProblem _unserved(String? pointer) => AuthorityProblem(
    'forbidden',
    title: bdUnservedTitle,
    detail: 'a bd store is written by create-bead and update-bead-properties',
    pointer: pointer,
  );
}

/// One served Link's Type, source and target.
typedef _Link = ({String type, String source, String target});

/// One record of bd's events journal: its position and its timestamp.
typedef _Record = ({int seq, String ts});

/// An admitted operation that failed: its receipt carries [problem].
/// [runsAgain] marks a failure a retry under the same key runs again.
final class _Failed implements Exception {
  const _Failed(this.problem, {this.runsAgain = false});

  final AuthorityProblem problem;
  final bool runsAgain;
}

/// A receipt bound to its principal and key.
final class _Retained {
  const _Retained({
    required this.token,
    required this.principal,
    required this.fingerprint,
    required this.status,
    required this.expiresAt,
    required this.receipt,
    required this.runsAgain,
  });

  final String token;
  final String principal;
  final String fingerprint;
  final String status;
  final DateTime expiresAt;
  final JsonMap receipt;
  final bool runsAgain;
}

/// The projection's clock: the instant a read returned while that read is
/// applied, and the time otherwise.
final class _ReadClock {
  _ReadClock(this._now);

  final DateTime Function() _now;
  DateTime? _pinned;

  DateTime now() => _now().toUtc();

  DateTime call() => _pinned ?? _now();

  /// Runs [apply] with the clock answering [instant].
  T at<T>(DateTime instant, T Function() apply) {
    _pinned = instant;
    try {
      return apply();
    } finally {
      _pinned = null;
    }
  }
}
