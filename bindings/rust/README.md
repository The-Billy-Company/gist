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

This crate and the Python `billy-irregex` package realize the **same**
`SearchRequest → Match` contract (`../../contract/search_api.toml`, ADR-352) over
the **same** certified `gist` binary. It builds the exact rg-parity argv the CLI
accepts, runs the binary with `--json`, and parses the JSON-lines stream — so
results come from the same engine the CLI uses, never a second matcher.

Subprocess is the default transport (ADR-352): the CLI engine fails loud on
unsupported input via `die()` → `process::exit(2)`, which would terminate a host
that linked _it_ in-process. Here a bad pattern exits the _child_ and surfaces as a
typed `Error::UnsupportedPattern` — the host is never touched.

The binary is resolved at call time: env `GIST_BIN`, then `gist` on `PATH`, then
the repo's `zig-out/bin/gist`. Build it with `make install-gist`.

## In-process warm engine — the `native` feature

The pull-cursor C ABI (ADR-352) is the graduation rung, and it never `die()`s:
every failure is the same typed `Error`. Build with `--features native` and the
crate additionally links the self-contained `libirregex` and exposes a warm
`Engine` held open across queries, each yielding a pull `Cursor` of owned
`Match` records — the callback-free sibling of the daemon `Session`:

```rust
let engine = gist::Engine::open(["services/backend"])?;   // none = rootless CWD walk
for m in engine.search(&gist::SearchRequest::new("TODO"))? {
    let m = m?;                                            // Iterator<Item = Result<Match>>
    println!("{}:{}: {}", m.path, m.line_number, m.text);
}

let tok = engine.cancel_token()?;                          // trip from another thread
let cur = engine.run(&req, gist::Run::default().max_results(100).cancel(&tok))?;
for batch in cur.batches(64) { /* amortize the FFI crossing */ }
```

`Engine::search` is serialized (single-writer), but the cursors it returns own
their records and iterate independently. An option the ABI can't carry
(glob/type scoping, multiline, a non-linear engine) is a typed
`Error::Unrepresentable` — use `SearchRequest::run` (subprocess) for the full CLI
surface. The `build.rs` resolves `libirregex` beside the kernel or at
`$GIST_LIB_DIR`; build it with `make install-gist`.

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
`src/surface/exec/session/protocol.zig` defines and the Zig CLI + Python clients speak, so all
three frame-match against the one daemon.

## Find, then aggregate

`search`/`files`/`count` answer _where_ a pattern occurs. `summary` answers _how
it is distributed_ — the question an agent asks next — by searching, then
grouping the matches into buckets ranked by count:

```rust
// busiest directories first
for g in gist::summary("TODO", gist::Axis::Dir)?.top(5) {
    println!("{:4}  {}", g.count(), g.key);
}

// which ADRs does the tree cite most? — bucket by the literal that matched
let cited = gist::summary(r"ADR-\d+", gist::Axis::Match)?;

// a custom axis is any Fn(&Match) -> String
let by_component = gist::tally_by(gist::search("panic")?, |m| {
    m.path.split('/').next().unwrap_or("").to_owned()
});
```

`Axis` is the named set — `File` · `Dir` · `Ext` · `Match` — and `tally_by` takes
any `Fn(&Match) -> String` for a custom one. `tally(matches, axis)` is the pure
core: it aggregates any `Match` sequence you already have (so it composes with
`search` and is unit-testable without the binary), and only `MatchKind::Match`
lines are counted — `-A/-B/-C` context lines never inflate a tally. Aggregation
is a result-side layer: it does **not** widen `SearchRequest` (the contract stays
match-finding-only) and never runs a second matcher.

## Which hit matters most — the ranked view

`rank` is gist's one native shape with no rg equivalent: the definition-first
[RRF view](../../README.md#ranking) that puts a symbol's declaration ahead of its
200 call sites and **demotes generated files** (which the repo forbids editing, so
they're never the target):

```rust
for r in gist::rank("SearchRequest", 8)? {
    println!("{:>3} [{}]  {}:{}", r.count, r.kind.as_str(), r.path, r.line_number);
}

let authored: Vec<_> = gist::rank("apperr.New", 20)?
    .into_iter()
    .filter(|r| !r.generated())     // skip codegen
    .collect();
```

Each `Ranked` row carries the engine's own `def`/`use`/`gen` classification
(`RankKind`) — read straight from `--rank`, **never reclassified in Rust**, so
"what is generated" can't fork from the engine (`src/rank/signals.zig`). Ranking
reads the persisted index, so it needs one built (`make install-gist`); with no
index there is nothing to rank and the result is empty. The `limit` caps the rows
(`0` = the engine default of 20).

## Standalone by design

By **default** this crate links no native archive — it drives a process — so it
needs neither `make build-gist` nor `zig-out/`, and the whole `bindings/rust/`
tree lifts out cleanly for the public OSS release (own `Cargo.lock` + toolchain,
excluded from the repo workspace). The opt-in `native` feature is where it joins
the sibling C-ABI bindings (`principia` / `lamina` / `billog`) and links
`libirregex`.

```bash
cd pkg/kernels/irregex/bindings/rust
cargo test                    # subprocess: behavioral + rg-parity (skips without gist/rg)
cargo test --features native  # + in-process Engine/Cursor parity vs cold (needs libirregex)
cargo clippy --all-features   # clean
```

## Prior art

Drives the same engine as `rg` (the tool it is a drop-in for); the
request/result contract mirrors ripgrep's `--json` record stream. The Python
face lives at [`../python`](../python), the Go face at [`../go`](../go); all
realize the one `SearchRequest → Match` contract over the same engine.
