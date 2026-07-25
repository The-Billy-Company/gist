//! Transports, the fallback ladder, and the crate's typed failures.
//!
//! Every face of this crate asks its question here, and `runtime` decides *how*
//! it gets answered:
//!
//! | tier | when |
//! |---|---|
//! | [`plane`] — the in-process analytic C ABI | the symbols are present and the schema digest agrees |
//! | [`relay`] — the certified CLIs, NDJSON in | always; the fail-open floor |
//! | [`shell`] / [`session`] — the exact plane's process + resident transports | the rg-parity search surface |
//!
//! The ladder is **fail-open by construction**. `IRREGEX_STALE` is a
//! *declinature*, not a failure: the tier is saying "ask the next one and you
//! will get the same answer", so it never reaches the caller as an `Err`. The
//! same is true of an absent analytic symbol — an engine built before ADR-377
//! landed simply has no in-process plane, and the crate keeps working.
//!
//! Exactly two things are loud. A **schema digest mismatch** ([`Error::SchemaDrift`])
//! means the library's row tables and this build's decoder disagree, so falling
//! back would hide a real version skew; and a **row that contradicts its own
//! declaration** ([`Error::Decode`]) is corruption, not a miss.

pub mod answer;
pub mod cell;
pub mod decode;
pub mod handshake;
mod lower;
pub mod plane;
mod readout;
pub mod relay;
#[cfg(unix)]
pub mod session;
pub mod shell;
pub mod sys;
mod verify;

/// Synthesized wire buffers the decoder tests are driven from.
#[cfg(test)]
mod fixture;

#[cfg(unix)]
pub use session::{Session, default_socket_path, warm_eligible};

use std::fmt;
use std::os::raw::c_void;

pub use answer::{Batch, BatchIter, RowIter, Rows, Stats, Tier};
pub use cell::{OwnedRow, OwnedValue, RowSeq, Texts, Value};
pub use decode::Row;

/// The one error type every fallible call in this crate returns.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// No engine binary could be located (env `GIST_BIN`, `PATH`, or the
    /// repo's `zig-out/bin/`). Build it with `make install-gist`.
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
    /// instead.
    Unrepresentable(String),
    /// The loaded library's row-schema digest disagrees with the table this
    /// crate's decoder was generated from. Named down to the drifting schema,
    /// because the alternative is a silently mis-decoded row.
    SchemaDrift(String),
    /// A row contradicted its own declaration — an unknown schema id, a value
    /// tag disagreeing with the contract, or text that is not UTF-8.
    Decode(String),
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
            Self::SchemaDrift(m) => write!(f, "analytic schema drift: {m}"),
            Self::Decode(m) => write!(f, "analytic row does not match its schema: {m}"),
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

// ── the request seam ───────────────────────────────────────────────────────

/// One analytic request, lowered for whichever tier answers it.
///
/// Each of the five `[analytic.params]` families implements this once; the two
/// transports then consume the *same* request without either knowing the other
/// exists. Adding a verb to an existing family costs one [`Query::op`] arm.
pub(crate) trait Query {
    /// The `IRREGEX_OP_*` code (`[analytic.verbs]`).
    fn op(&self) -> u32;
    /// The size-checked C params struct, borrowing this request's buffers.
    fn wire(&self) -> Wire<'_>;
    /// The CLI invocation that answers the same question out of process.
    ///
    /// # Errors
    /// [`Error::Unrepresentable`] for a request the CLI surface cannot spell.
    fn argv(&self) -> Result<relay::Invocation>;
    /// The corpus roots. The in-process plane carries them on the *engine*
    /// (there is no roots field in any params family), the CLIs carry them as
    /// trailing argv — so the request declares them once, here.
    fn roots(&self) -> &[std::path::PathBuf];
    /// The pattern set for the two families that carry one (`sweep`, `compose`).
    ///
    /// Kept off [`Query::wire`] because an `irregex_text[]` has to be built
    /// somewhere that outlives the params struct, and the only such place is the
    /// caller of both.
    fn texts(&self) -> Vec<&str> {
        Vec::new()
    }
    /// The directory to run a subprocess in; `None` = inherit.
    fn cwd(&self) -> Option<&std::path::Path> {
        None
    }
}

/// A filled `[analytic.params]` family, borrowing the request that built it.
///
/// The families are separate structs (rather than one union) because
/// `irregex_analytic_run` size-checks each against its declared shape, and a
/// mismatched size is `IRREGEX_INVALID` by design.
pub(crate) enum Wire<'a> {
    Kinship(sys::KinshipParams, std::marker::PhantomData<&'a ()>),
    Retrieval(sys::RetrievalParams, std::marker::PhantomData<&'a ()>),
    Sweep(sys::SweepParams, std::marker::PhantomData<&'a ()>),
    Compose(sys::ComposeParams, std::marker::PhantomData<&'a ()>),
    Rank(sys::RankParams, std::marker::PhantomData<&'a ()>),
}

impl<'a> Wire<'a> {
    /// Point the two pattern-carrying families at a `irregex_text[]` the caller
    /// owns. `'a` ties that array to the same request the params borrow from, so
    /// the pointer cannot outlive the strings behind it.
    pub(crate) fn bind(&mut self, texts: &'a [sys::Text]) {
        let (ptr, n) = (texts.as_ptr(), texts.len());
        match self {
            Self::Sweep(p, _) => (p.patterns, p.npatterns) = (ptr, n),
            Self::Compose(p, _) => (p.patterns, p.npatterns) = (ptr, n),
            _ => {},
        }
    }

    /// The opaque pointer `irregex_analytic_run` expects, valid for `&self`.
    pub(crate) fn as_ptr(&self) -> *const c_void {
        match self {
            Self::Kinship(p, _) => std::ptr::from_ref(p).cast(),
            Self::Retrieval(p, _) => std::ptr::from_ref(p).cast(),
            Self::Sweep(p, _) => std::ptr::from_ref(p).cast(),
            Self::Compose(p, _) => std::ptr::from_ref(p).cast(),
            Self::Rank(p, _) => std::ptr::from_ref(p).cast(),
        }
    }
}

/// `struct_size` for a params family — the fail-closed handshake every
/// `[analytic.params]` struct opens with.
pub(crate) fn struct_size<T>() -> u32 {
    u32::try_from(std::mem::size_of::<T>()).unwrap_or(u32::MAX)
}

/// Answer one analytic request, walking the ladder.
///
/// # Errors
/// Propagates [`Error::SchemaDrift`] and [`Error::Decode`] loud; every other
/// in-process refusal falls through to the subprocess tier.
pub(crate) fn answer(query: &impl Query) -> Result<Rows> {
    match plane::run(query)? {
        Some(rows) => Ok(rows),
        None => relay::run(query),
    }
}
