The competitive race now scopes gist and rg to the same logical corpus the
indexed rivals see. Both run under `--no-ignore-vcs` for a deterministic
multi-root oracle set, but that also discarded every nested `.gitignore` — so
they alone walked ~2,488 build artifacts the root `.gitignore` never names
(Elixir `_build`/`deps`/`cover` beam output, Electron `out/`). Those files are
pruned by `gist index`, so they never enter `paths.list` and never reach
csearch: the "indexed twin" was racing a strict subset of gist's corpus, and
every one of those files fell off both the elide oracle and the content shard
into a live `openat`+`read`. Re-applying them as the glob equivalent of the
`XDIRS` set the other no-gitignore tools already get cuts gist's `literal-rare`
cell 1.21x and its system time by a third, with the rg-equality oracle still
byte-identical across the literal, regex, PCRE, and count fields.
