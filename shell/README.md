---
doc_radar:
  sentinels:
    - description: "the installer mints each artifact from the binary and links it where the shell already looks — never a checked-in copy to drift"
      file: pkg/kernels/irregex/shell/install.sh
      contains: ["--generate", "GIST_SHELL_INSTALL", "command -v", "ln -sfn"]
    - description: "every shell the primer renders for is placed by name"
      file: pkg/kernels/irregex/shell/install.sh
      contains: ["complete-zsh", "complete-bash", "complete-fish", "complete-powershell", "man/man1/gist.1"]
    - description: "install-gist runs this after linking the binaries"
      file: scripts/act/workspace/taskrunner/taskrun/rows/builds/_gist.py
      contains: "pkg/kernels/irregex/shell/install.sh"
---

# `shell/` — the manual and the completions

The shell end of [`gist`](../src/surface/face/gist/README.md), the way
[`editor/`](../editor/) is the Vim end. Nothing here is written by hand: every
artifact is minted by `gist --generate` from the same flag table
[`grammar.zig`](../src/surface/exec/cold/argv/grammar.zig) dispatches argv on,
so a flag cannot exist in the parser and be missing from a menu.

```bash
make install-gist          # builds, links the binaries, then runs this
GIST_SHELL_INSTALL=0 …     # decline just this part
gist --generate man        # or mint one artifact yourself
```

| Target                | Lands in                                  | Wiring needed |
| --------------------- | ----------------------------------------- | ------------- |
| `man`                 | `$XDG_DATA_HOME/man/man1/gist.1`          | none if that is on `manpath` |
| `complete-zsh`        | the first writable `*/site-functions` on `$fpath` | none |
| `complete-bash`       | `$XDG_DATA_HOME/bash-completion/completions/gist` | none (bash-completion 2.x) |
| `complete-fish`       | `$XDG_CONFIG_HOME/fish/completions/gist.fish` | none |
| `complete-powershell` | `$XDG_DATA_HOME/gist/gist.ps1`            | dot-source it from `$PROFILE` |

Artifacts are written once under `zig-out/share/` and **symlinked** into place,
so one rebuild refreshes every install site. An existing real file is never
replaced by a link, a shell that isn't installed is never touched, and
re-running changes nothing.

## Why it is worth generating rather than writing

ripgrep's zsh completion is the best hand-written one in the field, and it
carries a comment asking you to re-run a CI script "to ensure that the options
supported by this function stay in synch with the `rg` binary". A drift gate is
an admission that there is drift to gate. Minting from the parse table removes
the category, and spends the saved effort on three things:

- **Zero forks per keystroke.** `_rg_types` answers `-t<TAB>` by running
  `rg --type-list` and re-parsing it, every time. gist's menu is an array
  written into the file at generation: **~0.06 ms against ripgrep's ~7 ms**, and
  it arrives with each type's globs attached, which rg discards by default.
- **A grouped menu.** `gist -<TAB>` is captioned by what a flag *changes* —
  corpus, semantics, presentation, execution — rather than one alphabetical
  wall of ~280 flags.
- **Derived mutual exclusion.** `-i`/`-s`/`-S` rule each other out because they
  write the same field in the parser, not because someone remembered.

Measure it yourself with `make test-gist-shell`, which also parses each
generated script with the shell it targets.
