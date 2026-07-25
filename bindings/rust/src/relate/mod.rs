//! Search by resemblance rather than by pattern — the twelve `relate` verbs.
//!
//! Three question shapes, twelve entry points:
//!
//! * **kinship** ([`Kinship`]) — *what resembles what*: `similar` from one file,
//!   or a corpus-wide `dups`/`clusters`/`echoes`/`concepts`/`fragments`/
//!   `distinct` sweep.
//! * **retrieval** ([`Retrieval`]) — *what explains this text*: `recall`, the
//!   anti-redundant `pack`, and `quote`'s per-phrase attribution.
//! * **sweep** ([`Sweep`]) — *N patterns, one walk*: `patterns` and the folded
//!   `pattern_counts`.
//!
//! Every verb answers with [`Rows`](crate::Rows) — the same cursor, decoded
//! against the schema the contract binds to that op. Read fields by name
//! ([`Row::text`](crate::Row::text), [`f64`](crate::Row::f64),
//! [`variant`](crate::Row::variant), [`rows`](crate::Row::rows)); a field the
//! engine did not fill is `None`, which for a distance is not the same as `0.0`.

mod kinship;
mod retrieval;
mod sweep;

pub use kinship::Kinship;
pub use retrieval::Retrieval;
pub use sweep::{Sweep, Tally};

// `[analytic.verbs]` op codes. Append-only wire discriminants.
pub(crate) const OP_SIMILAR: u32 = 1;
pub(crate) const OP_DUPS: u32 = 2;
pub(crate) const OP_CLUSTERS: u32 = 3;
pub(crate) const OP_ECHOES: u32 = 4;
pub(crate) const OP_CONCEPTS: u32 = 5;
pub(crate) const OP_FRAGMENTS: u32 = 6;
pub(crate) const OP_DISTINCT: u32 = 7;
pub(crate) const OP_RECALL: u32 = 8;
pub(crate) const OP_PACK: u32 = 9;
pub(crate) const OP_QUOTE: u32 = 10;
pub(crate) const OP_PATTERNS: u32 = 11;
pub(crate) const OP_PATTERN_COUNTS: u32 = 12;

/// Nearest files to `path` by compression kinship, closest first.
///
/// Distance is `1 − Jaccard` over LZ78 phrase sketches: `0.0` is byte-identical.
/// Every row carries a calibrated [`Grade`](crate::Grade), so an answer made
/// only of background says so instead of looking like a hit — filter with
/// [`Kinship::min_grade`].
pub fn similar(path: impl Into<String>) -> Kinship {
    Kinship::targeted(OP_SIMILAR, path.into())
}

/// Near-duplicate file pairs at or under a distance threshold, closest first.
pub fn dups() -> Kinship {
    Kinship::sweeping(OP_DUPS)
}

/// Fork families — connected components of the verified duplicate graph.
///
/// The restructure-ready unit a pair list makes you re-derive; graded by the
/// family's *loosest* edge.
pub fn clusters() -> Kinship {
    Kinship::sweeping(OP_CLUSTERS)
}

/// DRY candidates `dups` cannot see: pairs far apart in bytes but close in
/// structure — the same skeleton wearing different vocabulary.
pub fn echoes() -> Kinship {
    Kinship::sweeping(OP_ECHOES)
}

/// Recurring concepts across the corpus, ranked by how much they explain.
pub fn concepts() -> Kinship {
    Kinship::sweeping(OP_CONCEPTS)
}

/// Sub-file kinship: repeated fragments below whole-file granularity.
pub fn fragments() -> Kinship {
    Kinship::sweeping(OP_FRAGMENTS)
}

/// The least-redundant members of the corpus — what is *not* a copy of anything.
pub fn distinct() -> Kinship {
    Kinship::sweeping(OP_DISTINCT)
}

/// Which files would describe this text most cheaply? Compression retrieval,
/// typo-tolerant, no regex — the verb to reach for when `gist` found nothing
/// and you are unsure of the spelling.
pub fn recall(text: impl Into<String>) -> Retrieval {
    Retrieval::new(OP_RECALL, text.into())
}

/// The *set* of files that jointly explains this text most cheaply.
///
/// Each pick is priced by the bits it adds *beyond* the picks before it, so a
/// near-duplicate of an earlier pick never makes the cut. This is the reading
/// set for a task, not a ranked list.
pub fn pack(text: impl Into<String>) -> Retrieval {
    Retrieval::new(OP_PACK, text.into())
}

/// Rewrite this text as corpus quotations, each phrase priced in bits and
/// attributed to a source file. Needs the codex shelf (`relate index --shelf`).
pub fn quote(text: impl Into<String>) -> Retrieval {
    Retrieval::new(OP_QUOTE, text.into())
}

/// N patterns, one walk, exact per-pattern attribution.
///
/// Cheaper than N sequential searches, and the attribution is engine-side.
/// Add [`Sweep::counted_by`] to get tallies rather than hits.
pub fn patterns<I: IntoIterator<Item = S>, S: Into<String>>(patterns: I) -> Sweep {
    Sweep::new(patterns)
}
