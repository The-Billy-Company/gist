# tools

Maintenance scripts for this repo. Standard library only, no build step — run
them with `python3 tools/<name>.py`.

| Script | What it does |
|---|---|
| `sync_contract.py` | Verifies the foreign contracts are reachable as sibling checkouts (`../irregex`, `../relate`). |

## Four contracts, one of them ours

There are four contracts, split by who authors the thing being described:

| File | Authored in | Declares |
|---|---|---|
| `contract/surface.toml` | **here** | transports, the resident session, the tool boundary, the published package names |
| `irregex/contract/analytic.toml` | `irregex` | the row schemas, enums, verb table and producer map every analytic answer rides |
| `irregex/contract/engine.toml` | `irregex` | the request surface, match kinds, exit codes, the ABI status vocabulary, and the version axes |
| `relate/contract/kinship.toml` | `relate` | the compression plane — channels, grade bands, verbs, lifecycle |

The analytic tables are substrate: gist, relate and blast all return those rows,
so they are declared once beside the generator that lowers them
(`irregex/tools/build_schema_tables.py`) rather than in whichever product
declared them first.

Bindings resolve the two foreign contracts from the authoring sibling (or an
`IRGX_*_CONTRACT` override). Parity tests fail closed when a contract is
unreadable, so a checkout without siblings cannot silently skip the gate.
`sync_contract.py` is the explicit sibling check.
