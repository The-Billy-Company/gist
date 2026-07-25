//! The retrieval family: free text priced against the corpus.
//!
//! `recall · pack · quote` all take prose rather than a pattern and answer in
//! *bits* — how cheaply the corpus can describe this text. They differ in what
//! they return, not in what they ask, so they share one params struct.
//!
//! [`Rows::stats`](crate::Rows::stats)'s `foreign` counter matters most here:
//! it counts query fingerprints the corpus has never seen, which is how a
//! caller tells "your text isn't in this repo" from "no results".

use std::path::PathBuf;

use crate::contract::schema::VERBS;
use crate::runtime::relay::{Bin, Invocation, Shape};
use crate::runtime::{Query, Result, Rows, Wire, answer, struct_size, sys};

/// A retrieval question over free text.
#[derive(Debug, Clone)]
pub struct Retrieval {
    op: u32,
    query: String,
    roots: Vec<PathBuf>,
    top: u32,
}

impl Retrieval {
    pub(crate) fn new(op: u32, query: String) -> Self {
        Self {
            op,
            query,
            roots: Vec::new(),
            top: 0,
        }
    }

    /// Scope the corpus. `quote` always reads the whole codex shelf and ignores
    /// this, as the CLI does.
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

    /// Cap the answer. `0` = the engine's default.
    #[must_use]
    pub fn top(mut self, n: u32) -> Self {
        self.top = n;
        self
    }

    /// Ask the question.
    ///
    /// # Errors
    /// See [`crate::relate::Kinship::rows`].
    pub fn rows(&self) -> Result<Rows> {
        answer(self)
    }
}

impl Query for Retrieval {
    fn op(&self) -> u32 {
        self.op
    }

    fn roots(&self) -> &[PathBuf] {
        &self.roots
    }

    fn wire(&self) -> Wire<'_> {
        Wire::Retrieval(
            sys::RetrievalParams {
                struct_size: struct_size::<sys::RetrievalParams>(),
                flags: 0,
                query: self.query.as_ptr(),
                query_len: self.query.len(),
                top: self.top,
                reserved: 0,
            },
            std::marker::PhantomData,
        )
    }

    fn argv(&self) -> Result<Invocation> {
        let def = VERBS.get(self.op.saturating_sub(1) as usize);
        let (verb, schema) = def.map_or(("?", 0), |v| (v.name, v.schema));
        // `recall` is the bare-text probe of `similar` after the CLI fold: a
        // path argument scores kinship, free text scores coding gain.
        let cli = if self.op == super::OP_RECALL {
            "similar"
        } else {
            verb
        };
        let mut args = vec![cli.to_owned(), self.query.clone()];
        if self.top > 0 {
            args.extend(["--top".to_owned(), self.top.to_string()]);
        }
        args.push("--json".to_owned());
        args.extend(self.roots.iter().map(|p| p.display().to_string()));
        let inv = Invocation::json(Bin::Relate, schema, args);
        Ok(if self.op == super::OP_QUOTE {
            inv.shaped(Shape::Quotation)
        } else {
            inv
        })
    }
}
