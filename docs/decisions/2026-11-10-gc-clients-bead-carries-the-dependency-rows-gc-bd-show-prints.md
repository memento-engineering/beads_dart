---
status: accepted
date: 2026-11-10
decision-makers:
  - "Nico Spencer"
consulted:
  - "Claude (governor)"
informed: []
register:
  spec: 1
  slug: "gc-clients-bead-carries-the-dependency-rows-gc-bd-show-prints"
  surfaces:
    - "packages/gc_client/**"
  obsoletes: []
  updates:
    - "gc-client-lives-in-beads-dart-and-beads-go-through-bdp"
  obsoleted-by: null
  updated-by: []
  bead: "bdd-9nd"
  legacy-id: null
---

# gc_client's Bead carries the dependency rows gc bd show prints, until houston reads beads through BDP

## Context and Problem Statement

houston's intake op will refuse to drive a bead that has an open blocker. houston reads beads
only through gc_client, which shells out to `gc bd`, and gc_client's `Bead` drops the
`dependencies` rows that `gc bd show --json` prints. A bead's dependency rows are bd state, and
beads_dart#gc-client-lives-in-beads-dart-and-beads-go-through-bdp rules that beads go through
BDP; bdp already serves those rows as dependency Links. Moving houston's bead reads onto BDP
first would hold intake behind a larger migration.

## Decision Outcome

**gc_client's `Bead` may carry the dependency rows `gc bd show` and `gc bd list` print, as a
transitional path, until houston reads beads through BDP.** gc_client gains no other bd state
under this entry: a further bd field on `Bead` needs its own amendment.

This amends the clause "Beads go through BDP" of
beads_dart#gc-client-lives-in-beads-dart-and-beads-go-through-bdp for gc_client's `Bead`
dependency rows only, and leaves the rest of that ruling standing. It is retired when houston
reads beads through BDP, at which point the rows are removed from gc_client's `Bead`. It is
falsified when gc_client carries bd state beyond the dependency rows without an amendment.

### Consequences

* Good, because houston's intake can see a bead's blockers through the client it already uses.
* Bad, because blocker state has two paths, gc_client's rows and bdp's Links, until houston
  moves to BDP.
* Bad, because houston keeps its own copy of the amended ruling, so this amendment is recorded
  there too.
