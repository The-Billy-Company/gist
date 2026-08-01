<!--
doc_radar:
  counts:
    - glob: src/surface/cli/**/*.zig
      min: 4
      unit: modules
      description: the primer leaf — a new generator module needs a row below
-->

# `src/surface/cli/` — gist's generate vocabulary

What remains of the shared face vocabulary after the relate face moved into
the `relate` package: only the `--generate` primer that renders this
product's man page and shell completions. Flag parsing, verb-table
rendering, kinship grades, and the answer-keep passenger live with the face
that needs them (`relate/src/surface/cli/`).

| Path                  | Owns                                                                                                                                                                                                 |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`primer/`](primer)   | `--generate` artifacts — `primer.zig` owns the `Surface` vocabulary and dispatch; `page.zig` renders the man page; `shell.zig` emits bash/fish/PowerShell; `zsh.zig` emits the zsh completion. Nothing computed at tab time that could be baked at generation time; no drift between the parser and the completion because they share one description |

## Why it still sits under `cli/`

The primer is the face vocabulary for *this* product's man page and
completions. Relocating it under `face/gist/` would couple generation to one
verb driver; keeping it here matches the pre-split layout and the
`@import("gist").cli.primer` re-export the face already uses.

## When to edit

How the man page or a shell completion is rendered from the flag table. The
flag table itself (what argv the `gist` binary accepts) lives with the face
under [`../face/gist/`](../face/gist/).
