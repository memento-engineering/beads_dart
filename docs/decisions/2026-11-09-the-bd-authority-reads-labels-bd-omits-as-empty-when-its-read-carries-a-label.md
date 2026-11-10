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
  slug: "the-bd-authority-reads-labels-bd-omits-as-empty-when-its-read-carries-a-label"
  surfaces:
    - "packages/bdp/lib/src/authority/bd/**"
  obsoletes: []
  updates:
    - "grid#the-work-scope-authority-projects-bd-until-bd-speaks-bdp"
  obsoleted-by: null
  updated-by:
    - "the-bd-authority-writes-a-provides-label-through-bd-ship"
  bead: "bdd-7nl"
  legacy-id: null
---

# The bd authority reads labels bd omits as empty whenever its read carries a label

Drafted by the builder seat for bdd-7nl; it is owed the owner's ratification.

## Context and Problem Statement

bd's `bd list --json` leaves a bead's labels out of its row when the bead has none: in the decisions store, 76 of 90 rows carry no labels key. The bd authority never carried labels at all, so every bead it read had labels unknown. grid#an-external-dependency-resolves-by-a-closed-bead-providing-its-capability resolves a cross-store dependency by a closed bead whose labels say it provides the capability, and it fails closed when labels are unknown, per grid#a-work-scope-read-that-cannot-carry-a-fact-fails-closed. So on the live station no cross-store dependency resolved: grid-jied was refused because dec-0mu's labels could not be read, although bd lists dec-0mu closed with the label grid.approved.

grid#the-work-scope-authority-projects-bd-until-bd-speaks-bdp D2 carries a field bd omits when empty only when some row of the same read holds a value for it, and leaves it unknown on every bead otherwise. Labels need that evidence, and once a read evidences them, a bead whose row lists none has no labels rather than unknown ones.

## Decision Outcome

The bd authority carries labels by their own evidence in each read. When some row of a read holds a label, every bead of that read carries labels: a bead whose row lists labels carries them as bd lists them, and a bead whose row lists none carries none, as an empty list. When no row of a read holds a label, labels are unknown on every bead of that read, never empty. The evidence is taken on each read by itself, never carried over from an earlier one. A row whose labels are not a list of non-empty text refuses the whole read, as a malformed dependency does.

This amends grid#the-work-scope-authority-projects-bd-until-bd-speaks-bdp D2 for labels only, beside beads_dart#the-bd-authority-reads-a-text-field-bd-omits-as-empty-when-its-read-carries-text, which it leaves standing. The text fields, the other fields bd omits when empty and dependencies keep their rules. The fail-closed principle of grid#a-work-scope-read-that-cannot-carry-a-fact-fails-closed stands: labels read as none only when the read carries labels. Writing labels stays refused.

### Consequences

* Good, because a closed bead's capability label is read, so a cross-store dependency on it resolves.
* Bad, because a store in which no bead holds any label reads labels unknown, so a dependency on that store still fails closed until one of its beads is labelled.
* Bad, because a bd version whose list path dropped labels on some rows while keeping them on others would read the dropped ones as none. bdp's real-bd tests run only against the bd version they stamp (grid#a-test-runs-real-bd-only-against-a-store-its-version-stamped), and those tests are where such a version is caught.

### Confirmation

The labels tests of the 'a read is projected' group in `packages/bdp/test/authority/bd_authority_test.dart` show a read where some row holds labels carrying them on every bead, a read where no row holds one carrying them on none, a malformed labels value refusing the read, and the evidence taken afresh on each read.
