//! The subprocess tier of the analytic plane — the fail-open floor.
//!
//! When the in-process plane is absent or declines, the same question is put to
//! the certified CLIs and their NDJSON is lowered into the *same* rows. Nothing
//! here knows what a verb means: a caller hands over an [`Invocation`] naming a
//! binary, an argv, and the `[row_schemas]` id the output lowers into, and this
//! module runs it and decodes it. That is why there is one JSON decoder rather
//! than seventeen — it is driven by the schema table, exactly as the wire
//! decoder is.
//!
//! Two verbs need more than a per-line mapping, and both get a declared
//! [`Shape`] rather than a bespoke parser: `quote` splits one logical row across
//! a header line and its phrase lines, and `blast` nests its answer under
//! grouping keys the row model flattens. `rank` is the third exception for a
//! different reason — `--rank` predates `--json` and still prints human text.

use serde_json::{Map, Value as Json};

use super::answer::{Stats, Tier};
use super::cell::{OwnedRow, OwnedValue};
use super::lower::{lower, ordinal_in};
use super::{Query, Result, Rows, shell};
use crate::contract::{Ranked, Variant};

/// Which certified binary answers a verb.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Bin {
    /// `gist` — the rg-parity exact face.
    Gist,
    /// `relate` — the compression face.
    Relate,
    /// `irregex` — the composed face.
    Irregex,
}

impl Bin {
    /// The executable name and the env var that overrides its resolution.
    const fn names(self) -> (&'static str, &'static str) {
        match self {
            Self::Gist => ("gist", "GIST_BIN"),
            Self::Relate => ("relate", "RELATE_BIN"),
            Self::Irregex => ("irregex", "IRREGEX_BIN"),
        }
    }
}

/// How a binary's stdout maps onto rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Shape {
    /// One JSON object per row — the common case.
    Rows,
    /// A header object followed by its phrase objects, folded into one row.
    Quotation,
    /// One object whose grouping keys the row schema flattens.
    Blast,
    /// The human `--rank` view, which has no `--json` form.
    Ranked,
}

/// The `[row_schemas]` ids the two folded shapes read, and the one the ranked
/// text parser lifts into. Named here because these three are the only places
/// the subprocess tier needs a schema the [`Invocation`] does not carry.
const QUOTATION: u32 = 13;
const PHRASE: u32 = 12;
const BLAST: u32 = 21;
const RANKED: u32 = 22;

/// One CLI invocation that answers an analytic verb.
pub(crate) struct Invocation {
    pub bin: Bin,
    pub args: Vec<String>,
    /// The `[row_schemas]` id the output lowers into.
    pub schema: u32,
    pub shape: Shape,
}

impl Invocation {
    /// A JSON-emitting invocation of `bin`.
    pub(crate) fn json(bin: Bin, schema: u32, args: Vec<String>) -> Self {
        Self {
            bin,
            args,
            schema,
            shape: Shape::Rows,
        }
    }

    /// Declare a non-per-line output shape.
    pub(crate) fn shaped(mut self, shape: Shape) -> Self {
        self.shape = shape;
        self
    }
}

/// Answer `query` out of process.
///
/// # Errors
/// [`super::Error::Unrepresentable`] for a request the CLI surface cannot
/// spell, plus the usual spawn / non-zero-exit failures.
pub(crate) fn run(query: &impl Query) -> Result<Rows> {
    let inv = query.argv()?;
    let (name, env) = inv.bin.names();
    let (out, diagnostics) = shell::both(&shell::binary_named(name, env)?, &inv.args, query.cwd())?;
    let (rows, stats) = match inv.shape {
        Shape::Rows => stream(&out, inv.schema),
        Shape::Quotation => quotation(&out),
        Shape::Blast => blast(&out),
        Shape::Ranked => (ranked(&out), Stats::default()),
    };
    let stats = Stats {
        // The CLI's own row count is per-verb and sometimes counts hits rather
        // than emitted rows, so what was actually decoded wins.
        rows: rows.len() as u64,
        tier: Some(Tier::Subprocess),
        // The compression face keeps results on stdout and diagnostics on
        // stderr, and the summary — where `foreign` and `omitted` live — is a
        // diagnostic. Reading only stdout would drop exactly the two facts that
        // distinguish "not in this corpus" and "truncated" from "no results".
        ..merge(stats, summaries(&diagnostics))
    };
    Ok(Rows::materialized(rows, Some(stats)))
}

/// Prefer whichever stream actually carried a counter: a verb may summarize on
/// either, and neither is authoritative for every field.
fn merge(stdout: Stats, stderr: Stats) -> Stats {
    let pick = |a: u64, b: u64| if a == 0 { b } else { a };
    Stats {
        foreign: pick(stdout.foreign, stderr.foreign),
        omitted: pick(stdout.omitted, stderr.omitted),
        files_considered: pick(stdout.files_considered, stderr.files_considered),
        refreshed: pick(stdout.refreshed, stderr.refreshed),
        rows: pick(stdout.rows, stderr.rows),
        elapsed_ns: pick(stdout.elapsed_ns, stderr.elapsed_ns),
        tier: stdout.tier.or(stderr.tier),
    }
}

/// The summary object out of a diagnostics stream, ignoring the hint lines
/// around it.
fn summaries(stderr: &str) -> Stats {
    objects(stderr).1
}

// ── stdout → rows ──────────────────────────────────────────────────────────

/// Split stdout into row objects and the trailing summary object the CLIs emit
/// (recognized by its `verb` key, which no row schema declares).
fn objects(stdout: &str) -> (Vec<Map<String, Json>>, Stats) {
    let mut rows = Vec::new();
    let mut stats = Stats::default();
    for line in stdout.lines() {
        let line = line.trim();
        if !line.starts_with('{') {
            continue;
        }
        let Ok(Json::Object(obj)) = serde_json::from_str::<Json>(line) else {
            continue;
        };
        if obj.contains_key("verb") {
            stats = summary(&obj);
        } else {
            rows.push(obj);
        }
    }
    (rows, stats)
}

/// Lower the CLI's trailing summary into the same stats the C ABI reports. The
/// binaries spell the counters slightly differently per verb, so each field
/// accepts the spellings that mean it.
fn summary(obj: &Map<String, Json>) -> Stats {
    let n = |keys: &[&str]| -> u64 {
        keys.iter()
            .find_map(|k| obj.get(*k).and_then(Json::as_u64))
            .unwrap_or(0)
    };
    Stats {
        foreign: n(&["foreign"]),
        omitted: n(&["omitted"]),
        files_considered: n(&["indexed_files", "total_files", "files", "shelf_files"]),
        refreshed: n(&["refreshed"]),
        rows: n(&["rows"]),
        elapsed_ns: obj
            .get("ms")
            .and_then(Json::as_f64)
            .map_or(0, |ms| (ms * 1e6) as u64),
        tier: Some(Tier::Subprocess),
    }
}

fn stream(stdout: &str, schema: u32) -> (Vec<OwnedRow>, Stats) {
    let (objs, stats) = objects(stdout);
    (objs.iter().map(|o| lower(schema, o)).collect(), stats)
}

/// `quote` reports one answer as a header line plus one line per phrase; the
/// `quotation` schema holds them as a single row with nested `phrases`.
fn quotation(stdout: &str) -> (Vec<OwnedRow>, Stats) {
    let (objs, stats) = objects(stdout);
    let Some((head, rest)) = objs.split_first() else {
        return (Vec::new(), stats);
    };
    // The header's own `phrases` is a COUNT; the schema's field is the nested
    // rows, so it is rebuilt from the phrase lines rather than coerced.
    let mut head = head.clone();
    head.remove("phrases");
    let mut row = lower(QUOTATION, &head);
    row.set(
        "phrases",
        OwnedValue::Rows(rest.iter().map(|o| lower(PHRASE, o)).collect()),
    );
    (vec![row], stats)
}

/// `blast` groups its answer under `seed` / `direct` / `tangential`; the `blast`
/// schema is flat, so the grouping keys are lifted before the generic lowering.
fn blast(stdout: &str) -> (Vec<OwnedRow>, Stats) {
    let (objs, stats) = objects(stdout);
    let Some(obj) = objs.first() else {
        return (Vec::new(), stats);
    };
    let at = |group: &str, key: &str| -> Option<&Json> { obj.get(group)?.get(key) };
    let mut flat = Map::new();
    for (field, value) in [
        ("symbol", at("seed", "symbol")),
        ("kind", at("seed", "kind")),
        ("definitions", at("seed", "def")),
        ("dependents", at("direct", "dependents")),
        ("dependencies", at("direct", "dependencies")),
        ("twins", at("tangential", "twins")),
        ("ripple", at("tangential", "ripple")),
        ("comments", obj.get("comments")),
        ("notes", obj.get("notes")),
        ("omitted", at("stats", "omitted")),
    ] {
        if let Some(v) = value {
            flat.insert(field.to_owned(), v.clone());
        }
    }
    (vec![lower(BLAST, &flat)], stats)
}

/// `gist --rank` predates `--json` and still prints its human view, so the
/// ranked rows come from the text parser and are lifted into the row model.
fn ranked(stdout: &str) -> Vec<OwnedRow> {
    super::readout::parse_rank(stdout)
        .into_iter()
        .map(|r: Ranked| {
            let mut row = OwnedRow::new(RANKED);
            row.set("path", OwnedValue::Text(r.path));
            row.set("line_number", OwnedValue::Int(r.line_number as i64));
            row.set(
                "kind",
                OwnedValue::Enum(Variant {
                    enum_id: 4,
                    ordinal: ordinal_in("rank_kind", r.kind.variant()),
                }),
            );
            row.set("count", OwnedValue::Int(r.count as i64));
            if !r.snippet.is_empty() {
                row.set("snippet", OwnedValue::Text(r.snippet));
            }
            row
        })
        .collect()
}

#[cfg(test)]
mod tests {
    //! The inputs are lines the certified CLIs actually print. What is under
    //! test here is the *shape* work — which line is a row, which is a summary,
    //! and how the two folded verbs recover a row the CLI split or nested.
    //! Field-level lowering is tested next door in `lower`.

    use super::*;
    use crate::contract::schema::SCHEMAS;

    fn schema_id(name: &str) -> u32 {
        SCHEMAS.iter().find(|s| s.name == name).map_or(0, |s| s.id)
    }

    #[test]
    fn the_summary_line_becomes_stats_and_never_a_row() {
        let stdout = concat!(
            r#"{"path":"a.rs","gain":0.8,"cost_bits":10.0,"bits_saved":4.0,"factors":2,"literals":1}"#,
            "\n",
            r#"{"verb":"recall","foreign":7,"rows":1,"ms":12.5,"indexed_files":900}"#,
        );
        let (rows, stats) = stream(stdout, schema_id("recalled"));
        assert_eq!(rows.len(), 1, "the summary is not a row");
        assert_eq!(stats.foreign, 7);
        assert_eq!(stats.files_considered, 900);
        assert_eq!(stats.elapsed_ns, 12_500_000);
        assert_eq!(stats.tier, Some(Tier::Subprocess));
    }

    #[test]
    fn quote_folds_its_phrase_lines_into_one_nested_row() {
        let stdout = concat!(
            r#"{"phrases":2,"bits":140.0,"quoted_bytes":31,"query_bytes":40,"escapes":0}"#,
            "\n",
            r#"{"text":"const fd =","bits":40.0,"source":"a.zig"}"#,
            "\n",
            r#"{"text":"openat(","bits":30.0,"source":"b.zig"}"#,
        );
        let (rows, _) = quotation(stdout);
        let row = rows.first().expect("one quotation").view().expect("schema");
        // The header's own `phrases` is a COUNT; the schema's field is the rows,
        // so a naive coercion would decode `2` and lose both phrase lines.
        let phrases = row.rows("phrases").expect("phrases nested");
        assert_eq!(phrases.len(), 2);
        assert_eq!(phrases.get(1).and_then(|p| p.text("source")), Some("b.zig"));
        assert_eq!(row.real("bits"), Some(140.0));
        assert_eq!(row.int("quoted_bytes"), Some(31));
    }

    #[test]
    fn blast_lifts_its_grouping_keys_into_the_flat_schema() {
        let stdout = concat!(
            r#"{"seed":{"symbol":"answer","kind":"fn","def":["src/a.rs#L12"]},"#,
            r#""direct":{"dependents":[{"path":"src/b.rs","line":4,"use":"def"}]},"#,
            r#""tangential":{"twins":[{"path":"src/c.rs","distance":0.2,"grade":"strong","channel":"copies"}]},"#,
            r#""stats":{"omitted":3}}"#,
        );
        let (rows, _) = blast(stdout);
        let row = rows.first().expect("one blast").view().expect("schema");
        assert_eq!(row.text("symbol"), Some("answer"));
        assert_eq!(row.int("omitted"), Some(3));
        let def = row.rows("definitions").and_then(|d| d.get(0)).expect("def");
        assert_eq!(def.text("path"), Some("src/a.rs"));
        assert_eq!(def.int("line"), Some(12));
        let dependent = row
            .rows("dependents")
            .and_then(|d| d.get(0))
            .expect("dependent");
        assert_eq!(dependent.flag("defines"), Some(true));
    }

    #[test]
    fn a_line_that_is_not_json_is_skipped_not_fatal() {
        // Stderr occasionally interleaves; a diagnostic must not become a row.
        let stdout = "gist: warming the atlas\n{\"unit\":\"a.rs\",\"distance\":0.1}\nnot json\n";
        let (rows, _) = stream(stdout, schema_id("similar"));
        assert_eq!(rows.len(), 1);
    }
}
