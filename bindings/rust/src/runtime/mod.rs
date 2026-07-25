//! Typed failures for the GIST search API (ADR-352).
//!
//! Every failure is a value the caller handles — a bad pattern surfaces as
//! [`Error::UnsupportedPattern`], never a terminated host process the way the
//! engine's own in-process `die()`/exit would. Zero dependencies: the enum is
//! hand-written so the crate's dependency graph stays to serde alone.

use std::fmt;

/// The one error type every fallible call in this crate returns.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// No `gist` binary could be located (env `GIST_BIN`, `PATH`, or the
    /// repo's `zig-out/bin/gist`). Build it with `make install-gist`.
    NotFound(String),
    /// The pattern or flag combination is outside GIST's linear-time engine
    /// (e.g. PCRE2 lookaround/backreferences, `-U` multiline) — the engine
    /// exited 2 and named the ripgrep fallback on stderr.
    UnsupportedPattern(String),
    /// The engine exited non-zero for an I/O, walk, or timeout reason (an
    /// unreadable directory, a missing explicit path) — fail-loud, never a
    /// silent empty result.
    Failed(String),
    /// A [`crate::SearchRequest`] option the in-process cursor ABI cannot honor
    /// (glob/type scoping, multiline, `no_index`, a non-linear `engine`, …). The
    /// in-process `Engine` carries only match-finding intent the C ABI has a
    /// field for; run the full CLI surface through [`crate::SearchRequest::run`]
    /// instead. Only reachable under the `native` feature.
    Unrepresentable(String),
    /// The child process could not be spawned or its pipes could not be read.
    Io(std::io::Error),
}

/// Crate-wide `Result` alias.
pub type Result<T> = std::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(m) => write!(f, "gist binary not found: {m}"),
            Self::UnsupportedPattern(m) => write!(f, "unsupported pattern: {m}"),
            Self::Failed(m) => write!(f, "gist search failed: {m}"),
            Self::Unrepresentable(m) => write!(f, "option not representable in-process: {m}"),
            Self::Io(e) => write!(f, "gist io error: {e}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
