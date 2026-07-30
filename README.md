# gist

The product chassis - this repo ships the binaries. `gist` is the
indexed, rg-parity code search (same flags, same `.gitignore`/hidden
precedence, same exit codes, byte-identical piped output); `relate` is
the similarity CLI over the [`relate`](../relate) engine. Both ride the
[`irregex`](../irregex) library - the engines, the index, the corpus
walk, the flag grammar, and the warm resident core all live there. This
package owns everything with an opinion about the product:

- `src/exec/session/conduit/` - the daemon wire: protocol, spawn, vigil
- `src/exec/session/daemon/{client,serve}/` - the resident session
  proper: the socket server, request routing, the client (the answer
  keep it serves lives in the library's warm core)
- `src/exec/session/warden/` - rationing and standdown; the daemon never
  taxes the machine it serves
- `src/surface/cli/` - the product vocabulary: flag surfaces, grades,
  the `--schema`/`--generate` manifest driver, the primer, reprise
- `src/surface/face/{gist,relate}/` - both binary faces
- `src/surface/ffi/` + `include/` - the session C ABI
  (`libirregex.{a,dylib,so}`, `irregex.h`)
- `bindings/` - Go (cgo), Python (cffi), Rust consumers of that ABI
- `editor/` - the Vim/Neovim plugin (`:grep`-as-gist, streamed quickfix,
  `:GistRank`, `:GistBlast`)
- `shell/` - the generated man page + bash/zsh/fish/pwsh completions,
  minted from the same flag table argv is parsed with
- `bench/{certificate,dominance,rungs}/` - the vs-ripgrep dominance
  certificate and the ratio gates that keep it honest

## Build and test

```bash
zig build             # gist + relate binaries + libirregex → zig-out/
zig build test        # the unit suite
zig build check       # compile-only
zig build coverage    # per-function coverage
```

The binaries default to ReleaseFast regardless of the build's own
optimize mode (`-Dcli-optimize` overrides); the test binary stays
ReleaseSafe so the suite that tries to break the checks keeps them.

Dev model: sibling checkouts. `build.zig.zon` path-deps on `../irregex`
and `../relate`; releases pin url + hash. Inside billy,
`make install-gist` prefers these checkouts and symlinks the built
binaries onto PATH.

## Provenance

Extracted from `irregex` (cut at the extraction commit,
PLAN v5 split). The cut line is ripgrep's: what `rg`-the-binary owns
(the daemon, the product vocabulary, distribution, the certificate)
lives here; what the `grep-*` crates own (engines, walker, index, argv)
lives in the library. Architecture is machine-checked by
`contract/gist.ward`.
