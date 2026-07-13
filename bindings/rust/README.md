# gist — the importable Rust search API

## What it is

The Rust face of [GIST](../../README.md), Billy's dogfooded, `ripgrep`-parity
code-search kernel. One clean `search()` (plus `files()`, `count()`, `status()`)
that any Rust automation can call instead of hand-rolling `std::process::Command`
argv and `--json` parsing per site.

```rust
for m in gist::search(r"func\s+\w+\(")? {
    println!("{}:{}: {}", m.path, m.line_number, m.text);
}

let hits  = gist::files("TODO")?;                    // files-with-matches (-l)
let total = gist::count("panic")?;                   // total matching lines
let scoped = gist::SearchRequest::new("Wallet")      // the deep builder
    .path("services/backend")
    .type_("go")
    .ignore_case()
    .run()?;
```

## Why it exists — and why subprocess, not FFI

This crate and the Python `billy-gist` package realize the **same**
`SearchRequest → Match` contract (`../../contract/search_api.toml`, ADR-352) over
the **same** certified `gist` binary. It builds the exact rg-parity argv the CLI
accepts, runs the binary with `--json`, and parses the JSON-lines stream — so
results come from the same engine the CLI uses, never a second matcher.

Subprocess is the authoritative transport (ADR-352): the engine fails loud on
unsupported input via `die()` → `process::exit(2)`, which would terminate a host
that linked it in-process. Here a bad pattern exits the *child* and surfaces as a
typed `Error::UnsupportedPattern` — the host is never touched.

The binary is resolved at call time: env `GIST_BIN`, then `gist` on `PATH`, then
the repo's `zig-out/bin/gist`. Build it with `make install-gist`.

## Warm path — persistent `Session` (ADR-352 rung 2.5, Unix)

A `Session` keeps a Unix-socket connection to a running `gist serve` daemon warm
across many calls, so an eligible query skips the cold subprocess's process +
index-mmap + candidate-read startup:

```rust
let mut s = gist::Session::default_socket();   // $GIST_SESSION_SOCK or the repo default
let hot   = s.files(&gist::SearchRequest::new("TODO"))?;   // -l, warm
let total = s.count(&gist::SearchRequest::new("panic"))?;  // --count-matches, warm
```

It is **fail-open by construction**: no daemon listening, an ineligible request
(`gist::warm_eligible(&req)` is `false` for scoped roots, globs/types, context,
or any rich flag), or a wire hiccup transparently falls back to the
byte-identical cold subprocess. The wire protocol is the same one
`src/session/protocol.zig` defines and the Zig CLI + Python clients speak, so all
three frame-match against the one daemon.

## Standalone by design

Unlike the sibling C-ABI bindings (`principia` / `lamina` / `billog`), this crate
links **no** native archive — it drives a process — so it needs neither
`make build-gist` nor `zig-out/`. It is nonetheless a standalone crate (own
`Cargo.lock` + toolchain, excluded from the repo workspace) so the whole
`bindings/rust/` tree lifts out cleanly for the public OSS release without
dragging the workspace graph along.

```bash
cd pkg/kernels/gist/bindings/rust
cargo test           # behavioral + rg-parity (skips cleanly without gist/rg)
cargo clippy         # -D warnings clean
```

## Prior art

Drives the same engine as `rg` (the tool it is a drop-in for); the
request/result contract mirrors ripgrep's `--json` record stream. The Python
face lives at [`../python`](../python); the C-ABI FFI rung follows the sibling
kernel bindings once the engine's error path is refactored.
