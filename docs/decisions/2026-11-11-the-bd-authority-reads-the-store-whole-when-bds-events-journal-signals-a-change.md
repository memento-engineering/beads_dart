---
status: proposed
date: 2026-11-11
decision-makers:
  - "Nico Spencer"
consulted:
  - "Claude (builder seat)"
informed: []
register:
  spec: 1
  slug: "the-bd-authority-reads-the-store-whole-when-bds-events-journal-signals-a-change"
  surfaces:
    - "packages/bdp/lib/src/authority/bd/**"
  obsoletes: []
  updates: []
  obsoleted-by: null
  updated-by: []
  bead: "bdd-cqj"
  legacy-id: null
---

# The bd authority reads the store whole when bd's events journal signals a change

Drafted by the builder seat for bdd-cqj; it is owed the owner's ratification.

## Context and Problem Statement

The bd authority learned of changes only by polling: every interval it read the store whole and diffed the read into the changefeed, whether or not anything had changed. bd keeps a durable events journal, enabled per store, that records every mutation through bd's normal write paths in the same transaction as the change, as gapless records whose positions rise and are never reused within one replica. It does not record raw SQL writes or rows a pull merges, each replica counts its own positions, and old records are pruned.

The authority should read the store only when the journal says it changed, without trusting the journal past what it can show, and without changing how a read is projected, which beads_dart#the-bd-authority-reads-a-text-field-bd-omits-as-empty-when-its-read-carries-text and beads_dart#the-bd-authority-reads-labels-bd-omits-as-empty-when-its-read-carries-a-label rule.

## Decision Outcome

When a store's events journal is on, the bd authority takes a whole read only when the journal shows a mutation past the last one it saw, when the journal cannot be trusted, or when no whole read has begun for the authority's safety interval. When the journal is off, or its setting cannot be read, the authority reads whole on every poll as before. The safety interval, the authority's `safetyInterval`, is a fixed multiple of the polling interval, kept in the package's code and documentation.

The journal is a change signal only. Every projection still comes from a whole read, and a write is still confirmed by its own whole reads.

The journal is trusted on a poll only when the record at the last position seen reads back unchanged and positions rise. Otherwise the authority takes a fresh baseline and reads whole.

A baseline is taken before the whole read it guards, so a mutation between them is read twice rather than missed.

This amends no entry, and it leaves standing the projection rules of beads_dart#the-bd-authority-reads-a-text-field-bd-omits-as-empty-when-its-read-carries-text and beads_dart#the-bd-authority-reads-labels-bd-omits-as-empty-when-its-read-carries-a-label. It is falsified when a mutation through bd's normal write paths reaches a whole read but never the journal, or when bd reuses a position on one replica.

### Consequences

* Good, because a quiet store costs one journal read per poll instead of a whole read.
* Good, because a write that landed outside the journal, by raw SQL or a pull, is still seen within the safety interval.
* Bad, because the poll after each of the authority's own writes takes one more whole read, since its confirming reads do not advance the position seen.
* Bad, because a store whose journal was empty at the baseline has no record to anchor on, so a switch of replica there is seen only by the safety read.

### Confirmation

The journal group of `packages/bdp/test/authority/bd_authority_test.dart` holds each ruling over the fake bd, and `packages/bdp/test/authority/bd_journal_test.dart` holds journal mode, a quiet run without a whole read and a human's create reaching the changefeed against a stamped bd.
