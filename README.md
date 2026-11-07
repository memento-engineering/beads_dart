# beads_dart

Dart packages for talking to beads stores and the controllers that drive them (Gas City, the
grid). Each package lives under `packages/` and is versioned and tagged on its own.

| Package | What it is | Status |
| --- | --- | --- |
| `gc_client` | The `GcClient` seam over a Gas City city: beads, convoys, mail, hook claims and sling, with a transport that runs `gc` and an in-process fake (`package:gc_client/testing.dart`). | 0.1.0, from houston |
| `gc_api` | A client for the Gas City supervisor's HTTP API: health, cities, a city's status, its sessions and pending interactions, and its event log, paged and live. Every platform, the web included. | 0.1.0-dev.1 |
| `bdp` | The Bead Protocol (BDP v0) client (`package:bdp/client.dart`, every platform), its SQLite authority, and `serve_bd`, a BDP server over a bd store. | 0.1.0-dev.3, from memento-engineering/grid |
| `beads_dart` | The predecessor bd client. | planned, from memento-engineering/the_grid |

## Depending on a package

Nothing here is published to pub.dev. Depend on a package by git, and let pub pick the newest
tag that satisfies the version constraint:

```yaml
dependencies:
  gc_client:
    git:
      url: https://github.com/memento-engineering/beads_dart.git
      path: packages/gc_client
      tag_pattern: gc_client-v{{version}}
    version: ^0.1.0
```

`tag_pattern` needs Dart 3.9 or later.

A package here that depends on another package here declares it the same way, by git and
`tag_pattern`, never as a hosted dependency: inside this workspace the member wins, and a
consumer that takes the package by git resolves its sibling by git too. So a package that needs
a sibling's unreleased change waits for that sibling's tag.

## Releasing

A release of a package is its `version:` bump in `packages/<name>/pubspec.yaml`, merged to
`main`, then the tag `<name>-v<version>` on that commit, pushed. Never move a tag.

## Development

```sh
dart pub get
dart analyze --fatal-infos
dart format --set-exit-if-changed .
for p in packages/*/; do (cd "$p" && dart test); done
```

`tool/test_entry.dart` writes a package's generated `test/all_test.dart` and the `paths:` block of
its `dart_test.yaml`; run it after adding, moving or deleting a test file in a package that has
one (`dart run tool/test_entry.dart`, `--check` to verify).

The workspace analyzes with the `genesis_lint` plugin (`analysis_options.yaml`).
