# `gist` - the binary face

The dispatch shell for the `gist` command. The product documentation -
quickstart, the search contract, the three execution paths, ranked
search, evidence, and prior art - is the [repository
README](../../../../README.md); this note covers only what is in this
directory.

- [`main.zig`](main.zig) dispatches the bare search and the lifecycle
  verbs. The authoritative search implementation is not here: it lives
  in the `irregex` library's `src/exec/cold/`.
- [`verbs/index.zig`](verbs/index.zig) and [`verbs/codex.zig`](verbs/codex.zig)
  own trigram-index and codex lifecycle.
- [`verbs/status.zig`](verbs/status.zig) owns read-only index
  introspection.
- [`verbs/schema.zig`](verbs/schema.zig) renders the capability manifest
  from the flag catalog.
- [`verbs/config.zig`](verbs/config.zig) reports, validates, and derives
  the two persisted configuration layers.

Serving, client routing, auto-spawn, and cold fallback are one level out,
in [`../../../exec/session/daemon/`](../../../exec/session/daemon/). Run
the freshly built CLI with `zig build cli -- <args>`.
