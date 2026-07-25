//! One builder for all four composed verbs — they share `[analytic.params]`
//! `compose`, because they ask the same two-part question with different halves
//! emphasized.

use std::path::PathBuf;

use crate::contract::schema::VERBS;
use crate::runtime::relay::{Bin, Invocation, Shape};
use crate::runtime::{Error, Query, Result, Rows, Wire, answer, struct_size, sys};

/// A composed question: an exact pattern set plus the text to reason about.
#[derive(Debug, Clone)]
pub struct Composed {
    op: u32,
    text: String,
    patterns: Vec<String>,
    roots: Vec<PathBuf>,
    all: bool,
    everywhere: bool,
    max_distance: Option<f64>,
    min_echo: Option<f64>,
    budget: u32,
    top: u32,
}

impl Composed {
    pub(crate) fn new(op: u32) -> Self {
        Self {
            op,
            text: String::new(),
            patterns: Vec::new(),
            roots: Vec::new(),
            all: false,
            everywhere: false,
            max_distance: None,
            min_echo: None,
            budget: 0,
            top: 0,
        }
    }

    pub(super) fn text(mut self, text: impl Into<String>) -> Self {
        self.text = text.into();
        self
    }

    /// Add an exact intent. Repeatable; a file is a candidate if it matches any
    /// of them, or every one under [`match_all`](Self::match_all).
    #[must_use]
    pub fn pattern(mut self, pattern: impl Into<String>) -> Self {
        self.patterns.push(pattern.into());
        self
    }

    /// Require every pattern to match, rather than any (`--match all`).
    #[must_use]
    pub fn match_all(mut self, yes: bool) -> Self {
        self.all = yes;
        self
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

    /// Deliberately sweep the whole corpus. `context` and `family` demand an
    /// explicit scope, and this is how you say "yes, all of it" — so a composed
    /// query can never wander into a vendor tree by omission.
    #[must_use]
    pub fn everywhere(mut self) -> Self {
        self.everywhere = true;
        self
    }

    /// Byte-kinship admission for [`family`](super::family).
    #[must_use]
    pub fn max_distance(mut self, t: f64) -> Self {
        self.max_distance = Some(t);
        self
    }

    /// Structural-echo admission for [`family`](super::family) — the right axis
    /// for test families, which share a skeleton but not an API surface.
    #[must_use]
    pub fn min_echo(mut self, e: f64) -> Self {
        self.min_echo = Some(e);
        self
    }

    /// Soft token cap for [`blast`](super::blast). What it trims is reported in
    /// [`Stats::omitted`](crate::Stats::omitted), not silently dropped.
    #[must_use]
    pub fn budget(mut self, n: u32) -> Self {
        self.budget = n;
        self
    }

    /// Cap the answer. `0` = the engine's default.
    #[must_use]
    pub fn top(mut self, n: u32) -> Self {
        self.top = n;
        self
    }

    /// Ask the question.
    ///
    /// # Errors
    /// [`Error::Unrepresentable`] when a scope-demanding verb was given neither
    /// a root nor [`everywhere`](Self::everywhere), or when an intent is
    /// missing; otherwise the usual transport failures.
    pub fn rows(&self) -> Result<Rows> {
        let scoped = self.everywhere || !self.roots.is_empty();
        match self.op {
            super::OP_CONTEXT | super::OP_FAMILY if !scoped => {
                return Err(Error::Unrepresentable(
                    "a composed query needs a scope: add `.root(…)`, or `.everywhere()` \
                     to sweep the whole corpus on purpose"
                        .to_owned(),
                ));
            },
            super::OP_CONTEXT if self.patterns.is_empty() => {
                return Err(Error::Unrepresentable(
                    "`context` needs at least one exact intent — that is what makes it \
                     composed rather than `relate pack`"
                        .to_owned(),
                ));
            },
            _ => {},
        }
        answer(self)
    }
}

impl Query for Composed {
    fn op(&self) -> u32 {
        self.op
    }

    fn roots(&self) -> &[PathBuf] {
        &self.roots
    }

    fn texts(&self) -> Vec<&str> {
        self.patterns.iter().map(String::as_str).collect()
    }

    fn wire(&self) -> Wire<'_> {
        let mut flags = 0;
        if self.max_distance.is_some() {
            flags |= sys::AN_MAX_DISTANCE;
        }
        if self.min_echo.is_some() {
            flags |= sys::AN_MIN_ECHO;
        }
        if self.all {
            flags |= sys::AN_MATCH_ALL;
        }
        Wire::Compose(
            sys::ComposeParams {
                struct_size: struct_size::<sys::ComposeParams>(),
                flags,
                text: self.text.as_ptr(),
                text_len: self.text.len(),
                patterns: std::ptr::null(),
                npatterns: self.patterns.len(),
                max_distance: self.max_distance.unwrap_or_default(),
                min_echo: self.min_echo.unwrap_or_default(),
                budget: self.budget,
                top: self.top,
            },
            std::marker::PhantomData,
        )
    }

    fn argv(&self) -> Result<Invocation> {
        let schema = VERBS
            .get(self.op.saturating_sub(1) as usize)
            .map_or(0, |v| v.schema);
        // `context` and `family` lost their verb names to ADR-367's fold: the
        // composition became a `--matching` flag on the direct faces, and the
        // `irregex` binary now carries only the two verbs that could not fold.
        let (bin, mut args) = match self.op {
            super::OP_CONTEXT => (
                Bin::Relate,
                vec!["pack".to_owned(), self.text.clone(), "--json".to_owned()],
            ),
            super::OP_FAMILY => (
                Bin::Relate,
                vec![
                    "echoes".to_owned(),
                    "--unit".to_owned(),
                    "function".to_owned(),
                    "--shape".to_owned(),
                    "families".to_owned(),
                    "--json".to_owned(),
                ],
            ),
            super::OP_PROVENANCE => (
                Bin::Irregex,
                vec![
                    "provenance".to_owned(),
                    self.text.clone(),
                    "--json".to_owned(),
                ],
            ),
            _ => (
                Bin::Irregex,
                vec!["blast".to_owned(), self.text.clone(), "--json".to_owned()],
            ),
        };
        for pattern in &self.patterns {
            args.extend(["--matching".to_owned(), pattern.clone()]);
        }
        if self.all {
            args.extend(["--match".to_owned(), "all".to_owned()]);
        }
        if self.op == super::OP_FAMILY {
            if let Some(t) = self.max_distance {
                args.extend(["--max-distance".to_owned(), format!("{t}")]);
            }
            if let Some(e) = self.min_echo {
                args.extend(["--min-echo".to_owned(), format!("{e}")]);
            }
        }
        if self.op == super::OP_BLAST && self.budget > 0 {
            args.extend(["--budget".to_owned(), self.budget.to_string()]);
        }
        if self.top > 0 && self.op != super::OP_BLAST && self.op != super::OP_PROVENANCE {
            args.extend(["--top".to_owned(), self.top.to_string()]);
        }
        args.extend(self.roots.iter().map(|p| p.display().to_string()));
        let inv = Invocation::json(bin, schema, args);
        // `provenance` already emits one JSON object per attribution, so only
        // `blast`'s grouped single object needs a declared shape.
        Ok(if self.op == super::OP_BLAST {
            inv.shaped(Shape::Blast)
        } else {
            inv
        })
    }
}
