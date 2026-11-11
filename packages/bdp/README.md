# bdp

The Dart client for the Bead Protocol (BDP v0, draft) and the SQLite-backed authority
library. It has no grid dependency and may be imported by any package in this
repo.

The wire types are typed from the normative schema bundle (`bdp-v0.schema.json`); the
client keeps the wire shapes exact and does not chase conformance. See
`the-grid-speaks-bdp-work-and-execution-are-two-scopes` (D6) for the subset.

## Libraries

| Library | What it is |
| --- | --- |
| `package:bdp/client.dart` | The client alone, for any platform, the web included: everything below but the authority. |
| `package:bdp/bdp.dart` | The client and the SQLite authority with its HTTP handler. Needs `dart:io`. |
| `package:bdp/bd.dart` | A bd store served as a Scope over bd's CLI (`serve_bd`). Needs `dart:io`. |
| `package:bdp/testing.dart` | Test support. |

## Shape

| Piece | What it is |
| --- | --- |
| Wire types | `BeadRecord`, `LinkRecord`, `Reference` (`UriReference` / `PinnedReference`), `Attribution`, `TypeDescriptor`, `ScopeDiscovery` (profile, version, limits), `OperationDirectory`, `ProblemDetails`, the six `MutationOperation`s and `BatchRequest`, `MutationResult`, `MutationReceipt`, `ChangeGroup` / `StateChange` / `ErasureRecord`, `Event` with its five data types, `EventPage`, `SnapshotManifest`, `ChangefeedPage`. Immutable, value-equal, `fromJson` / `toJson`. |
| Opaque tokens | `Revision`, `Checkpoint`, `ScopePosition`, `ScopeEpoch`, `AuthorizationView`, `TransactionId`, `EventId`, `IdempotencyKey`: compared for equality only and echoed byte for byte. A number where a token belongs is a `FormatException`, never a reinterpretation. |
| `LocalScope` | The operations of one Scope as the kernel consumes them — reads, pages, incident Links, the Type inventory and Type Descriptors, the six singletons, `batch`, receipts and their result pages, finite and live changefeed, snapshot. An in-process authority implements it directly; `ScopeClient` implements it over HTTP. |
| `ScopeClient` | `LocalScope` over an injected `http.Client`. `ScopeClient.discover` follows the Scope's `service-desc` link. |
| `Replica` | A value folding a snapshot and the changefeed for one Authorization View. `apply` returns the next replica or throws `ReplicationException`; a refused group changes nothing. |
| `decodeSse` | WHATWG `text/event-stream` framing. |

```dart
final scope = await ScopeClient.discover(
  Uri.parse('https://beads.example/acme/'),
  httpClient: http.Client(),
);
final task = await scope.readBead('beads/task-42');
final receipt = await scope.batch([
  UpdateBeadProperties(
    bead: 'beads/task-42',
    expectedRevision: task.revision,
    change: PropertyChange([PatchOp.replace('/status', 'closed')]),
  ),
], idempotencyKey: IdempotencyKey.generate());

var replica = await scope.bootstrap();
final subscription = scope.follow(
  ChangefeedStart.after(replica.checkpoint),
  (group) async => replica = replica.apply(group), // persist, then return
);
```

### Failures

- A Problem Details response is a `BdpProblemException` carrying the problem (with
  `code` and `retry`), the HTTP status and any `Retry-After`.
- A bodyless or non-BDP refusal (`304`, `405`, `406`, `412`, `500`) is a
  `BdpHttpException` with its status.
- A success body that does not match its wire shape is a `BdpProtocolException`.
- A Transactional `batch` or singleton that fails after admission is not an exception:
  it is a `failed` `MutationReceipt` carrying the problem.
- A miss is the authority's `resource-not-found` problem. Collection reads return pages;
  an empty page with a non-null `next` is not the end, and the page walkers
  (`allBeads`, `allLinks`, `allIncidentLinks`) follow `next` until it is `null`.

### The durable-checkpoint reconnect rule

`follow` calls `apply` once per change group, in order, one at a time, and advances its
reconnect cursor only when `apply` completes. Every request, including every reconnect,
carries that checkpoint in `after` and never sends `Last-Event-ID`, so a group the
transport delivered but the consumer did not finish applying is delivered again. A
failed `apply`, a protocol violation or a problem such as `cursor-expired` ends the
subscription through `done`. `after-delay` problems, transient bodyless statuses (`408`,
`429`, `500`, `502`, `503`, `504`) and dropped connections are retried, honouring
`Retry-After`. `start=now` is resolved to the head checkpoint with a finite read first;
that read is retried the same way, a dropped continuation resumes at that page, and
`cancel()` aborts it like the SSE request. Do not await
`cancel()` from inside `apply`: it waits for the in-flight `apply` to finish.

## Profile coverage

| Surface | Profile | Status |
| --- | --- | --- |
| Discovery (`service-desc`, discovery document, Operation Directory) | Read+ | Implemented; members validated against the advertised profile; `bdpVersion` other than `0` stops |
| Bead and Link reads by local ID or URL | Read | Implemented |
| Collections with `type`, `conformsTo`, `source`, `target`, `endpoint`, `selector`, `limit`, and `next` | Read | Implemented; the Selector is sent verbatim, percent-encoded |
| Incident Links (`view=links`, `direction`) | Read | Implemented |
| Type inventory and Type Descriptor reads | Read | Implemented (`types`, `nextTypes`, `readTypeDescriptor`) |
| Six singleton mutations with `Idempotency-Key` and optional `expectedRevision` | Read+Update, Transactional | Implemented; inline result on Read+Update, receipt on Transactional |
| `batch` | Transactional | Implemented for the six Resource operations |
| Mutation Receipts and receipt pages | Transactional | Implemented (`readReceipt`, `readReceiptPage`) |
| Finite changefeed (`after`, `genesis`, `start=now`) and SSE changefeed | Transactional | Implemented |
| Snapshot bootstrap (manifest plus both streams, verified) | Transactional | Implemented (`bootstrap`) |
| Event wire types and Event pages | Transactional | Codecs only; Event Source reads are not exposed — the changefeed is the kernel's change signal |
| `properties` view, `include=links` aggregate, alias resolution | Read | Not exposed |
| Minimum-position reads (`BDP-Minimum-Scope-Position`) | Transactional | Not exposed |

Deliberately out:

| Out | Why |
| --- | --- |
| Set mutations (`updateWhere`, `deleteWhere`) | Not in the grid's subset; a batch carrying one is refused by the decoder with `UnsupportedOperation` |
| Aliases (`put-alias`, `delete-alias`, alias URLs) | Not in the subset |
| Version erasure | The replica keeps no history; erasure records are decoded, and a group that leaves an erased version live is refused, but no erasure ledger is kept |
| The History capability | `historicalResolution` and `changeContext` are carried verbatim, not interpreted |
| Authorization views | One principal and one constant view; the view token is checked as a fence, nothing more |
| The `sequence` carrier | Not in the subset |

## Tests

Offline by default: codecs round-trip every message of the Transactional and Read+Update
exchange fixtures under `test/fixtures/bdp/` (see its `README.md` for the upstream
commit) whose schema definition the client models; messages of out-of-subset definitions
(aliases, set mutations, `sequence`) and requests refused as malformed are checked for
refusal instead, as `test/codec_test.dart` lists. The client is driven through an offline
fake `http.Client`, and the changefeed and SSE tests use canned streams.

`test/live_bdptest_test.dart` (tag `live`) launches the upstream `bdptest` reference
server with an advertised Read profile on an ephemeral port and compares its reads with
the reference-domain fixture. It needs `node` on the `PATH` and `BDPTEST_MAIN` set to the
server's built `dist/main.js`; without either it skips.

`test/interop/` holds the two halves to one set of shapes where they overlap: the
operations of `LocalScope` are answered by the same authority twice — in process through
its own `LocalScope`, and over HTTP by a `ScopeClient` talking to `authorityHandler`
through `HandlerClient` (`package:bdp/testing.dart`, an `http.Client` that calls a shelf
handler with no socket) — and the two answers must decode to equal values, refusals
included. That covers discovery, Bead reads, Bead and Link collections and incident Links
(continuations are compared for Bead and Type pages only), the Type inventory, the
`createBead` singleton and `batch`
(carrying creates, updates and deletes), receipts, the finite changefeed, snapshot
bootstrap and the live follow; the other five singletons and Link reads are exercised in
process and over HTTP separately, not compared. Type Descriptor reads are
checked in process only: the handler serves no descriptor documents (see below). What the
handler serves beyond `LocalScope` has no in-process counterpart and is checked over HTTP
alone, in `test/authority/http_test.dart`: the Operation Directory document, Event Source
pages and SSE, snapshot-handle refetch, ETags with `If-Match` / `If-None-Match` and
`HEAD`, method and media-type refusals (`405` / `406` / `415`) and the minimum-position
read context.

## Authority

`ScopeAuthority` is the single writer of one BDP Scope over one SQLite
database (WAL mode) that it opens and owns, and `authorityHandler` serves it
over HTTP with the BDP v0 wire shapes. It is a library, not a binary: a
station opens the authority on a file under its grid home, installs its
Types, and mounts the handler wherever the canonical Scope URL's path is
served. The store itself is not exported, so current state changes only
through a mutation, and every exported name carries the `Authority` prefix
or belongs to `ScopeAuthority`.

`ScopeAuthority` is a `LocalScope`: in process, a consumer reads, mutates and follows it
through the same typed operations a `ScopeClient` performs over HTTP. Each answer to an
operation the HTTP handler serves is the document the handler would serve, decoded with
the client's codecs; a refusal is the `BdpProblemException` the client raises for the
same problem document. `readTypeDescriptor` is the one operation with no HTTP route: a
Type ID is a URL its publisher hosts, so in process the authority answers from the Types
pinned in its store, while a `ScopeClient` dereferences the Type URL itself.

```dart
final authority = ScopeAuthority.file('execution.db', scope: 'http://localhost:8080/execution/')
  ..installType(descriptor, schema: schema);
final LocalScope scope = authority; // or: await ScopeClient.discover(...)
final receipt = await scope.batch([...], idempotencyKey: IdempotencyKey('attempt-7-start'));
var replica = await scope.bootstrap();
scope.follow(ChangefeedStart.after(replica.checkpoint), (group) async {
  replica = replica.apply(group);
});
```

The wire-level surface the HTTP handler drives — `mutate`, `resource`, `collection`,
`incidentLinkPage`, `changePage`, `watch`, `snapshotDocument`, `discoveryDocument` —
answers raw documents and `AuthorityProblem`s.

These members, which act on the world, are marked `@effect` (from `genesis_foundation`), so
`genesis_lint` reports a direct call to one from a build, or from any code that is neither an
`@effect` member nor an effect leaf's lifecycle:
`LocalScope`'s six singletons, `batch`, `follow` and `snapshot`, `ChangefeedSubscription`'s
`cancel` (which ends the follow), and on `ScopeAuthority` also `close`, `reinitialize`,
`installType` (which commits a Type to the store), `mutate`, `watch` (which opens a stream over
the store) and `snapshotDocument` (which retains a snapshot handle). The testing client's `send` is one too:
it delivers a request to the authority's handler, which commits a mutation sent through it.
`test/effect_marks_test.dart` holds every public member of `ScopeAuthority`'s interface,
inherited ones included, to that list or to a list of reads, and analyzes a build that calls
those six, the testing client's `send` and three reads. It also inventories every member of every type, extension and
function the package exports — through `package:bdp/bdp.dart` and `package:bdp/testing.dart`,
inherited members included — and fails on one that is neither `@effect` nor reviewed: the
wire types, tokens, problems, queries and the replica are whitelisted as types — listed once,
they fail the check if they gain an `@effect`, but their members are not reviewed one by one,
so an unmarked member that acted, added to one of them, would pass — and the reads of
`LocalScope` and `ScopeClient`, a Type registry's own members and the functions that make a
value are reviewed member by member. Constructors are classified apart, because the lint
diagnoses calls to `@effect` members and never instance creation: every public constructor
of an exported type that is not a value is listed as acting on nothing or as acting.
`ScopeAuthority.file` and `ScopeAuthority.memory` act — they open, and may initialize, a
store — and are listed so; a build that calls one is not diagnosed.
The testing client's other members are `http`'s, which marks none: a request made through its
`post`, `put` or `delete` from a build is not reported.

Two routes to an effect are not reported. Opening the authority is a constructor, which the
lint does not police. And the lint does not see through a function value: the `Handler` that
`authorityHandler` returns commits and opens streams for the requests it serves, and a call to
it from a build is not reported. `typeRegistry` is a read-only view of the pinned Types;
`install` on it throws `StateError`.

### What is implemented (the Transactional subset)

- The six singleton mutations and the ordered, all-or-nothing `batch` with
  batch-local `@name` references, each under one required idempotency key.
- `expectedRevision` compare-and-swap; a mismatch fails the whole
  transaction. Semantic no-op updates keep their revision and emit nothing.
- Idempotency keys scoped to (Scope, epoch, principal): an identical retry —
  singleton, batch or one-operation batch alike — returns the retained
  receipt without executing; the same key with different semantics is a
  direct `409 idempotency-conflict`. Requests are compared as normalized JSON
  values, by the text `semanticText` writes (exported from `package:bdp/bdp.dart`
  with `isAdmissibleNumber`, the rule by which a number is admitted): member
  order is ignored and numbers compare by exact decimal value,
  never through binary64, so `1`, `1.0` and `1e0`, or `0` and `-0.0`, are one
  request, and `9007199254740992` and `9007199254740993` are two, in process
  and over HTTP alike; two inadmissible literals are one request only when
  they denote the same exact value. A completed receipt's detail expires to
  its compact form (disposition plus allocated identities) and never
  re-executes; its key stays bound to its request until the epoch changes, so
  a different request under it is an `idempotency-conflict` however long ago
  it completed. A failed receipt is forgotten after its retention and its key
  executes anew.
- Exactly one change group per effective transaction, carrying the final
  postimages or tombstones and the ordered `created` / `updated` / `deleted`
  / `linked` / `unlinked` Events with their group ordinals. Admission,
  execution, the group and the receipt commit in one SQLite transaction, and
  current state is written only by applying the group's changes. A Resource
  created and deleted in one transaction contributes no change; its identity
  stays committed. The log is never pruned, by anything.
- The Scope epoch: stable across reopen and restart, replaced by
  `reinitialize()` on any connection, which discards current state and
  receipts and unbinds every idempotency key, receipt, checkpoint (an empty
  epoch's own `<epoch>_0` included), Bead and Link collection cursor, Type
  inventory cursor, Event cursor and snapshot handle of the old epoch: each
  is then `cursor-expired` or `resource-not-found`. `genesis` names no epoch;
  it asks for the current epoch's whole history. The old epoch's groups stay
  in the database, keyed by epoch. Identity non-reuse and the pinned Types
  survive it; their inventory's cursors do not.
- The changefeed: finite pages from `after=<checkpoint>`, `after=genesis` or
  `start=now` (omitting both, or supplying both, is `invalid-parameter`), and
  `watch()`, a stream that joins the backlog to the live tail; over HTTP,
  `text/event-stream` with `id` = checkpoint and `event: change-group`. The
  backlog is read in transactions of at most `backlogBatchGroups` groups
  (256 by default), yielding to the event loop between them, and each of
  them checks that the Scope is still in the epoch the stream started in: a
  reinitialization by any connection during the backlog ends the stream with
  `cursor-expired`, and no group of the new epoch is delivered under the old
  one's checkpoint. The live tail follows the database, not the instance: a
  group this authority commits is delivered at once, after any group another
  connection committed before it; while a file authority has a live stream
  it checks SQLite's `data_version` every `liveTailInterval` (50 ms by
  default) and delivers other connections' groups, or ends the stream with
  `cursor-expired` when another connection reinitialized the Scope. With no
  live stream it does not check. `close()` ends every live stream (done,
  after the groups already delivered), during its backlog too.
- Waiting for locks: a file authority installs its own busy handler before the open's
  first statement, so the open and every later statement wait up to `lockTimeout`
  (10 s by default) for a lock another connection holds, sleeping between attempts as
  SQLite's `busy_timeout` does, and fail with `SQLITE_BUSY` after it. `onLockWait` is
  called on the opening isolate each time a statement finds a lock held, before it
  waits. It runs inside SQLite's busy handler, mid statement, so it must not use the
  authority; if it throws, that statement stops waiting and the throw reaches the caller
  of the open or the operation in place of `SQLITE_BUSY`.
- The database the authority opened, not its pathname. The authority keeps
  the SQLite connection it opened and never re-resolves the path. It does
  not track the file's identity, so it does not detect a file deleted,
  renamed or replaced at that path while it is open, and its live tail
  reports nothing when that happens. SQLite does not support replacing a
  database file under an open connection — it can corrupt the database — so
  replacing the database is not a reinitialization: a station that replaces
  the file closes every authority on it first and opens new ones after.
- Event Sources: the Scope's `events/` and each Resource's `?view=events`,
  as finite pages and SSE.
- Snapshots: a manifest with both streams inline at one position; its handle
  refetches the same manifest — retained in memory while the handle lives,
  reconstructed by folding the log after a restart.
- Strict reads reporting epoch, the one constant Authorization View token
  and position, with the minimum-position read context enforced.
- Type Descriptors with conformance, endpoint constraints and
  external-endpoint policies, pinned in the store: one current contract per
  Type ID, the revision installed last. Installing other content at a
  pinned ID, from any connection, pins a new revision beside the earlier
  ones, named by `authorityTypeRevisionOf` (a digest of the descriptor and
  schema) and listed in installation order by `typeRegistry.revisionsOf`;
  installing the current content again pins nothing, and a revision that
  changes what the Type describes or makes conformance cyclic throws.
  Records written under an earlier revision stay as written, and
  `AuthorityTypeRegistry.project` reads their properties through the
  current one: a diagnostic for each member it no longer declares, then
  its validation. A revision is visible to mutations only once its row
  commits, read back by every connection inside the transaction that
  validates against it, survives `reinitialize()`, and is kept as a deep,
  unmodifiable copy of the installed schema. The
  `types/` inventory pages (`limit`, `cursor`) in canonical-uri order; a
  cursor expires when the pinned Types change or the epoch does.
- A minimal JSON Schema 2020-12 validator. It implements `type`, `enum`,
  `const`, `properties`, `required`, `additionalProperties`, `items` (one
  schema), `minLength` / `maxLength`, `minimum` / `maximum` /
  `exclusiveMinimum` / `exclusiveMaximum`, `minItems` / `maxItems` /
  `uniqueItems`, `minProperties` / `maxProperties`, `pattern`, `allOf` /
  `anyOf` / `oneOf` / `not`, boolean schemas, and `$ref` as a JSON Pointer
  fragment (`#` or `#/…`) naming a subschema of the same document; the
  annotations `title`, `description`, `default`, `examples`, `format`,
  `deprecated`, `readOnly`, `writeOnly` and `$comment` are accepted and
  ignored, and `$schema` (only the 2020-12 dialect) and `$id` only at the
  root. Installation refuses everything else: any other keyword; a keyword
  value of a shape the 2020-12 meta-schema refuses — among them `examples`
  and `enum` that are not arrays, a `required` that is not an array of
  distinct strings, a `type` list that repeats a name, a non-string `title`,
  `description`, `format` or `$comment`, a non-boolean `deprecated`,
  `readOnly` or `writeOnly`, and a root `$id` with a fragment (`default` and
  `const` take any value; the count keywords take an integer, never an
  integral double); an anchor or remote `$ref`, a `$ref` naming no
  subschema or re-entering itself without descending into the instance, an
  embedded `$id` or `$schema`, `unevaluatedProperties` other than `true`, a
  closed properties root, and a `pattern` that does not compile.
- Problem details with the BDP `type` / `code` / `retry` table, strict
  request JSON (duplicate member names and unpaired surrogates are
  `malformed-request`; number literals that do not round-trip through
  binary64 fail their operation as `validation-failed`, decided in time
  linear in the literal, and so does an in-process number that no literal
  admits — an integer past 2^53 that its nearest binary64 value's shortest
  literal does not spell, such as `2^53 + 1` or `2^63 - 1`, or a non-finite
  double),
  `405` / `406` / `415`, ETags, `If-Match` / `If-None-Match` on every read,
  and `HEAD`. A read decides parameters, the target's non-disclosure, the
  minimum-position context, negotiation, then preconditions; problems and
  `406` carry the Scope context fields. An internal fault is a bodyless
  `500` and is reported to the handler's `onFault` (standard error by
  default).
- Discovery and the Operation Directory validate against the bundle's
  `transactionalDiscovery` and `transactionalOperationDirectory`. Discovery
  advertises the authority's limits: its page sizes, the request body bound
  (`limits.request.bodyBytes`, `ScopeAuthority.maximumBodyBytes`, 1 MiB), the
  operations one transaction may carry, and its retention. The body bound is
  advertised in process as over HTTP, so a client sizes what it sends by one
  number either way; `authorityHandler` refuses a longer body as
  `request-too-large`, and a request made in process has no body and is never
  refused for its size.

### What is out

Set mutations (`updateWhere`, `deleteWhere`, the `selector` parameter),
aliases, `sequence`, version erasure, the History capability, owned Links,
`include=links`, authorization views (one principal class, one constant
view), replication of foreign Scopes, and receipt-result paging (the
operation limit never exceeds the page bound, so results always fit inline).
Because a transaction executes inside its admitting SQLite transaction, no
receipt is ever `pending`, no response is ever `202`, and no transient abort
can follow admission. To keep the Transactional shapes, discovery advertises the `aliases`
root and the Operation Directory lists all twelve targets: every alias URL
is `resource-not-found` (no alias ever exists), and `put-alias`,
`delete-alias`, `sequence`, `update-where`, `delete-where` and those
operations inside a `batch` are refused with `forbidden` before admission,
binding no key. The constructor refuses an operation limit above the page
bound, which is what keeps receipts unpaged.

The tests run the vendored `discovery`, `batch`, `changefeed`, `events`,
`snapshots`, `direct-problems`, `receipts`, `receipt-pagination` and
`http-contracts` fixtures; each exchange or case this subset cannot stage
is listed in its test with the reason.

### Revisions and digests

A revision is a local discipline, not a protocol scheme: SHA-256 over the
canonical JSON of the version (members sorted, Dart's number spelling) without
its `revision`, base64url, first 22 characters. Equal versions of one Resource
share a token, which the revision rules permit; no peer derives tokens from
it, so it names no `sha256-jcs` scheme. Positions are `p<n>` within an epoch
(`p0` is genesis), checkpoints are `<epoch>_<n>` (`<epoch>_0` for an empty
epoch), the `genesis` request token excepted, Event IDs are
`<checkpoint>_<ordinal>`, and all of them are opaque to clients.

## The bd authority

`package:bdp/bd.dart` serves one bd store (bd 1.3, a proxied-server store
among them) as a Scope of the Transactional subset, reading and writing it
only through bd's own CLI and the JSON it prints, never its Dolt tables. It
stands in for bd speaking BDP itself. `BdScopeAuthority` implements
`AuthorityScope`, the surface `authorityHandler` serves, so it is a
`LocalScope` in process and a Scope over HTTP; a client above it imports
`bdp.dart` alone and never runs bd. `bd.dart` is apart from `bdp.dart`, and
`test/structure_test.dart` pins that no library a client imports reaches it.

### Reads

Every Resource, page, incident-link view, snapshot, Event Source and
changefeed page is served from the last whole read of the store, held in a
private in-memory `ScopeAuthority` (the projection):

| Read | Arguments |
|---|---|
| the whole read | `bd list --all --include-gates --flat --limit 0 --sort id --json` |
| the control query, when the list is empty | `bd config list --json` |
| the version, once at open | `bd version` |

A read is taken whole or not at all. A list that fails, holds a row that is
no object or names no bead, a dependency that names no target or type, an id
that cannot be spelled as an identity, or more than `changes` (65536 by
default) creates, replaces and deletes, applies nothing; an empty list
applies only when the control query returns rows. While the last read could
not be taken, those reads answer `temporarily-unavailable` naming why, and
discovery, the Operation Directory, the Type inventory, Type Descriptors and
receipts are still served; a live `watch` stays open. A read that changed
something is one change group, dated by the instant its list returned; an
unchanged read commits none. The store is read before and after each write,
and polled `interval` (2 s by default) after each poll ends, in one of two
modes `open` chooses from `bd config get events-journal` (`followsJournal`).
With the store's events journal off, or that setting unreadable, each poll is
a whole read. With it on, each poll runs `bd events tail` past the last
record seen, and the store is read whole only when the journal shows a newer
record, when the journal cannot be trusted (the call fails, its seqs do not
rise, or the record last seen no longer reads back with the same `ts`, as
after a prune or on another replica), whereupon the journal's head is taken
again before the read, or when no whole read has begun for `safetyInterval`
(`interval` times `safetyFactor`, 30), which catches what the journal does not
record, such as `bd sql` writes and rows a `bd dolt pull` merges. Before that
safety read the setting is read again, and a journal turned off drops the
authority to polling with whole reads. The journal is only a signal: every
projection comes from a whole read.

Each bead is served at `<scope>beads/<id>` (the id percent-encoded as a URI
component) under one Type, `<scope>types/bead`, with these properties, under
bd's own JSON keys:

| Property | Carried |
|---|---|
| `id`, `issue_type`, `status`, `priority`, `assignee`, `updated_at` | when the row has it |
| `title`, `description`, `design`, `acceptance_criteria`, `notes` | when some row of the read holds a value for it; empty text in a row without one |
| `external_ref`, `await_id`, `close_reason` | the same; null in a row without one |
| `metadata` | the same; an empty map in a row without one, left out when it holds a number a Scope cannot store |
| `dependencies` | a list of `{depends_on_id, type}`; an empty list only when bd counts none |

A record's revision is the projection's content digest, so any change bd
serves, `updated_at` among them, moves it. Each dependency is a Link at
`<scope>links/<holder>/<type>/<target>` (each part percent-encoded; a Link a
later read serves again after it left takes `/<n>` from its second
generation) under the Link Type `<scope>types/dependency/<type>`, installed
before the first read that holds it. Its source is the holder's URL, and its
target is the target bead's URL when the same read serves it, and
`urn:bd:<target>` otherwise. A bead id that once left a read is withheld if
it comes back: a Scope never reuses an identity.

### Writes

A transaction holds one operation (`limits.transaction.operations` is 1); a
larger batch is refused before admission as `limit-exceeded`
(`transaction.operations`), binding no key. `create-bead` and
`update-bead-properties` are served; `delete-bead`, the Link mutations and
`ScopeAuthority.unservedTargets` are refused as `forbidden` before
admission. Each write is preceded by a whole read (one that cannot be taken
is the direct problem `temporarily-unavailable`, binding no key), checks its
`expectedRevision` against it, runs its bd calls, and is confirmed by whole
reads every `confirmInterval` (`interval` when `open` is given none) until
the store holds every field it wrote, or `within` (10 s by default) elapses.
Every argument rides joined to its flag, a bead id follows `--`, and an
argument holding NUL is refused before anything runs.

An update applies its patch to the served properties and writes each
top-level property that changed, and each metadata key the patch names:

| Change | bd call |
|---|---|
| `metadata/<key>` added or changed, or named by an `add` or `replace` though it holds that value | `--set-metadata=<key>=<value>` on one `bd update ... --json -- <id>`; a text as it is, a number or boolean as its JSON literal |
| `metadata/<key>` removed | `--unset-metadata=<key>` on that update |
| `notes` extended | `--append-notes=<the rest>` on that update, less one leading newline when the notes were not empty |
| `priority`, `issue_type`, `assignee`, `external_ref` | `--priority=`, `--type=`, `--assignee=`, `--external-ref=` on that update |
| `status` to `closed`, with a `close_reason` | `bd close --reason=<close_reason> --json -- <id>`, after the update |
| `status` to `closed`, with no `close_reason` | `bd update --status=closed --json -- <id>`, after the update, so bd's refusal to close a blocked bead reaches the client in bd's own words |
| `status` of a gate (`issue_type` `gate`) to `closed` | `bd gate resolve [--reason=<close_reason>] -- <id>`, after the update, confirmed by the status alone |
| `status` to anything else | `bd update --status=<status> --json -- <id>`, after the update |
| exactly one `add` or `replace` at each of `/description`, `/design` and `/acceptance_criteria`, at an `expectedRevision` | the guarded text update: one `bd update --description=<d> --design=<g> --acceptance=<a> --json -- <id>`, all three in that order even when one is unchanged, confirmed by each served text (one the read does not carry counting as empty) |

The guarded text update is conditional by the whole read before it: a bead
that moved since the revision the client observed is `revision-mismatch`, and
nothing runs. bd has no conditional write, so an edit another actor makes
between that read and the call is still replaced.

Each of these fails `validation-failed` before any call: a change of the
whole properties or of the whole `metadata` map; a notes change that does
not extend the current notes; any other change naming `title`,
`description`, `design` or `acceptance_criteria` (the three texts without an
`expectedRevision`, one or two of them, the three beside any other path, a
value that is not a text), which bd writes only whole over what other actors
wrote; removing a property of the table; a metadata value that is null, a
map, a list, or a text bd would read as a number, boolean or null; a key that
is empty or holds `=`; `close_reason` but with the change that closes the
bead; and any other property. A patch that changes nothing, and names no
metadata key, makes no call.

A create names the Type `<scope>types/bead` (else `type-not-installed`),
supplies no `id` (bd allocates it), carries a non-empty text `title` and only
`description`, `design`, `acceptance_criteria`, `notes`, `assignee`,
`priority` (2 by default), `issue_type` (`task` by default), `external_ref`
and `metadata`. Its external ref is its `external_ref`, or
`bdp:<idempotency key>:<operation name>`, the operation's index standing for
a name it does not declare. A bead the read before it serves under that ref
is the bead, created no second time; two are `identity-taken`. Otherwise it
is one `bd create --title= --type= --priority= [--description= --design=
--acceptance= --assignee= --notes=] --external-ref=<ref> --json`, and a
non-empty `metadata` is then one `bd update` of `--set-metadata=` flags.

A create whose `issue_type` is `gate` is a gate's create. It carries exactly
`issue_type`, `await_id` (the key it is found again by), `blocks` (the bd id
of the bead it holds) and `reason`, each a non-empty text; any other
property, or a missing one, is `validation-failed`, and `blocks`, `reason`
and `await_id` are refused on any other create. A gate the read before it
serves under that `await_id`, open or closed, is the gate, and no call runs;
two are `identity-taken`; a `blocks` bead the read does not serve is
`resource-not-found`. Otherwise it is one `bd gate create --blocks=<work>
--type=human --reason=<reason> --await-id=<key> --json`, confirmed once the
gate is served under that key with a description ending `Reason: <reason>`
and the blocked bead lists a dependency on it.

A failed receipt carries only a code a receipt may carry. bd's refusal of a
call is `validation-failed`, its detail bd's error, read from the JSON
envelope on stdout, then one on stderr, then stderr's text, then stdout's. A
merge after a create that fails, a write the read-backs never confirm, and a
bd that cannot be run are `revision-mismatch` (retry after the state
changes), naming the bead's URL as `instance`; the failed merge's detail
reads `the create of <id> under external ref <ref> stood and the merge of
its metadata did not: <bd's error>`, and a retry under the same key runs
again, finds the bead by its ref, merges, and binds the key to its completed
receipt. Receipts are held in memory for `receiptRetention` (7 days); each
open is a new epoch, so a restart unbinds every key.

A client reads what a failed write was with `bdWriteFailureOf`, exported
from `package:bdp/bd.dart`, never by a problem's title: it answers a
`BdWriteFailure` kind (`refused` before any call, `rejected` by bd with bd's
own words whole, `moved` past the expected revision with nothing written,
`unconfirmed` by the read-backs, `stood` for a create whose merge failed, and
`failed` for everything else), a message, and the bead's URL when the
problem names one.

### The program

`dart compile exe packages/bdp/bin/serve_bd.dart -o build/bdp/serve_bd`, run
from the workspace root into a directory that exists, builds the server:

```
Usage: serve_bd --store=<directory> [--port=<n>] [--scope=<url>] [--actor=<name>] [--interval-ms=<n>] [--bd=<executable>]
```

| Flag | Default |
|---|---|
| `--store=<directory>` | required: the directory whose `.beads` is the store |
| `--port=<n>` | 0, a free port on 127.0.0.1 |
| `--scope=<url>` | `http://127.0.0.1:<port>/` |
| `--actor=<name>` | `bdp` |
| `--interval-ms=<n>` | 2000 |
| `--bd=<executable>` | `bd` |

A bad or missing flag exits 64 with the usage. Once it answers it prints
three lines, in order, and serves until SIGINT or SIGTERM:

```
bd: <the bd version line, read once as it starts>
polling every <n> ms
service description: <scope>bdp.json
```

The second line names the mode: `polling every <n> ms` over a store whose
events journal is off, and over one whose journal is on:

```
reading the events journal every <n> ms, and the store whole at least every <n × 30> ms
```

Discovery advertises pages of 50 items by default and 200 at most; a larger
`limit` is clamped to 200. `serveBdStore` is the program's work, in process.
