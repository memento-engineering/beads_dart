# beads_dart

Dart packages for talking to beads stores and the controllers that drive them (Gas City, the
grid). Each package lives under `packages/` and is versioned and tagged on its own.

| Package | What it is | Status |
| --- | --- | --- |
| `gc_client` | The `GcClient` seam over a Gas City city: beads, convoys, mail, hook claims and sling, with a transport that runs `gc` and an in-process fake (`package:gc_client/testing.dart`). | 0.1.0, from houston |
| `bdp` | The Bead Protocol (BDP v0) client, its SQLite authority, and a BDP server over a bd store. | planned, from memento-engineering/grid |
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

## Releasing

A release of a package is its `version:` bump in `packages/<name>/pubspec.yaml`, merged to
`main`, then the tag `<name>-v<version>` on that commit, pushed. Never move a tag.

## Development

```sh
dart pub get
dart analyze --fatal-infos
dart format --set-exit-if-changed .
(cd packages/gc_client && dart test)
```
