# beads_dart: agent instructions

This is the repository's one agent document; CLAUDE.md only imports it. Issues are beads with
the prefix `bdd`.

## Packages

Each package lives under `packages/<name>` and is versioned and tagged on its own. The table in
`README.md` says what each is and its version; the workspace (`pubspec.yaml`) holds three:
`packages/bdp` (the BDP client, its SQLite authority and `serve_bd`), `packages/gc_api` (a
read-only client for the Gas City supervisor's HTTP API) and `packages/gc_client` (the
`GcClient` seam over a Gas City city). README's `beads_dart` row is planned, not a package here.

## The gate

CI's `dart` job (`.github/workflows/ci.yaml`, Dart 3.12.2) runs, from the repository root:

```sh
dart pub get
dart analyze --fatal-infos
dart format --set-exit-if-changed .
dart run tool/test_entry.dart --check
for p in packages/*/; do
  [ -d "$p/test" ] || continue
  (cd "$p" && dart test)
done
```

Run it whole before handing a change over. The `ci-required` job passes only when `dart`
succeeds; it is the one check the ruleset and merge queue require.

## Depending on a package

Nothing is published to pub.dev. Consumers resolve a package by git with `tag_pattern` (Dart
3.9 or later): the repository URL, `path: packages/<name>`, `tag_pattern: <name>-v{{version}}`
and a version constraint (`README.md`). A package here that depends on a sibling declares it the
same way, never as a hosted or path dependency, so a consumer that takes it by git resolves the
sibling by git too; inside the workspace the member wins. `packages/gc_api/pubspec.yaml`'s `bdp`
dependency is the example. A change that needs a sibling's unreleased change waits for its tag.

## Releasing and changelogs

A release is the tag `<name>-v<version>` on the commit that bumps `version:` in
`packages/<name>/pubspec.yaml`. Never move a tag. Releasing is the owner's job: a change bumps
no version and pushes no tag. It adds its line to the package's `CHANGELOG.md` under an
`## Unreleased` heading at the top, adding the heading when absent; a package with no
`CHANGELOG.md` (gc_client today) gets one that starts with that heading.

## Compiling for the web

`package:bdp/client.dart` and everything `gc_api` reaches stay compilable for the web: neither
reaches `dart:io`, `dart:ffi`, `sqlite3` or `shelf`. `packages/bdp/test/structure_test.dart`
holds `client.dart` to `bdp.dart`'s exports minus the authority, forbids those imports in all it
reaches, and compiles a program importing it with `dart compile js`;
`packages/gc_api/test/web_test.dart` compiles `test/web_entry.dart` the same way. gc_api takes
bdp only through `package:bdp/client.dart` (`docs/decisions`).

## gc_api fixtures

They follow the gc 1.5.1 supervisor. `packages/gc_api/test/fixtures/openapi.json` is its own
OpenAPI description, vendored unmodified (build in the fixtures' README.md), and
`packages/gc_api/test/spec_test.dart` holds the client and every other fixture to it. Fixtures
use the made-up city `demo` (and `spare` beside it) under `/home/gc/cities/`, never a real
host's names or paths. When gc moves, refresh `openapi.json` from one supervisor and update
the version in the fixtures' README.md.

## The generated test entry

bdp's tests run from the generated `packages/bdp/test/all_test.dart` and the `paths:` block of
`packages/bdp/dart_test.yaml`. After adding, moving or deleting a test file in bdp, regenerate
both with `dart run tool/test_entry.dart` from the repository root; never edit them by hand.
`tool/test_entry.dart --check`, which the gate runs, fails when they are stale.

## Decisions

Rulings live in the register at `docs/decisions`, written with the `decisions` CLI
(`decisions guide decide`, then `decisions new`) and checked with `decisions lint docs/decisions`.
Read the entries whose surfaces cover what you change before changing it.
