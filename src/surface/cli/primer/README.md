---
doc_radar:
  counts:
    - description: "primer is four Zig modules — Surface + three renderers"
      glob: pkg/kernels/irregex/src/surface/cli/primer/*.zig
      equals: 4
      unit: modules
  sentinels:
    - description: "one Surface drives every --generate target"
      file: pkg/kernels/irregex/src/surface/cli/primer/primer.zig
      contains: ["pub const Surface", "pub fn render", "pub fn emit", "complete-zsh"]
---

# `src/surface/cli/primer/` — man page + shell completions

`--generate` artifacts for every product face, minted from the same `Surface`
table the parser dispatches on. One description; four renderings. Nothing a
completion offers is fetched at tab time — closed candidate sets are baked at
generation, so a tab costs zero processes and cannot drift from the binary
without regenerating.

| File         | Role                                                                 |
| ------------ | -------------------------------------------------------------------- |
| `primer.zig` | `Surface` / `Option` / `Target` vocabulary and `--generate` dispatch |
| `page.zig`   | Man page (roff), grouped by what a flag changes                      |
| `shell.zig`  | bash · fish · PowerShell completions                                 |
| `zsh.zig`    | zsh completion — tag-split, not a flat ~90-flag dump                 |

## When to edit

A new flag group, value kind, or completion target. The face that *owns* the
flag still declares it in that face's repertoire / catalog; this package only
renders a `Surface` it is handed.
