# `hydra/cli/` — the binary shell

The thin dispatch layer of the `hydra` binary: `main.zig` parses the verb
(`similar` / `dups` / `patterns`), initializes the stdout budget, and hands
off to the engine drivers in [`../engine/`](../engine/README.md); `schema.zig`
emits the machine-readable `--schema` capability manifest. No search logic
lives here — the shell stays swappable, the engine stays testable.
