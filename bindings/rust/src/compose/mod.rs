//! Both engines at once (ADR-367): exact narrows, compression reasons inside.
//!
//! A hand-run `gist -l | relate …` pipe throws the match information away
//! between the two steps and makes the statistical half pay whole-corpus noise.
//! These four verbs keep it: an exact `PatternSet` narrows the corpus to a typed
//! candidate set, and the compression kernel then runs *only* inside that
//! subset. The exact and statistical scores stay in separate row fields — never
//! fused into one number that means neither.
//!
//! | verb | question |
//! |---|---|
//! | [`context`] | the reading set among files that actually match some intents |
//! | [`family`] | which matching files are forks or renamed twins of each other |
//! | [`provenance`] | where a pasted snippet is really from, re-verified against live bytes |
//! | [`blast`] | what moves if I change this symbol |
//!
//! `context` and `family` require a scope — a root, or [`Composed::everywhere`]
//! — because a composed query must never silently sweep a vendor tree.

mod verbs;

pub use verbs::Composed;

pub(crate) const OP_CONTEXT: u32 = 13;
pub(crate) const OP_FAMILY: u32 = 14;
pub(crate) const OP_PROVENANCE: u32 = 15;
pub(crate) const OP_BLAST: u32 = 16;

/// The reading set among the files that match your intents.
///
/// Coverage packing over only the matching files: each pick reports the patterns
/// that admitted it and the bits it adds beyond the picks before it. Give it the
/// task text plus one or more [`Composed::pattern`] intents.
pub fn context(task: impl Into<String>) -> Composed {
    Composed::new(OP_CONTEXT).text(task)
}

/// Fork families among the files matching `symbol`.
///
/// Test files sharing a skeleton but not an API surface are *structural* twins,
/// so discovery there wants [`Composed::min_echo`]; byte copy-paste wants
/// [`Composed::max_distance`].
pub fn family(symbol: impl Into<String>) -> Composed {
    Composed::new(OP_FAMILY).pattern(symbol)
}

/// Quote attribution re-checked against each source's *current* bytes — a
/// phrase surfaces only if the live file still holds it.
///
/// Needs the codex shelf (`relate index --shelf`).
pub fn provenance(snippet: impl Into<String>) -> Composed {
    Composed::new(OP_PROVENANCE).text(snippet)
}

/// The live blast radius of a symbol, from current bytes and no precomputed
/// graph: the seed definition and kind, direct dependents and dependencies,
/// tangential twins, same-language ripple, and comments that mention it.
///
/// [`Composed::budget`] trims the low-priority tail; what it trimmed is counted
/// in [`Stats::omitted`](crate::Stats::omitted), never silently dropped.
pub fn blast(symbol: impl Into<String>) -> Composed {
    Composed::new(OP_BLAST).text(symbol)
}
