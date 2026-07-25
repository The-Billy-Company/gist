//! One analytic answer: the cursor its rows are pulled from, the batches they
//! arrive in, and the facts about the answer that no row can carry.
//!
//! ## Why pulling takes `&self`
//!
//! Unlike the exact plane's `irregex_cursor`, which recycles one submatch
//! scratch per pull, an analytic answer is materialized into a *single* arena
//! that stays valid until close (`include/irregex.h`, `irregex_rows_next_batch`).
//! Modeling a pull as `&mut self` would therefore invent an invalidation the ABI
//! does not have and forbid the very thing batching exists for — holding several
//! batches at once. The read position lives in a [`Cell`] instead, which makes a
//! cursor single-consumer (`!Sync`) without making its rows transient.
//!
//! The borrow is still the safety argument: a [`Row`] points into the cursor's
//! arena, so the compiler refuses to let one outlive the cursor, and
//! [`Row::to_owned`] is the only exit.

use std::cell::Cell;
use std::sync::Arc;

use super::cell::OwnedRow;
use super::plane::{EngineHandle, Vtable, fault};
use super::{Error, Result, Row, sys};

/// Which tier answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// Computed live from current bytes.
    Live,
    /// Folded from the persisted kinship atlas.
    Atlas,
    /// Read from the codex shelf (`quote` / `provenance`).
    Shelf,
    /// Answered out of process by a certified CLI.
    Subprocess,
}

/// Answer-level facts no row can carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    /// How many query fingerprints the corpus has **never seen**. Load-bearing
    /// for the retrieval verbs: a high count means "your text isn't in this
    /// repo", which is a different answer from "no results".
    pub foreign: u64,
    /// How many candidates a budget trimmed away, so a truncated answer says so.
    pub omitted: u64,
    /// Files the query considered.
    pub files_considered: u64,
    /// Files re-sketched to fold into a warm answer.
    pub refreshed: u64,
    /// Rows the engine produced.
    pub rows: u64,
    /// Wall-clock nanoseconds, as the engine measured it.
    pub elapsed_ns: u64,
    /// Which tier answered.
    pub tier: Option<Tier>,
}

impl Stats {
    fn from_wire(raw: &sys::Stats) -> Self {
        Self {
            foreign: raw.foreign,
            omitted: raw.omitted,
            files_considered: raw.files_considered,
            refreshed: raw.refreshed,
            rows: raw.rows,
            elapsed_ns: raw.elapsed_ns,
            tier: Some(match raw.source {
                sys::SOURCE_ATLAS => Tier::Atlas,
                sys::SOURCE_SHELF => Tier::Shelf,
                _ => Tier::Live,
            }),
        }
    }
}

/// A live `irregex_rows` cursor and everything that must outlive it.
pub(super) struct Native {
    pub(super) ptr: *mut sys::irregex_rows,
    pub(super) vt: &'static Vtable,
    pub(super) done: Cell<bool>,
    /// Keeps the corpus alive for as long as any row borrows its arena. Never
    /// read: holding it *is* the contract.
    pub(super) _engine: Arc<EngineHandle>,
}

impl Drop for Native {
    fn drop(&mut self) {
        unsafe { (self.vt.close)(self.ptr) };
    }
}

enum Source {
    Native(Native),
    /// A subprocess answer, already materialized. The `Vec` is never mutated
    /// after construction — only the read cursor moves — so rows handed out stay
    /// valid for as long as the cursor does, exactly as the arena does.
    Materialized {
        rows: Vec<OwnedRow>,
        at: Cell<usize>,
    },
}

/// A cursor over one analytic answer, from whichever tier produced it.
pub struct Rows {
    source: Source,
    /// What a subprocess answer reported on its summary line; the native tier
    /// asks the engine instead.
    summary: Option<Stats>,
}

impl Rows {
    /// A cursor over a live native answer.
    pub(super) fn native(native: Native) -> Self {
        Self {
            source: Source::Native(native),
            summary: None,
        }
    }

    /// A cursor over rows the subprocess tier already materialized.
    pub(crate) fn materialized(rows: Vec<OwnedRow>, summary: Option<Stats>) -> Self {
        Self {
            source: Source::Materialized {
                rows,
                at: Cell::new(0),
            },
            summary,
        }
    }

    /// Pull the next row.
    ///
    /// # Errors
    /// [`Error::Decode`] for a row that contradicts its declaration.
    pub fn next(&self) -> Option<Result<Row<'_>>> {
        match &self.source {
            Source::Native(n) => {
                if n.done.get() {
                    return None;
                }
                let mut raw = blank();
                match unsafe { (n.vt.next)(n.ptr, &raw mut raw) } {
                    sys::MATCH => Some(unsafe { Row::from_wire(&raw) }),
                    sys::OK => {
                        n.done.set(true);
                        None
                    },
                    other => {
                        n.done.set(true);
                        Some(Err(fault(n.vt, other, "row pull")))
                    },
                }
            },
            Source::Materialized { rows, at } => {
                let row = rows.get(at.get())?;
                at.set(at.get() + 1);
                Some(view(row))
            },
        }
    }

    /// Pull up to `size` rows in one crossing (`size` is clamped to ≥ 1).
    ///
    /// Every row in the returned batch borrows the same arena, so a caller may
    /// hold several batches at once and the compiler will agree — the point of
    /// batching, and what a per-pull scratch buffer could not offer.
    ///
    /// # Errors
    /// [`Error::Decode`] for a row that contradicts its declaration.
    pub fn batch(&self, size: usize) -> Option<Result<Batch<'_>>> {
        let size = size.max(1);
        match &self.source {
            Source::Native(n) => {
                if n.done.get() {
                    return None;
                }
                let mut buf = vec![blank(); size];
                let mut written = 0usize;
                let status = unsafe {
                    (n.vt.next_batch)(n.ptr, buf.as_mut_ptr(), buf.len(), &raw mut written)
                };
                match status {
                    sys::MATCH => Some(
                        buf[..written.min(size)]
                            .iter()
                            .map(|raw| unsafe { Row::from_wire(raw) })
                            .collect::<Result<Vec<_>>>()
                            .map(|rows| Batch { rows }),
                    ),
                    sys::OK => {
                        n.done.set(true);
                        None
                    },
                    other => {
                        n.done.set(true);
                        Some(Err(fault(n.vt, other, "row batch")))
                    },
                }
            },
            Source::Materialized { rows, at } => {
                let start = at.get();
                if start >= rows.len() {
                    return None;
                }
                let end = start.saturating_add(size).min(rows.len());
                at.set(end);
                Some(
                    rows[start..end]
                        .iter()
                        .map(view)
                        .collect::<Result<Vec<_>>>()
                        .map(|rows| Batch { rows }),
                )
            },
        }
    }

    /// Iterate batches of `size` rows.
    pub fn batches(&self, size: usize) -> BatchIter<'_> {
        BatchIter { rows: self, size }
    }

    /// Iterate rows one at a time. Every yielded row borrows the cursor, so a
    /// whole answer can be walked without copying.
    pub fn iter(&self) -> RowIter<'_> {
        RowIter { rows: self }
    }

    /// Answer-level facts. Final once the cursor is drained.
    #[must_use]
    pub fn stats(&self) -> Stats {
        if let Some(s) = self.summary {
            return s;
        }
        match &self.source {
            Source::Native(n) => {
                let mut raw = sys::Stats {
                    struct_size: super::struct_size::<sys::Stats>(),
                    ..sys::Stats::default()
                };
                if unsafe { (n.vt.stats)(n.ptr, &raw mut raw) } == sys::OK {
                    Stats::from_wire(&raw)
                } else {
                    Stats::default()
                }
            },
            Source::Materialized { rows, .. } => Stats {
                rows: rows.len() as u64,
                tier: Some(Tier::Subprocess),
                ..Stats::default()
            },
        }
    }

    /// Drain the cursor into owned rows that outlive it.
    ///
    /// # Errors
    /// [`Error::Decode`] for a row that contradicts its declaration.
    pub fn to_vec(&self) -> Result<Vec<OwnedRow>> {
        self.iter().map(|r| r.map(Row::to_owned)).collect()
    }
}

/// Borrow one materialized row, naming an id this build cannot decode.
fn view(row: &OwnedRow) -> Result<Row<'_>> {
    row.view()
        .ok_or_else(|| Error::Decode(format!("no schema {} in this build", row.schema_id)))
}

/// A zeroed row header for the engine to fill.
fn blank() -> sys::Row {
    sys::Row {
        schema_id: 0,
        nvalues: 0,
        present: 0,
        values: std::ptr::null(),
    }
}

/// One pull's worth of rows, all borrowing the cursor's arena.
pub struct Batch<'a> {
    rows: Vec<Row<'a>>,
}

impl<'a> Batch<'a> {
    /// The rows, in engine order.
    #[must_use]
    pub fn rows(&self) -> &[Row<'a>] {
        &self.rows
    }
}

impl<'a> std::ops::Deref for Batch<'a> {
    type Target = [Row<'a>];

    fn deref(&self) -> &Self::Target {
        &self.rows
    }
}

impl<'a> IntoIterator for Batch<'a> {
    type Item = Row<'a>;
    type IntoIter = std::vec::IntoIter<Row<'a>>;

    fn into_iter(self) -> Self::IntoIter {
        self.rows.into_iter()
    }
}

/// The batch iterator returned by [`Rows::batches`].
pub struct BatchIter<'a> {
    rows: &'a Rows,
    size: usize,
}

impl<'a> Iterator for BatchIter<'a> {
    type Item = Result<Batch<'a>>;

    fn next(&mut self) -> Option<Self::Item> {
        self.rows.batch(self.size)
    }
}

/// The row iterator returned by [`Rows::iter`].
pub struct RowIter<'a> {
    rows: &'a Rows,
}

impl<'a> Iterator for RowIter<'a> {
    type Item = Result<Row<'a>>;

    fn next(&mut self) -> Option<Self::Item> {
        self.rows.next()
    }
}

#[cfg(test)]
mod tests {
    //! Driven through the materialized source, because it is the one both tiers
    //! share: `next`/`batch`/`stats` are the same code paths a native cursor
    //! takes, minus the FFI crossing this build cannot make today.

    use super::*;
    use crate::contract::schema::SCHEMAS;
    use crate::runtime::cell::OwnedValue;

    fn similar(path: &str, distance: f64) -> OwnedRow {
        let id = SCHEMAS
            .iter()
            .find(|s| s.name == "similar")
            .map_or(0, |s| s.id);
        let mut row = OwnedRow::new(id);
        row.set("path", OwnedValue::Text(path.to_owned()));
        row.set("distance", OwnedValue::Real(distance));
        row
    }

    fn cursor(n: usize) -> Rows {
        Rows::materialized(
            (0..n).map(|i| similar(&format!("f{i}.rs"), 0.1)).collect(),
            None,
        )
    }

    #[test]
    fn batches_partition_the_answer_exactly_once() {
        let rows = cursor(7);
        let seen: Vec<String> = rows
            .batches(3)
            .filter_map(std::result::Result::ok)
            .flatten()
            .filter_map(|r| r.text("path").map(str::to_owned))
            .collect();
        assert_eq!(seen.len(), 7);
        assert_eq!(seen.first().map(String::as_str), Some("f0.rs"));
        assert_eq!(seen.last().map(String::as_str), Some("f6.rs"));
    }

    #[test]
    fn a_zero_batch_size_still_makes_progress() {
        // Clamping to one is what keeps `batches(0)` from being an infinite loop
        // that yields empty batches forever.
        let rows = cursor(2);
        assert_eq!(rows.batches(0).count(), 2);
    }

    #[test]
    fn several_batches_from_one_cursor_coexist() {
        // The headline property of batching: because a pull takes `&self` and
        // the arena outlives every pull, two batches are alive at once and both
        // still read. Were pulling `&mut self`, this would not compile.
        let rows = cursor(4);
        let first = rows
            .batch(2)
            .and_then(std::result::Result::ok)
            .expect("first batch");
        let second = rows
            .batch(2)
            .and_then(std::result::Result::ok)
            .expect("second batch");
        assert_eq!((first.rows().len(), second.rows().len()), (2, 2));
        assert_eq!(first.first().and_then(|r| r.text("path")), Some("f0.rs"));
        assert_eq!(second.first().and_then(|r| r.text("path")), Some("f2.rs"));
        assert!(rows.batch(2).is_none(), "the cursor is drained");
    }

    #[test]
    fn a_drained_cursor_reports_its_row_count_and_tier() {
        let rows = cursor(3);
        assert_eq!(rows.iter().count(), 3);
        let stats = rows.stats();
        assert_eq!(stats.rows, 3);
        assert_eq!(stats.tier, Some(Tier::Subprocess));
    }

    #[test]
    fn a_summary_line_wins_over_the_row_count() {
        // `foreign` is the retrieval verbs' "your text isn't in this repo"
        // signal, and it only ever arrives on the summary line — a cursor that
        // recomputed stats from its rows would erase it.
        let summary = Stats {
            foreign: 12,
            omitted: 5,
            tier: Some(Tier::Subprocess),
            ..Stats::default()
        };
        let rows = Rows::materialized(vec![similar("a.rs", 0.1)], Some(summary));
        assert_eq!((rows.stats().foreign, rows.stats().omitted), (12, 5));
    }

    #[test]
    fn owning_a_row_outlives_the_cursor_it_came_from() {
        let owned = {
            let rows = cursor(1);
            rows.to_vec().expect("materialized rows decode")
        };
        assert_eq!(
            owned
                .first()
                .and_then(OwnedRow::view)
                .and_then(|r| r.text("path")),
            Some("f0.rs")
        );
    }

    #[test]
    fn a_row_whose_schema_this_build_lacks_is_refused_not_skipped() {
        let beyond = u32::try_from(SCHEMAS.len()).unwrap_or(u32::MAX) + 1;
        let rows = Rows::materialized(vec![OwnedRow::new(beyond)], None);
        let err = rows
            .to_vec()
            .expect_err("an unknown schema must not decode");
        assert!(err.to_string().contains(&beyond.to_string()), "{err}");
    }
}
