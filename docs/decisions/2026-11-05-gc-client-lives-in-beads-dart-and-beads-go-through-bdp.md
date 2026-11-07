---
status: accepted
date: 2026-11-05
decision-makers:
  - "Nico Spencer"
consulted: []
informed: []
register:
  spec: 1
  slug: "gc-client-lives-in-beads-dart-and-beads-go-through-bdp"
  surfaces:
    - "packages/**"
  obsoletes: []
  updates: []
  obsoleted-by: null
  updated-by: []
  bead: "bdd-kxn"
  legacy-id: null
---

# gc_client lives in beads_dart, and beads go through BDP

## Context and Problem Statement

This register starts with this repository. Before it existed, houston recorded on 2026-11-05
where the shared Dart packages for beads stores and their controllers live and how consumers
take them, in houston docs/decisions/2026-11-05-gc-client-lives-in-beads-dart-and-beads-go-through-bdp.md,
accepted with Nico Spencer among its deciders. houston is private, so a build in this
repository cannot read that entry. This entry ports its ruling unchanged so that it binds here.

## Decision Outcome

**The shared packages live here, each released by its own tag and taken by git, and beads go
through BDP. houston's ruling binds this repository unchanged:**

> Shared packages live in memento-engineering/beads_dart. That public repository holds the Dart packages for beads stores and the controllers that drive them: gc_client from houston, bdp from memento-engineering/grid, and beads_dart from memento-engineering/the_grid. Each sits under packages/<name>, is versioned on its own, and is released by tagging <name>-v<version>. Consumers resolve them by git tag_pattern, never through pub.dev: a dependency names the repository URL, path: packages/<name>, tag_pattern: <name>-v{{version}} and a version constraint. Beads go through BDP; Gas City-only state goes through the Gas City API.

This entry ports houston docs/decisions/2026-11-05-gc-client-lives-in-beads-dart-and-beads-go-through-bdp.md
and amends nothing in this register. It is falsified when a package here is published to
pub.dev or consumed other than by its git tag, or when a client reads beads other than through BDP.

### Consequences

* Good, because a build in this repository sees the ruling that governs its packages without
  reading houston.
* Bad, because the ruling now has two copies; a later change to it is recorded in both registers.
