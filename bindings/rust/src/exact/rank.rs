//! `rank` — the one exact-plane verb whose answer is analytic rows.
//!
//! Ranking is a *judgment* about matches (a symbol's definition ahead of its two
//! hundred call sites, codegen demoted), so it cannot be a `Match` stream: the
//! row carries a per-file classification and count that no single hit has. That
//! is why `[analytic.verbs]` owns it while the rest of this module does not.
//!
//! The crate's public shape stays [`Ranked`] rather than raw rows. The typed
//! record is strictly more usable here — the schema has five fixed fields and
//! every one of them is always meaningful — and it keeps a caller who has been
//! using [`crate::rank`] working unchanged.

use std::path::PathBuf;

use super::SearchRequest;
use irregex::contract::{RankKind, Ranked};
use irregex::runtime::relay::{Bin, Invocation, Shape};
use irregex::runtime::{Query, Result, Row, Wire, answer, struct_size, sys};

/// The `[row_schemas].ranked` id, and `[analytic.verbs].rank`'s op.
const OP_RANK: u32 = 17;

/// Rank `request`, then lower the rows into the typed record.
pub(crate) fn rank_list(request: &SearchRequest, limit: u32) -> Result<Vec<Ranked>> {
    Rank { request, limit }.list()
}

struct Rank<'a> {
    request: &'a SearchRequest,
    limit: u32,
}

impl<'a> Rank<'a> {
    /// Rank, then lower the rows into the typed record.
    ///
    /// A row missing a non-optional field is decode corruption on the wire tier
    /// and simply an unranked file on the CLI tier, so the fallible fields
    /// default rather than abort a whole answer over one line.
    fn list(&self) -> Result<Vec<Ranked>> {
        let rows = answer(self)?;
        rows.iter()
            .map(|row| {
                row.map(|r: Row<'_>| Ranked {
                    path: r.text("path").unwrap_or_default().to_owned(),
                    line_number: r.int("line_number").unwrap_or_default().unsigned_abs(),
                    kind: r
                        .variant("kind")
                        .and_then(|v| v.name())
                        .and_then(RankKind::parse)
                        .unwrap_or(RankKind::Use),
                    count: r.int("count").unwrap_or_default().unsigned_abs(),
                    snippet: r.text("snippet").unwrap_or_default().to_owned(),
                })
            })
            .collect()
    }
}

impl Query for Rank<'_> {
    fn op(&self) -> u32 {
        OP_RANK
    }

    fn roots(&self) -> &[PathBuf] {
        // `SearchRequest` carries its scope as strings for the rg-parity argv;
        // the analytic engine keys its corpus on the *engine's* roots instead,
        // so an in-process rank runs over the ambient corpus and the pattern
        // does the narrowing. Path scoping stays a subprocess-tier concern.
        &[]
    }

    fn cwd(&self) -> Option<&std::path::Path> {
        self.request.cwd.as_deref()
    }

    fn wire(&self) -> Wire<'_> {
        Wire::Rank(
            sys::RankParams {
                struct_size: struct_size::<sys::RankParams>(),
                flags: 0,
                pattern: self.request.pattern.as_ptr(),
                pattern_len: self.request.pattern.len(),
                top: self.limit,
                reserved: 0,
            },
            std::marker::PhantomData,
        )
    }

    fn argv(&self) -> Result<Invocation> {
        let flag = if self.limit == 0 {
            "--rank".to_owned()
        } else {
            format!("--rank={}", self.limit)
        };
        let mut args = vec!["rg".to_owned()];
        args.extend(self.request.to_argv());
        args.push(flag);
        args.push("--regexp".to_owned());
        args.push(self.request.pattern.clone());
        args.extend(self.request.paths.iter().cloned());
        // `--rank` predates `--json` and still prints its human view, so the
        // subprocess tier lifts the text into rows rather than parsing JSON.
        Ok(Invocation::json(Bin::Gist, super::RANKED_SCHEMA, args).shaped(Shape::Ranked))
    }
}
