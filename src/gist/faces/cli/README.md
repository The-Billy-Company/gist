---
doc_radar:
  counts:
    - description: "CLI face keeps its five verb/concern packages plus schema"
      glob: pkg/kernels/irregex/src/gist/faces/cli/*/
      equals: 5
      unit: dirs
  sentinels:
    - description: "entrypoint still dispatches through gist.commands.*"
      file: pkg/kernels/irregex/src/gist/faces/cli/main.zig
      contains:
        - "const indexer = gist.commands.indexer;"
        - "const search = gist.commands.search;"
        - "const client = gist.commands.client;"
---

# gist/faces/cli — the `gist` binary

This is the agent-facing product: a thin argv shell over the shared kernel.
`main.zig` only classifies the invocation and hands off; every verb's real work
lives in a sibling package below.

## What the binary does

Two lifecycle verbs (what gist *does*, not which competitor's argv it apes):

```text
gist index                        build + persist the trigram index
gist status [--json]              is an index ready, how fresh, how big
```

Everything else is search — no verb at all, the shape an agent's `rg <pattern>`
reflex already takes:

```text
gist <pattern> [PATH...] [flags]  find it now; live-scan, auto-use a covering index
gist rg|search …                  same engine, addressed with an explicit verb
gist serve                        keep a ResidentSession warm behind a Unix socket
```

Plus the conventional top-level flags: `--help`, `--version`, `--schema`.

`gist jesus` needs no prior `gist index`. It live-scans with ripgrep's default
behavior (gitignore, piped stdin, exit codes). When a fresh index covers the
searched subtree it is used *only* to skip reads of files the trigrams prove
can't match — never to change the file set or the bytes on stdout. `--no-index`
forces the pure walk; `--rank` is gist's one native shape ripgrep can't express.

## Layout

| Package | Owns |
| --- | --- |
| [`schema/`](schema) | `gist --schema` JSON capability manifest (driven from the flag catalog) |
| [`status/`](status) | read-only index introspection |
| [`lifecycle/`](lifecycle) | `gist index` — the one mutating build |
| [`search/`](search) | the unified rg-DEFAULT engine (argv → walk → read → emit) |
| [`daemon/`](daemon) | `gist serve` + warm dial / cold fallback / autoserve |

The sibling face is [`../ffi/`](../ffi) — same match decisions, different host
contract. Build with `zig build cli -- <args>` (see
[`../../../README.md`](../../../README.md)).
