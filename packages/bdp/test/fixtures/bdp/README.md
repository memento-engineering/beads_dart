# BDP v0 fixtures

Copied unmodified from [gastownhall/bdp](https://github.com/gastownhall/bdp) at
commit `182f1fcf8a01d896976bff3c9e3fb87c596c6ca6` (MIT, see `LICENSE`):

| Here | Upstream |
| --- | --- |
| `schemas/bdp-v0.schema.json` | `schemas/bdp-v0.schema.json` |
| `transactional/*.json` | `fixtures/transactional/` (the files the client touches) |
| `read-update/discovery.json`, `read-update/singletons.json` | `fixtures/read-update/` |
| `reference-domain/reference-domain.json` | `fixtures/reference-domain/` |

They are test data for `package:bdp`'s codecs and client. When the draft moves,
refresh them from one upstream commit together and update the commit above.

The authority tests load the same files: the schema bundle validates the wire shapes the
authority serves, and the Transactional exchanges are the oracle its tests compare against.
