# gist

The product chassis — ships the `gist` and `relate` binaries. Flag
grammar (rg-parity argv), the resident session daemon (sockets,
lifecycle, answer keep, watch), the CLI vocabulary, `--rank` fusion, the
session C ABI + Go/Python/Rust bindings, the Vim/Neovim plugin, generated
man pages + shell completions, and the ripgrep dominance certificate.

Extracted from `irregex` (cut from the extraction commit,
PLAN v5 split). Depends on [`irregex`](../irregex) (the library: engine,
corpus, cold pipeline, warm resident core) and [`relate`](../relate) (the
similarity engine) as sibling checkouts during development.

Status: extraction snapshot — build wiring (module-qualified imports,
build.zig) is in progress.

## Layout

- `src/exec/cold/{argv,view}/` — flag grammar · gist-native views
- `src/exec/session/{daemon,conduit,warden,watch,reconcile,facet}/` — the daemon proper
- `src/surface/cli/` — emit vocabulary, hints, hyperlinks
- `src/surface/face/{gist,relate}/` — both binary faces
- `src/surface/ffi/` + `include/` — the session C ABI
- `src/kernel/rank/` — weighted RRF rank fusion
- `bindings/` · `editor/` · `shell/` — bindings + editor/shell integration
- `bench/certificate/` — the vs-ripgrep certificate
