//! `gist` — the importable Rust face of the code-search kernel.
//!
//! One clean, rg-parity search API over the certified `gist` engine, sharing the
//! exact `SearchRequest` shape the CLI and the Python package speak. Results are
//! produced by the same engine the CLI uses — this crate *drives* it, it does not
//! reimplement search.
//!
//! The shared substrate (contracts, row protocol, transports, typed failures)
//! lives in the [`irregex`] crate. Kinship / retrieval / sweep live in
//! [`relate`](https://crates.io/crates/relate); composed verbs live in
//! [`blast`](https://crates.io/crates/blast). Depending on `gist` does not make
//! those faces reachable.
//!
//! ```no_run
//! for m in gist::search(r"func\s+\w+\(")? {
//!     println!("{}:{}: {}", m.path, m.line_number, m.text);
//! }
//!
//! let hits  = gist::files("TODO")?;                              // files-with-matches
//! let total = gist::count("panic")?;                            // total matching lines
//! let scoped = gist::SearchRequest::new("Wallet")
//!     .path("services/backend")
//!     .type_("go")
//!     .run()?;
//! # Ok::<(), gist::Error>(())
//! ```
//!
//! Beyond *where* a pattern occurs, [`summary`] answers *how it is distributed*
//! (search then aggregate into ranked buckets), and [`rank`] answers *which hit
//! matters most* — gist's definition-first view (a symbol's declaration ahead of
//! its call sites, codegen demoted), with no rg equivalent:
//!
//! ```no_run
//! for g in gist::summary("TODO", gist::Axis::Dir)?.top(5) {
//!     println!("{:4}  {}", g.count(), g.key);
//! }
//! for r in gist::rank("SearchRequest", 5)? {
//!     println!("[{}] {}:{}", r.kind.as_str(), r.path, r.line_number); // skip r.generated()
//! }
//! # Ok::<(), gist::Error>(())
//! ```
//!
//! ## Why subprocess, not FFI
//!
//! The engine fails loud on unsupported input via `die()` → `process::exit(2)`,
//! which is fatal for a naive in-process link. The default crate is therefore a
//! **subprocess transport**: a bad pattern exits the child and surfaces as
//! [`Error::UnsupportedPattern`], never a terminated host. It carries no native
//! archive, so it lifts out cleanly for an OSS release.
//!
//! The binary is resolved at call time: env `GIST_BIN`, then `gist` on `PATH`,
//! then the repo's `zig-out/bin/gist`. Build it with `zig build`.
//!
//! ## The `native` feature — an in-process warm engine
//!
//! Opt into `native` and the crate additionally links `libgist` + `libirregex`
//! and exposes the pull-cursor surface: a warm [`Engine`] held open across many
//! queries, each yielding a pull [`Cursor`] that iterates owned [`Match`]
//! records, with a thread-safe [`CancelToken`] and per-operation [`Run`] budgets.
//! It never `die()`s — every failure is the same typed [`Error`]. The `build.rs`
//! resolves the libraries beside the kernel (or at `$GIST_LIB_DIR`); build them
//! with `zig build`.
//!
//! ```no_run
//! # #[cfg(feature = "native")] {
//! let engine = gist::Engine::open(["services/backend"])?;
//! for m in engine.search(&gist::SearchRequest::new("TODO"))? {
//!     let m = m?;
//!     println!("{}:{}: {}", m.path, m.line_number, m.text);
//! }
//! # }
//! # Ok::<(), gist::Error>(())
//! ```

pub mod exact;
pub mod index;

pub use exact::{Axis, Group, SearchEngine, SearchRequest, Tally, tally, tally_by};
#[cfg(feature = "native")]
pub use exact::{Batches, CancelToken, Cursor, DEFAULT_BATCH, Engine, Run};
pub use irregex::contract::{
    Channel, Grade, Match, MatchKind, RankKind, Ranked, Submatch, Unit, Variant,
};
pub use irregex::runtime::{
    Batch, Error, OwnedRow, OwnedValue, Result, Row, RowSeq, Rows, Stats, Texts, Tier, Value,
};
#[cfg(unix)]
pub use irregex::runtime::{Session, default_socket_path, warm_eligible};

/// Find `pattern`, returning structured [`Match`] records. For anything beyond a
/// bare pattern (paths, case-folding, globs, context…) build a [`SearchRequest`].
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn search(pattern: impl Into<SearchRequest>) -> Result<Vec<Match>> {
    pattern.into().run()
}

/// Sorted paths of files containing a match (the `-l` shape).
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn files(pattern: impl Into<SearchRequest>) -> Result<Vec<String>> {
    pattern.into().files()
}

/// Total matching lines across the searched tree.
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn count(pattern: impl Into<SearchRequest>) -> Result<usize> {
    pattern.into().count()
}

/// Search `pattern`, then tally the matches along `by` — "find, then see the
/// distribution" in one call. For scoped roots, globs, or other options, build a
/// [`SearchRequest`] and call [`tally`] on its [`SearchRequest::run`] result.
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn summary(pattern: impl Into<SearchRequest>, by: Axis) -> Result<Tally> {
    Ok(tally(pattern.into().run()?, by))
}

/// The engine's definition-first `--rank` view: the top-`limit` files for
/// `pattern`, each tagged `def`/`use`/`gen` by the engine (`0` = engine
/// default). Ranking needs a persisted index; with none, the result is empty.
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn rank(pattern: impl Into<SearchRequest>, limit: u32) -> Result<Vec<Ranked>> {
    let req = pattern.into();
    exact::rank_list(&req, limit)
}

/// The persisted-index freshness report (`gist status`).
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Io`] on spawn failure.
pub fn status() -> Result<String> {
    irregex::runtime::shell::status()
}

/// The driven binary's semver.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Io`] on spawn failure.
pub fn version() -> Result<String> {
    irregex::runtime::shell::version()
}

/// Absolute path to the resolved `gist` binary.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves.
pub fn binary() -> Result<std::path::PathBuf> {
    irregex::runtime::shell::binary()
}
