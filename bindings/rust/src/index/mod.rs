//! Persisted artifacts: build them, and ask what state they are in.
//!
//! Every verb in this crate answers correctly with no artifact at all — the
//! engine degrades to a live walk and says so in
//! [`Stats::tier`](crate::Stats::tier). An index is an **acceleration tier, not
//! a dependency**, and nothing here changes an answer; it only changes what a
//! question costs.
//!
//! Two artifacts, because the two engines ask different things of the corpus:
//! the [`Trigrams`](Artifact::Trigrams) index prefilters exact search, while the
//! [`Atlas`](Artifact::Atlas) snapshots every file's kinship sketch and
//! structure silhouette, and the [`Shelf`](Artifact::Shelf) is the phrase codex
//! `quote` and `provenance` attribute against. A warm answer folds in whatever
//! changed since the artifact's anchor, so a stale artifact stays *correct* and
//! merely prunes less.

use irgx::runtime::{Result, plane, shell};

/// A persisted artifact of one of the two engines.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Artifact {
    /// The trigram index that prefilters exact search (`gist index`).
    Trigrams,
    /// The kinship atlas the compression verbs fold (`relate index`).
    Atlas,
    /// The codex shelf `quote`/`provenance` attribute against
    /// (`relate index --shelf`, which also refreshes the atlas).
    Shelf,
}

impl Artifact {
    /// The binary that owns this artifact, and its env override.
    const fn owner(self) -> (&'static str, &'static str) {
        match self {
            Self::Trigrams => ("gist", "GIST_BIN"),
            Self::Atlas | Self::Shelf => ("relate", "RELATE_BIN"),
        }
    }

    const fn build_args(self) -> &'static [&'static str] {
        match self {
            Self::Trigrams | Self::Atlas => &["index"],
            Self::Shelf => &["index", "--shelf"],
        }
    }
}

/// Build or refresh `artifact`, returning whatever the engine reported.
///
/// Roots are the engine's own (`GIST_ROOTS`, else the working tree), so that one
/// tree cannot be indexed under two different notions of where it starts.
///
/// # Errors
/// [`Error::NotFound`](crate::Error::NotFound) when the binary does not resolve,
/// [`Error::Failed`](crate::Error::Failed) on a non-zero exit.
pub fn build(artifact: Artifact) -> Result<String> {
    let (bin, env) = artifact.owner();
    shell::lifecycle(bin, env, artifact.build_args())
}

/// The artifact's readiness and freshness report, as the engine renders it.
///
/// # Errors
/// [`Error::NotFound`](crate::Error::NotFound) when the binary does not resolve,
/// [`Error::Failed`](crate::Error::Failed) on a non-zero exit.
pub fn status(artifact: Artifact) -> Result<String> {
    let (bin, env) = artifact.owner();
    shell::lifecycle(bin, env, &["status"])
}

/// Whether an in-process analytic plane answered this process's symbol probe.
///
/// Diagnostic only: no caller needs to branch on it, because the ladder falls
/// through to the subprocess tier for the identical answer. It is here so a host
/// can *report* which tier it is paying for. A schema-digest mismatch reads as
/// `false` here and fails loud on the call itself — the one refusal that must
/// never be silently downgraded.
#[must_use]
pub fn analytic_plane() -> bool {
    plane::available()
}

/// The `[row_schemas]` digest this build's decoder was generated from.
///
/// Comparing it to another binding's digest is how two languages prove they
/// speak the same rows without either reading the other's generated table.
#[must_use]
pub fn schema_digest() -> &'static str {
    irgx::contract::schema::DIGEST
}
