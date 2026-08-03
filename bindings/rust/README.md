# gist - indexed code search for Rust

## What it is

The Rust face of [GIST](../../README.md), the dogfooded, `ripgrep`-parity
code-search kernel. One clean `search()` (plus `files()`, `count()`, `status()`)
that any Rust automation can call instead of hand-rolling `std::process::Command`
argv and `--json` parsing per site.

The shared substrate — contracts, row protocol, transports, typed failures —
lives in the [`irgx`](https://crates.io/crates/irgx) crate. Kinship and composed
verbs are their own crates
([`relate-search`](https://crates.io/crates/relate-search),
[`blast-search`](https://crates.io/crates/blast-search)); depending on `gist`
does not make them reachable.

```rust
for m in gist::search(r"func\s+\w+\(")? {
    println!("{}:{}: {}", m.path, m.line_number, m.text);
}

let hits  = gist::files("TODO")?;                    // files-with-matches (-l)
let total = gist::count("panic")?;                   // total matching lines
let scoped = gist::SearchRequest::new("Session")     // the deep builder
    .path("src/server/api")
    .type_("go")
    .ignore_case()
    .run()?;
```

## Why it exists — and why subprocess, not FFI

This crate and the Python `gist` package realize the **same**
`SearchRequest → Match` contract (`../../../irregex/contract/engine.toml`) over
the **same** certified `gist` binary. It builds the exact rg-parity argv the CLI
accepts, runs the binary with `--json`, and parses the JSON-lines stream — so
results come from the same engine the CLI uses, never a second matcher.

Subprocess is the default transport: the CLI engine fails loud on
unsupported input via `die()` → `process::exit(2)`, which would terminate a host
that linked _it_ in-process. Here a bad pattern exits the _child_ and surfaces as a
typed `Error::UnsupportedPattern` — the host is never touched.

The binary is resolved at call time: env `GIST_BIN`, then `gist` on `PATH`, then
the repo's `zig-out/bin/gist`. Build it with `zig build`.

## In-process warm engine — the `native` feature

The pull-cursor C ABI is the graduation rung, and it never `die()`s:
every failure is the same typed `Error`. Build with `--features native` and the
crate additionally links `libgist` + `libirgx` and exposes a warm
`Engine` held open across queries, each yielding a pull `Cursor` of owned
`Match` records — the callback-free sibling of the daemon `Session`:

```rust
let engine = gist::Engine::open(["src/server/api"])?;   // none = rootless CWD walk
for m in engine.search(&gist::SearchRequest::new("TODO"))? {
    let m = m?;                                            // Iterator<Item = Result<Match>>
    println!("{}:{}: {}", m.path, m.line_number, m.text);
}
```

## Cross-crate wiring

```bash
cargo add gist-search   # pulls irgx, the substrate, as a normal dependency
```

The package on crates.io is
[`gist-search`](https://crates.io/crates/gist-search) and the library is `gist`,
so you still write `use gist::…`. The bare name belongs to an unrelated crate
with twenty thousand downloads and names there are permanent, which is the same
reason the PyPI distribution is `gist-search` too.

This checkout builds against the sibling substrate by path; a published build
ignores that and resolves the same version range of
[`irgx`](https://crates.io/crates/irgx) from the registry.

```toml
irgx = { version = "1.0.0", path = "../../../irregex/bindings/rust" }
```

## Layout

| Path | Job |
|---|---|
| `src/exact/` | `SearchRequest` re-export, aggregate, rank, native cursor |
| `src/index/` | trigram / atlas / shelf lifecycle helpers |
| `../irregex/bindings/rust` | substrate this crate depends on |
