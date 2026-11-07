---
status: accepted
date: 2026-11-05
decision-makers:
  - "Nico Spencer"
consulted: []
informed: []
register:
  spec: 1
  slug: "the-gc-api-client-keeps-its-own-problem-type-and-imports-bdps-client-library"
  surfaces:
    - "packages/gc_api/**"
  obsoletes: []
  updates: []
  obsoleted-by: null
  updated-by: []
  bead: "bdd-kxn"
  legacy-id: null
---

# The Gas City API client keeps its own problem type and imports bdp client library only

## Context and Problem Statement

houston recorded on 2026-11-05 how the Gas City API client, gc_api here, reads a Gas City
failure and how it reuses bdp, in houston docs/decisions/2026-11-05-the-gc-api-client-keeps-its-own-problem-type-and-imports-bdps-client-library.md,
accepted with Nico Spencer among its deciders. houston is private, so a build in this
repository cannot read that entry. This entry ports its ruling unchanged so that it binds here.

## Decision Outcome

**The Gas City API client reads a Gas City failure through a problem type of its own, in which
nothing is required, and reuses bdp only through bdp's web-safe client library. houston's ruling
binds this repository unchanged:**

> The Gas City API client keeps its own RFC 9457 type, GcProblem, in which every member is optional, and never reads a Gas City failure through bdp's ProblemDetails (which requires BDP's code and retry members, while the supervisor's ErrorModel makes every member optional and a refusal before routing, such as a mutation without X-GC-Request, carries only title, status and detail). It reuses bdp only through package:bdp/client.dart, bdp's client without the authority, which reaches neither dart:io nor SQLite; that is where it takes decodeSse from. A client meant for every platform imports bdp the same way.

This entry ports houston docs/decisions/2026-11-05-the-gc-api-client-keeps-its-own-problem-type-and-imports-bdps-client-library.md
and amends nothing in this register. It is falsified when the supervisor's error model comes
to require the members bdp's problem type requires, or when bdp's client library can no
longer be compiled for the web.

### Consequences

* Good, because a refusal the supervisor answers before routing is still read as a problem.
* Bad, because two problem types describe RFC 9457 in this repository, one per protocol.
