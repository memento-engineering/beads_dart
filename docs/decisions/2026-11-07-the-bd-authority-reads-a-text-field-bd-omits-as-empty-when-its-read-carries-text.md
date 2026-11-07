---
status: accepted
date: 2026-11-07
decision-makers:
  - "Nico Spencer"
consulted:
  - "Claude (houston operator session)"
informed: []
register:
  spec: 1
  slug: "the-bd-authority-reads-a-text-field-bd-omits-as-empty-when-its-read-carries-text"
  surfaces:
    - "packages/bdp/lib/src/authority/bd/**"
  obsoletes: []
  updates:
    - "grid#the-work-scope-authority-projects-bd-until-bd-speaks-bdp"
  obsoleted-by: null
  updated-by: []
  bead: "bdd-c0a"
  legacy-id: null
---

# The bd authority reads a text field bd omits as empty whenever its read carries any text field

## Context and Problem Statement

bd 1.3.2's `bd list --json` leaves a field out of a row when the field is empty. A row with no `design` key could therefore be a bead whose design is empty, or a read path that doesn't carry design. grid#the-work-scope-authority-projects-bd-until-bd-speaks-bdp D2 decides between the two field by field: a field bd omits when empty is carried only when some row of the same read holds a value for it. Otherwise the field is unknown on every bead of the read, per grid#a-work-scope-read-that-cannot-carry-a-fact-fails-closed D2.

That rule failed in practice once grid#a-readiness-verdict-is-keyed-on-the-beads-text-and-the-breaker-counts-by-circuit D2 made a bead's description, design and acceptance criteria an input to admission. In a store where no bead has a design yet, design reads unknown on every bead, so no bead has a text basis and the station grades none of them. The first case was the new bdd store on 2026-11-07: bdd-kxn and bdd-s0s were refused with "its text basis cannot be read" until each was given a design. The fail-closed entry had said prose fields were not covered because no eligibility clause depended on them. That stopped being true at the readiness entry, and the rule beneath it was never re-examined.

bd omits empty fields to keep its output small. The output is read by agents, and every empty key costs tokens. The omission is bd's convention for "empty", not a sign that the read can't carry the field.

## Decision Outcome

The bd authority (`packages/bdp/lib/src/authority/bd/`) reads bd's convention as bd means it, for the text fields as one group. When any row of a read holds a value for any of title, description, design, acceptance_criteria or notes, every one of those fields is carried on every bead of that read, and a row that leaves one out holds it as empty text. bd requires a title on every bead, so every read with a bead in it carries the text fields. A read where no row holds any text field carries none of them, as before.

The other fields bd omits when empty keep the rule that some row of the same read must hold a value: external_ref, await_id, close_reason and metadata. Metadata carries the approval stamp and the validation plan. A store that has never held them must still read them as unknown rather than absent. Dependencies keep their own rule.

This amends grid#the-work-scope-authority-projects-bd-until-bd-speaks-bdp D2 for the text fields only. The fail-closed principle of grid#a-work-scope-read-that-cannot-carry-a-fact-fails-closed D2 stands: a text field is read as empty only when the read carries the text fields.

### Consequences

* Good, because a bead in a new store, or in a store whose beads never use design or notes, has a text basis and is graded.
* Good, because the authority now reads bd's output the way bd writes it, instead of asking a store to prove each field with a value.
* Bad, because if a bd version's list path carries title but silently drops another text field, that field reads as empty, not unknown. A bead could then be graded on text missing its design. bdp's real-bd tests run only against the bd version they stamp (grid#a-test-runs-real-bd-only-against-a-store-its-version-stamped), and those tests are where such a version is caught.

### Confirmation

`packages/bdp/test/authority/bd_authority_test.dart` shows a read whose rows hold titles but no design or notes carrying design and notes as empty text on every bead. It also shows a read whose rows hold no text field carrying none of the text fields, and a read whose rows hold no metadata still leaving metadata out.
