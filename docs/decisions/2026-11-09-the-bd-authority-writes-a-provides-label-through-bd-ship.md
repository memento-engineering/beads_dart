---
status: proposed
date: 2026-11-09
decision-makers:
  - "Nico Spencer"
consulted:
  - "Claude (builder seat)"
informed: []
register:
  spec: 1
  slug: "the-bd-authority-writes-a-provides-label-through-bd-ship"
  surfaces:
    - "packages/bdp/lib/src/authority/bd/**"
  obsoletes: []
  updates:
    - "the-bd-authority-reads-labels-bd-omits-as-empty-when-its-read-carries-a-label"
  obsoleted-by: null
  updated-by: []
  bead: "bdd-h12"
  legacy-id: null
---

# The bd authority writes a provides label through bd ship, since bd reserves the prefix

Drafted by the builder seat for bdd-h12; it is owed the owner's ratification.

## Context and Problem Statement

When a bead in one roster store lands, the grid appends a provides label to it, so that a dependency on that capability from another store resolves. The bd authority refused every label write, as beads_dart#the-bd-authority-reads-labels-bd-omits-as-empty-when-its-read-carries-a-label ruled. On 2026-11-10 on lunar that refusal held up grid-jied: provides:dec-5cq could not be added to dec-5cq, and the dependency stayed owed until the governor ran bd by hand.

bd itself reserves the provides prefix. Its plain label verb refuses a provides label and points at its ship verb, which finds the bead labelled with the matching export label and adds the provides label to it, and does so only when that bead is closed unless forced. The governor's manual cure was exactly that: the export label, then the ship.

## Decision Outcome

The bd authority writes labels only by appending. It refuses, before any call to bd, a change that would drop or replace a label the bead holds, and a change of the whole list where its read does not carry labels, since it cannot know such a change drops nothing.

A provides label is written the way bd allows: by the matching export label, unless the bead already holds it, and then bd's ship verb. The authority never adds a provides label through the plain label verb and never forces a ship.

bd's refusal of a ship is the write's refusal, carried unchanged; the export label added before it stays on the bead, so a later retry ships directly.

A ship is refused before any call when another bead the authority serves holds the same export label, since bd would ship that bead instead.

A label write is confirmed only by a read holding every label it appended, both the export and the provides label for a provides label; labels a read does not carry never confirm one.

This amends the clause "Writing labels stays refused." of beads_dart#the-bd-authority-reads-labels-bd-omits-as-empty-when-its-read-carries-a-label and leaves its read rules standing. It is falsified when bd accepts a provides label through its plain label verb, or ships a named bead rather than the holder of the export label.

### Consequences

* Good, because a landed bead's capability is shipped without the governor running bd by hand.
* Bad, because an open bead keeps the export label from a ship bd refused.
* Bad, because a store whose read carries no labels pays an export label add the bead may already hold.
* Bad, because bd 1.3.2 runs no ship in proxied-server mode, so on a store in that mode a provides append lands its export label and fails with bd's refusal.

### Confirmation

The labels tests of the 'the bd authority writes' group in `packages/bdp/test/authority/bd_authority_test.dart` hold an ordinary append, a provides append with and without the export label held, a close and a ship in one change, the refusals before any call, the open-bead refusal and the unconfirmed append. The real-bd label tests of `packages/bdp/test/authority/bd_writes_test.dart` hold the label adds and the carried ship refusal against a stamped bd.
