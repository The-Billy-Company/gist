# `shell/` — the manual and the completions

The shell end of [`gist`](../src/surface/face/gist/README.md), the way
[`editor/`](../editor/) is the Vim end. Nothing here is written by hand: every
artifact is minted by `gist --generate` from the same flag table
`irregex/src/exec/cold/argv/catalog.zig` declares and
`irregex/src/exec/cold/argv/grammar.zig` dispatches argv on,
rendered by [`cli/primer/`](../src/surface/cli/primer/README.md). A flag cannot
exist in the parser and be missing from a menu.

```bash
zig build          # builds, links the binaries, then runs this
GIST_SHELL_INSTALL=0 …     # decline just this part
gist --generate man        # or mint one artifact yourself
```

| Target                | Lands in                                          | Wiring needed                 |
| --------------------- | ------------------------------------------------- | ----------------------------- |
| `man`                 | `$XDG_DATA_HOME/man/man1/gist.1`                  | none if that is on `manpath`  |
| `complete-zsh`        | the first writable `*/site-functions` on `$fpath` | none                          |
| `complete-bash`       | `$XDG_DATA_HOME/bash-completion/completions/gist` | none (bash-completion 2.x)    |
| `complete-fish`       | `$XDG_CONFIG_HOME/fish/completions/gist.fish`     | none                          |
| `complete-powershell` | `$XDG_DATA_HOME/gist/gist.ps1`                    | dot-source it from `$PROFILE` |

Artifacts are written once under `zig-out/share/` and **symlinked** into place,
so one rebuild refreshes every install site. An existing real file is never
replaced by a link, a shell that isn't installed is never touched, and
re-running changes nothing.

On Windows the same job is [`install.ps1`](../install.ps1) rather than
[`install.sh`](install.sh), and only the `powershell` row applies: the completion
lands at `%LOCALAPPDATA%\gist\gist.ps1` and gets one guarded dot-source line in
`$PROFILE`, because a profile is the only place PowerShell autoloads from — it has
no `site-functions`, `bash-completion`, or `completions.d` equivalent to drop a
file into and say nothing. The man page is still minted and placed for whoever has
a `man` that reads it (Git for Windows, MSYS2, a WSL install sharing the home
directory); nothing on a stock Windows will, and it costs one file to be right
for the people who do. A symlink needs a privilege there, so each placement tries
a link and falls back to a copy — which is why `install.ps1` reports which one it
used: a copy goes stale on the next rebuild and a link does not.

## Why it is worth generating rather than writing

ripgrep's zsh completion is the best hand-written one in the field, and it
carries a comment asking you to re-run a CI script "to ensure that the options
supported by this function stay in synch with the `rg` binary". A drift gate is
an admission that there is drift to gate. Minting from the parse table removes
the category, and spends the saved effort on three things:

- **Zero forks per keystroke.** `_rg_types` answers `-t<TAB>` by running
  `rg --type-list` and re-parsing it, every time. gist's menu is an array
  written into the file at generation: **~0.065 ms against ripgrep's ~5 ms,
  about 77×** (both sinks stubbed alike, so only the gather is timed; a busier
  machine puts rg nearer 9 ms and moves gist's side hardly at all). Its 241
  candidates each arrive with that type's globs attached, where rg discards
  them and offers 224 bare names.
- **A grouped menu.** `gist -<TAB>` offers its 282 candidates under five
  captions naming what a flag _changes_ — corpus, semantics, presentation,
  execution, configuration — rather than one alphabetical wall. The man page is
  sectioned the same way, off the same `Reach` the parser already records.
- **Derived mutual exclusion.** `-i`/`-s`/`-S` rule each other out because they
  write the same field in the parser, not because someone remembered.

the shell-completion suite under `shell/` is the standing proof: each shell parses its own
artifact, mandoc lints the page, every flag is shown to be filed in exactly one
caption, and the suite fails if any generated file would run a program at tab
time.
