//! `gist` — the importable Rust face of Billy's code-search kernel (ADR-352).
//!
//! One clean, rg-parity search API over the certified `gist` engine, sharing the
//! exact `SearchRequest` shape the CLI and the Python package speak. Results are
//! produced by the same engine the CLI uses — this crate *drives* it, it does not
//! reimplement search.
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
//! which is fatal for a naive in-process link. This crate is therefore a
//! **subprocess transport** — the authoritative one today: a bad pattern exits
//! the child and surfaces as [`Error::UnsupportedPattern`], never a terminated
//! host. A resident in-process FFI session is GIST's specified graduation rung;
//! when it lands, this same API swaps its transport underneath unchanged.
//!
//! The binary is resolved at call time: env `GIST_BIN`, then `gist` on `PATH`,
//! then the repo's `zig-out/bin/gist`. Build it with `make install-gist`.

mod aggregate;
pub mod contract;
mod engine;
mod error;
mod request;
#[cfg(unix)]
mod session;

pub use aggregate::{Axis, Group, Tally, tally, tally_by};
pub use contract::{Match, MatchKind, RankKind, Ranked, Submatch};
pub use error::{Error, Result};
pub use request::SearchRequest;
#[cfg(unix)]
pub use session::{Session, default_socket_path, warm_eligible};

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
/// [`SearchRequest`] and call [`SearchRequest::summary`].
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn summary(pattern: impl Into<SearchRequest>, by: Axis) -> Result<Tally> {
    pattern.into().summary(by)
}

/// The engine's definition-first `--rank` view: the top-`limit` files for
/// `pattern`, each tagged `def`/`use`/`gen` by the engine (`0` = engine
/// default). Ranking needs a persisted index; with none, the result is empty.
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn rank(pattern: impl Into<SearchRequest>, limit: u32) -> Result<Vec<Ranked>> {
    pattern.into().rank(limit)
}

/// The persisted-index freshness report (`gist status`).
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Io`] on spawn failure.
pub fn status() -> Result<String> {
    engine::status()
}

/// The driven binary's semver.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Io`] on spawn failure.
pub fn version() -> Result<String> {
    engine::version()
}

/// Absolute path to the resolved `gist` binary.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves.
pub fn binary() -> Result<std::path::PathBuf> {
    engine::binary()
}
