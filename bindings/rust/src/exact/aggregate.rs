//! Result-side aggregation over GIST matches.
//!
//! `search`/`files`/`count` answer *where* a pattern occurs; aggregation
//! answers *how it is distributed* — the question an agent asks next: which
//! files carry the most `TODO`s, which directories concentrate a `panic`, what
//! distinct error codes match `apperr\.\w+`. It is a pure post-processing layer
//! over the [`Match`] records the engine already returns: it never widens
//! [`crate::SearchRequest`] (the contract stays match-finding-only —
//! presentation and stats are deliberately *not* request options) and never
//! runs a second matcher.
//!
//! ```no_run
//! let hot = gist::tally(gist::search("TODO")?, gist::Axis::Dir);
//! for g in hot.top(5) {
//!     println!("{:4}  {}", g.count(), g.key);
//! }
//! # Ok::<(), gist::Error>(())
//! ```
//!
//! [`Axis`] selects the named bucketing; [`tally_by`] takes any
//! `Fn(&Match) -> String` for a custom axis. Only [`MatchKind::Match`] lines are
//! counted — `-A/-B/-C` context lines are display neighborhood, not matches, so
//! they never inflate a tally.

use std::collections::{BTreeSet, HashMap};

use irregex::contract::{Match, MatchKind};

/// The bucketing axis for a [`tally`] — the match property that decides which
/// bucket a match falls into.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    /// Bucket by the file the match is in.
    File,
    /// Bucket by the match's parent directory (`""` for a repo-root file).
    Dir,
    /// Bucket by file extension, dot included (`""` when the file has none).
    Ext,
    /// Bucket by the literal text that matched — the first submatch span, else
    /// the stripped line. The axis for "what distinct tokens did this pattern
    /// hit".
    Match,
}

impl Axis {
    /// The bucket label `m` belongs in along this axis.
    #[must_use]
    pub fn key(self, m: &Match) -> String {
        match self {
            Self::File => m.path.clone(),
            Self::Dir => dir_of(&m.path).to_owned(),
            Self::Ext => ext_of(&m.path).to_owned(),
            Self::Match => m
                .submatches
                .first()
                .map_or_else(|| m.text.trim().to_owned(), |s| s.text.clone()),
        }
    }
}

/// Parent directory of a `/`-separated path (`""` for a root-level file). Paths
/// are engine output, always forward-slashed, so this is deliberately not
/// `std::path` (which is platform-separator aware) — matching the Python face's
/// `posixpath.dirname`.
fn dir_of(path: &str) -> &str {
    path.rfind('/').map_or("", |i| &path[..i])
}

/// Extension of a path incl. the leading dot (`""` when the basename has none).
/// A dot in a parent directory never counts, and a leading-dot dotfile
/// (`.gitignore`) has no extension — mirroring `posixpath.splitext`.
fn ext_of(path: &str) -> &str {
    let base = path.rsplit('/').next().unwrap_or(path);
    match base.rfind('.') {
        Some(i) if i > 0 => &base[i..],
        _ => "",
    }
}

/// One aggregation bucket: every match sharing a `key`.
#[derive(Debug, Clone)]
pub struct Group {
    /// The bucket label (the axis value all these matches share).
    pub key: String,
    /// The matches in this bucket, in engine output order.
    pub matches: Vec<Match>,
}

impl Group {
    /// Matching lines in this bucket.
    #[must_use]
    pub fn count(&self) -> usize {
        self.matches.len()
    }

    /// Distinct files this bucket spans (1 for a file-axis bucket, ≥1 for a
    /// dir/ext/match axis).
    #[must_use]
    pub fn files(&self) -> usize {
        self.matches
            .iter()
            .map(|m| m.path.as_str())
            .collect::<BTreeSet<_>>()
            .len()
    }
}

/// Buckets ranked by descending match count (ties broken by key ascending) —
/// the shape a report or an agent reads top-down.
#[derive(Debug, Clone)]
pub struct Tally {
    /// The buckets, largest first.
    pub groups: Vec<Group>,
}

impl Tally {
    /// Total matching lines across every bucket.
    #[must_use]
    pub fn total(&self) -> usize {
        self.groups.iter().map(Group::count).sum()
    }

    /// Distinct files across every bucket.
    #[must_use]
    pub fn files(&self) -> usize {
        self.groups
            .iter()
            .flat_map(|g| g.matches.iter().map(|m| m.path.as_str()))
            .collect::<BTreeSet<_>>()
            .len()
    }

    /// The `n` largest buckets (all of them when `n == 0`).
    #[must_use]
    pub fn top(&self, n: usize) -> &[Group] {
        if n == 0 || n >= self.groups.len() {
            &self.groups
        } else {
            &self.groups[..n]
        }
    }

    /// The bucket labeled `key`, or `None` if the pattern never hit it.
    #[must_use]
    pub fn get(&self, key: &str) -> Option<&Group> {
        self.groups.iter().find(|g| g.key == key)
    }

    /// Number of buckets.
    #[must_use]
    pub fn len(&self) -> usize {
        self.groups.len()
    }

    /// Whether no buckets were formed (nothing was tallied).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.groups.is_empty()
    }

    /// Borrowing iterator over the buckets, largest first.
    pub fn iter(&self) -> std::slice::Iter<'_, Group> {
        self.groups.iter()
    }
}

impl<'a> IntoIterator for &'a Tally {
    type Item = &'a Group;
    type IntoIter = std::slice::Iter<'a, Group>;
    fn into_iter(self) -> Self::IntoIter {
        self.groups.iter()
    }
}

/// Bucket `matches` along a named [`Axis`] and rank the buckets by descending
/// count. See [`tally_by`] for a custom axis.
///
/// Pure and binary-free: it consumes [`Match`] records, so it composes with
/// [`crate::search`] or any other source and is unit-testable without the
/// engine. Context lines ([`MatchKind::Context`]) are skipped, so a request with
/// `-A/-B/-C` context still tallies only the true matches.
#[must_use]
pub fn tally<I>(matches: I, by: Axis) -> Tally
where
    I: IntoIterator<Item = Match>,
{
    tally_by(matches, |m| by.key(m))
}

/// [`tally`] with a caller-supplied axis: any `Fn(&Match) -> String` decides the
/// bucket label, for groupings the named [`Axis`] set doesn't cover (by symbol,
/// by first path segment, by a captured error code…).
#[must_use]
pub fn tally_by<I, F>(matches: I, key: F) -> Tally
where
    I: IntoIterator<Item = Match>,
    F: Fn(&Match) -> String,
{
    let mut buckets: HashMap<String, Vec<Match>> = HashMap::new();
    for m in matches {
        if m.kind == MatchKind::Match {
            buckets.entry(key(&m)).or_default().push(m);
        }
    }
    let mut groups: Vec<Group> = buckets
        .into_iter()
        .map(|(key, matches)| Group { key, matches })
        .collect();
    // A total order (count descending, then unique key ascending) makes the
    // result deterministic regardless of `HashMap` iteration order.
    groups.sort_by(|a, b| {
        b.matches
            .len()
            .cmp(&a.matches.len())
            .then_with(|| a.key.cmp(&b.key))
    });
    Tally { groups }
}
