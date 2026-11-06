# Changelog

## Unreleased

- The bd authority serves the Work Scope's writes (grid-1c4c). An update of exactly
  `/description`, `/design` and `/acceptance_criteria` at an `expectedRevision` is the guarded
  text update, one `bd update` of all three; every other change naming a whole-text field, the
  title in any change among them, is still `validation-failed`. A close carrying no
  `close_reason` is `bd update --status=closed`, a gate's close is `bd gate resolve`, and a
  `create-bead` whose `issue_type` is `gate` is `bd gate create`, found again by its
  `await_id`. A metadata key a patch names is merged even when the read before holds it.
  `BdScopeAuthority.open` takes `confirmInterval`, the wait between the reads that confirm a
  write; `package:bdp/bd.dart` exports `BdWriteFailure` and `bdWriteFailureOf`, which read a
  failed write's receipt; and bd's refusal of a call and a supplied bead id carry the
  `diagnostics` a `validation-failed` receipt problem requires.
- A bd store is served as a Scope over bd's own CLI and JSON (grid-cyw,
  `a-bdp-server-over-bds-cli-stands-in-for-bd-until-bd-speaks-bdp`, proposed).
  `AuthorityScope` is the surface `authorityHandler` serves and the
  in-process binding decodes; `ScopeAuthority` implements it unchanged, and
  `authorityHandler` takes any `AuthorityScope`, awaiting its `mutate`.
  `package:bdp/bd.dart`, apart from `bdp.dart`, holds `BdScopeAuthority`, which
  serves the last whole `bd list` as a Scope with a polled changefeed and writes
  one operation per transaction through bd's own verbs; `serveBdStore`, which
  serves it over HTTP; and the `serve_bd` program.
- `package:bdp/bd.dart` exports `bdListArguments`, the bd authority's whole read, for a writer
  that lists before it writes (grid-dip), and `BdScopeAuthority.open` takes `snapshotLifetime`,
  how long a snapshot's handle is kept and what discovery advertises as
  `maximumSnapshotLifetime`; it defaults to five minutes, as before. `BdScopeAuthority.open`
  no longer reads bd's version, so a bd whose `bd version` fails still opens and is served, and
  `BdScopeAuthority.bdVersion` is gone; `serveBdStore` reads the version once as it starts,
  before it opens the authority, and `BdStoreServer.bdVersion` holds it.
- The package's tests run from the generated `test/all_test.dart` (grid-1tq,
  `a-package-runs-its-tests-from-one-generated-entry-and-only-a-file-the-tool-lists-runs-apart`,
  proposed), which calls every test file's `main` under a group named by its path; a plain
  `dart test` runs it through `dart_test.yaml` `paths:`, and no file runs apart. Tests a run ran:
  548 before, 549 after (the new `test/test_entry_test.dart`).
  The gate's wall time on this host: 522 s before, 197 s after; the CI gate job took 23.2 and
  21.7 minutes before.
- A Type installed with other content at a pinned Type ID is pinned as a new revision beside
  the earlier ones instead of refused (grid-29q). `ScopeAuthority.installType` answers the
  `AuthorityTypeRevision` it pinned, null when the content is identical to the current
  revision; `AuthorityTypeRegistry.revisionsOf` lists a Type's revisions in installation order,
  every other member answers the current one, and `AuthorityTypeRegistry.project` reads
  properties written under an earlier revision through the current one. A revision is named by
  `authorityTypeRevisionOf`, a digest of its descriptor and schema. A revision that changes
  what the Type describes, or makes conformance cyclic, throws `ArgumentError`. An existing
  store gains an empty `type_revisions` table; nothing in it moves.

**Breaking:** `ScopeAuthority.mutate`'s `inadmissibleNumbers` maps each pointer to the exact
decimal value its literal denotes, rather than listing the pointers. Numbers enter request
identity in a new spelling, so a retry of a request carrying a number whose receipt was
retained before the upgrade is an `idempotency-conflict` rather than a replay. Waiting does
not resolve it: a completed receipt keeps the fingerprint its key is bound to for the life of
its epoch — past its retention only its detail expires — and only a failed receipt is
forgotten. Nothing migrates in the development line: a store holding receipts from before the
upgrade is reinitialized before such retries are relied on. `reinitialize()` deletes every
Bead, Link and receipt and starts a new epoch, so it discards the store's current state, not
only its receipts; the pinned Types and the old epoch's change groups survive it.

- Every authority advertises its request body bound in its discovery,
  `limits.request.bodyBytes` = `ScopeAuthority.maximumBodyBytes` (1 MiB), in process as over
  HTTP, and `authorityHandler` refuses a longer body as `request-too-large`.
- `isAdmissibleNumber` and `semanticText` are exported from `package:bdp/bdp.dart`: the rule by
  which an authority admits a number, and the text by which it identifies a JSON value.
- `ScopeAuthority`'s `close`, `reinitialize`, `installType`, `mutate`, `watch` and
  `snapshotDocument` are marked `@effect`, and so is `ChangefeedSubscription.cancel`, so
  `genesis_lint` reports a direct call to any of them from a build or from code that is
  neither an `@effect` member nor an effect leaf's lifecycle; a call through a function value,
  and a constructor, are not diagnosed. `HandlerClient.send`, which delivers a request to the
  authority's handler, is marked `@effect` too. Every member of every type, extension and function the package exports is
  held, by a test over the analyzer's element model, to `@effect` or a reviewed list of
  members that act on nothing; the value types are listed once, as types, not member by
  member. Every public constructor of an exported type that is not a value is classified as
  acting on nothing or as acting — `ScopeAuthority.file` and `.memory` act, and the lint,
  which sees member calls only, does not diagnose them.
- A file authority waits out another connection's lock with a busy handler of its own,
  installed before the open's first statement: every statement waits up to `lockTimeout`
  (10 s by default) before failing with `SQLITE_BUSY`, and `onLockWait` is called each time
  one finds a lock held. It runs inside SQLite's busy handler and must not use the authority;
  if it throws, the statement stops waiting and the throw reaches the caller of the open or
  operation in place of `SQLITE_BUSY`.
- Requests compare numbers as exact decimals: `9007199254740992` and `9007199254740993` under
  one key are an `idempotency-conflict`, not a replay, in process as over HTTP, and two
  inadmissible literals that parse to one double are two requests. Schema `enum`, `const` and
  `uniqueItems`, and no-op detection, compare numbers the same way.
- An in-process integer is admitted only when it round-trips through binary64 as a literal
  would: `2^62` and `2^63 - 1` are now refused, as they always were over HTTP. A non-finite
  double fails its operation instead of throwing.
- A `watch` backlog is read in transactions of at most `backlogBatchGroups` groups, yielding
  between them, and ends with `cursor-expired` if the Scope is reinitialized during it; `close`
  ends a watcher mid-backlog.
- Type inventory cursors carry their epoch, so every cursor expires across a reinitialization.
- Installing a Type refuses `examples` that is not an array, a repeated `required` or `type`
  entry, and a root `$id` with a fragment.

## 0.1.0-dev.2

**Breaking:** an empty Scope's snapshot checkpoint is `<epoch>_0`, not `genesis`; installing a
Type refuses schema constructs the validator does not implement.

- Live observation follows the database: a file authority with a live watcher delivers groups
  other connections commit, and ends the watcher with `cursor-expired` when another connection
  reinitializes the Scope. `close()` ends every watcher.
- Idempotency compares requests by value: `1`, `1.0` and `1e0`, or `0` and `-0.0`, are one
  request.
- Checkpoints and Bead and Link collection cursors carry their epoch, so neither continues
  across a reinitialization.
- A Type is pinned once per ID across connections, validated against the store's pinned
  contract, and kept as an unmodifiable deep copy.
- The `types/` inventory pages in canonical-uri order with `limit` and `cursor`; the HTTP
  changefeed refuses `after` together with `start=now`.
- Cancelling a `follow` does not wait on an idle SSE body from a client that ignores aborts.
- The members of `LocalScope` that act on a Scope — `snapshot`, `follow`, the six singleton
  mutations and `batch` — and `bootstrap` are marked `@effect` (from the dependency-free
  `genesis_foundation`), on the interface and on `ScopeClient`'s and the authority's
  implementations, so `genesis_lint` polices where they are called.

## 0.1.0-dev.1

- BDP v0 wire types typed from the schema bundle, with value equality and JSON codecs
  that echo opaque tokens byte for byte.
- `LocalScope`, the Scope operations an in-process authority implements.
- `ScopeClient`: discovery, reads, paginated collections with Selectors, incident Links,
  the six singleton mutations, `batch`, receipts, finite and SSE changefeed with the
  durable-checkpoint reconnect rule, and snapshot bootstrap.
- `Replica`: atomic change-group application over a verified snapshot.
- The authority: `ScopeAuthority` and `authorityHandler`, one BDP Scope (Transactional
  subset) over SQLite with its change-group log, receipts, changefeed, Event Sources and
  snapshots.
- `ScopeAuthority` is a `LocalScope`: in process it answers the client's typed operations
  with the documents its HTTP handler serves, decoded by the client's codecs, except Type
  Descriptor reads, which it answers from its pinned Types because the handler serves no
  descriptor documents.
- `package:bdp/testing.dart`: `HandlerClient`, an `http.Client` that answers from a shelf
  handler in process, so a `ScopeClient` can drive `authorityHandler` with no socket.
