# `surface/face/gist/verbs/` — gist's five flat verbs

Lifecycle and introspection verbs for the gist face, consolidated flat after
the restructure (was `lifecycle/` + nested `status/` / schema dirs). One file
per verb — nothing to seal; zoning dropped the old directory seals.

| File | Verb | Job |
| ---- | ---- | --- |
| `index.zig` | `gist index` | Walk roots, build trigram `Index`, generation-publish blobs + freshness anchor |
| `codex.zig` | `gist codex` | Verb group over the shared shelf (`irregex/src/corpus/index/shelf/`) — build / count / tally / status |
| `status.zig` | `gist status` | Read-only report of index / atlas / shelf / daemon readiness |
| `schema.zig` | `gist --schema` | JSON capability manifest from the flag catalog |
| `config.zig` | `gist config` | Interrogate / check / init charter + preferences |

## `gist index`

Publishes into `.gist/` (or `$GIST_DIR`): the mmap index, path table, roots
list, and the T3 freshness anchor (`corpus/fresh/`). Pair-atomic
under `gens/<id>/` then `pair.gen`. Consumers: cold read-elision
(`exec/cold/engine/serial.zig`) and `--rank` (`exec/cold/view/ranked.zig`).

## `gist codex`

Owns the verb group, not the artifact. The shelf's path / persist / open /
staleness live in `irregex/src/corpus/index/shelf/`
so three faces share one writer.
