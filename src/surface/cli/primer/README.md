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
    - description: "the zsh menu is captioned per group and derives its exclusions, rather than dumping one flat table"
      file: pkg/kernels/irregex/src/surface/cli/primer/zsh.zig
      contains: ["tag-order", "ignored-patterns", "group-name"]
---

# `src/surface/cli/primer/` — man page + shell completions

`--generate` artifacts for every product face, minted from the same `Surface`
table the parser dispatches on. One description; five renderings. Nothing a
completion offers is fetched at tab time — closed candidate sets are baked at
generation, so a tab costs zero processes and cannot drift from the binary
without regenerating.

| File         | Role                                                                 |
| ------------ | -------------------------------------------------------------------- |
| `primer.zig` | `Surface` / `Option` / `Target` vocabulary and `--generate` dispatch |
| `page.zig`   | Man page (roff), grouped by what a flag changes                      |
| `shell.zig`  | bash · fish · PowerShell completions                                 |
| `zsh.zig`    | zsh completion — captioned groups, not one flat table                |

## What a `Surface` is, and what is derived from it

An `Option` says how a flag is spelled, what it takes, which group it belongs
to, and which flags it rules out. Everything a renderer needs beyond that is
computed here rather than restated per shell:

- **Grouping** comes from the `Reach` the parser already records to decide what
  a persisted setting may change — corpus, semantics, presentation, execution —
  so a flag lands in the right man-page section and the right completion caption
  by having been classified at all.
- **Exclusions** come from the action union: two flags that assign the same
  field are rivals, which is how `-i`/`-s`/`-S` and
  `--context-separator`/`--no-context-separator` rule each other out without a
  hand-kept list.
- **Shared candidate sets** are hoisted once per file, so the 239 file types and
  233 encodings are written once and referenced by every flag that takes one.

Three exhaustive `switch`es over the action union decide what a flag takes, what
it displaces, and where it belongs, so adding an action is a compile error until
all three are answered.

## Two traps worth knowing

**A zsh caption may not contain a colon.** `_next_label` splits
`label:description` at the _last_ colon, so a colon in a group title silently
moves the tag — and every `ignored-patterns` lookup for that group misses,
leaving a beautifully captioned copy of the entire option table under each
heading. Titles use an em dash, `wordy` strips colons defensively, and both a
Zig test and `shell/check.sh` fail if one reappears.

**The man page is measured in output columns, not source bytes.** Non-ASCII is
emitted as `\[uXXXX]` roff escapes — portable to any roff, and the only way the
78-column fold can count what the reader will see. A folded line beginning `.`
or `'` is prefixed `\&` so roff does not read prose as a request.

## When to edit

A new flag group, value kind, or completion target. The face that _owns_ the
flag still declares it in that face's repertoire / catalog; this package only
renders a `Surface` it is handed. The consumer-side proof —
each shell parsing its own artifact — lives in
[`shell/check.sh`](../../../../shell/README.md), run by `make test-gist-shell`.
