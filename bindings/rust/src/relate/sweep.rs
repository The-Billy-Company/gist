//! The sweep family: N patterns, one walk, exact attribution.
//!
//! `patterns` answers with a row per hit; `pattern_counts` folds the same walk
//! into a tally engine-side, so a caller who only wants counts never pays to
//! ship the hits. The axis of the tally (per pattern or per file) is the only
//! difference between them, which is why both ride one params family.

use std::path::PathBuf;

use crate::contract::schema::VERBS;
use crate::runtime::relay::{Bin, Invocation};
use crate::runtime::{Error, Query, Result, Rows, Wire, answer, struct_size, sys};

/// Which axis `pattern_counts` folds the walk onto.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tally {
    /// One row per pattern: how often each intent fired.
    Pattern,
    /// One row per file: how concentrated the hits are.
    File,
}

/// A multi-pattern sweep.
#[derive(Debug, Clone)]
pub struct Sweep {
    patterns: Vec<String>,
    roots: Vec<PathBuf>,
    under: Option<String>,
    tally: Option<Tally>,
    fixed: bool,
    ignore_case: bool,
    top: u32,
}

impl Sweep {
    pub(crate) fn new<I: IntoIterator<Item = S>, S: Into<String>>(patterns: I) -> Self {
        Self {
            patterns: patterns.into_iter().map(Into::into).collect(),
            roots: Vec::new(),
            under: None,
            tally: None,
            fixed: false,
            ignore_case: false,
            top: 0,
        }
    }

    /// Scope the corpus to a root (repeatable).
    #[must_use]
    pub fn root(mut self, path: impl Into<PathBuf>) -> Self {
        self.roots.push(path.into());
        self
    }

    /// Scope the corpus to several roots at once.
    #[must_use]
    pub fn roots<I: IntoIterator<Item = P>, P: Into<PathBuf>>(mut self, paths: I) -> Self {
        self.roots.extend(paths.into_iter().map(Into::into));
        self
    }

    /// Restrict to files matching a glob, within the roots.
    #[must_use]
    pub fn under(mut self, glob: impl Into<String>) -> Self {
        self.under = Some(glob.into());
        self
    }

    /// Fold the walk into an engine-side tally instead of streaming hits — this
    /// is what makes the request `pattern_counts` rather than `patterns`.
    #[must_use]
    pub fn counted_by(mut self, axis: Tally) -> Self {
        self.tally = Some(axis);
        self
    }

    /// Treat every pattern as a literal.
    #[must_use]
    pub fn fixed(mut self, yes: bool) -> Self {
        self.fixed = yes;
        self
    }

    /// Case-insensitive matching.
    #[must_use]
    pub fn ignore_case(mut self, yes: bool) -> Self {
        self.ignore_case = yes;
        self
    }

    /// Cap the answer. `0` = the engine's default.
    #[must_use]
    pub fn top(mut self, n: u32) -> Self {
        self.top = n;
        self
    }

    /// Run the sweep.
    ///
    /// # Errors
    /// [`Error::Unrepresentable`] when no pattern was given; otherwise see
    /// [`crate::relate::Kinship::rows`].
    pub fn rows(&self) -> Result<Rows> {
        if self.patterns.is_empty() {
            return Err(Error::Unrepresentable(
                "a sweep needs at least one pattern".to_owned(),
            ));
        }
        answer(self)
    }

    fn flags(&self) -> u32 {
        let mut f = 0;
        if self.fixed {
            f |= sys::AN_FIXED;
        }
        if self.ignore_case {
            f |= sys::AN_IGNORE_CASE;
        }
        match self.tally {
            Some(Tally::Pattern) => f |= sys::AN_BY_PATTERN,
            Some(Tally::File) => f |= sys::AN_BY_FILE,
            None => {},
        }
        f
    }
}

impl Query for Sweep {
    fn op(&self) -> u32 {
        if self.tally.is_some() {
            super::OP_PATTERN_COUNTS
        } else {
            super::OP_PATTERNS
        }
    }

    fn roots(&self) -> &[PathBuf] {
        &self.roots
    }

    fn wire(&self) -> Wire<'_> {
        // `texts` must outlive the params struct; it does, because `Wire`'s
        // lifetime is pinned to `&self` and the Vec of views is rebuilt per call
        // — so it is leaked into the params only for the duration of the run.
        Wire::Sweep(
            sys::SweepParams {
                struct_size: struct_size::<sys::SweepParams>(),
                flags: self.flags(),
                patterns: std::ptr::null(),
                npatterns: self.patterns.len(),
                under: self.under.as_ref().map_or(std::ptr::null(), |u| u.as_ptr()),
                under_len: self.under.as_ref().map_or(0, String::len),
                top: self.top,
                reserved: 0,
            },
            std::marker::PhantomData,
        )
    }

    fn texts(&self) -> Vec<&str> {
        self.patterns.iter().map(String::as_str).collect()
    }

    fn argv(&self) -> Result<Invocation> {
        let schema = VERBS
            .get(self.op().saturating_sub(1) as usize)
            .map_or(0, |v| v.schema);
        let mut args = vec!["patterns".to_owned()];
        for p in &self.patterns {
            args.extend(["-e".to_owned(), p.clone()]);
        }
        if let Some(axis) = self.tally {
            let by = match axis {
                Tally::Pattern => "pattern",
                Tally::File => "file",
            };
            args.extend(["--by".to_owned(), by.to_owned()]);
        }
        if let Some(glob) = &self.under {
            args.extend(["--under".to_owned(), glob.clone()]);
        }
        if self.fixed {
            args.push("-F".to_owned());
        }
        if self.ignore_case {
            args.push("-i".to_owned());
        }
        if self.top > 0 {
            args.extend(["--top".to_owned(), self.top.to_string()]);
        }
        args.push("--json".to_owned());
        args.extend(self.roots.iter().map(|p| p.display().to_string()));
        Ok(Invocation::json(Bin::Relate, schema, args))
    }
}
