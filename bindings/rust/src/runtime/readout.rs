//! Reading back the two streams the CLI prints rather than emits.
//!
//! Everything else the crate decodes is schema-driven (`decode`, `lower`).
//! These two are not, because neither is a row: ripgrep's `--json` record
//! stream is a *foreign* contract the exact face is held to byte-for-byte, and
//! `--rank` predates `--json` entirely and still prints for people. Both are
//! parsed here so the transport modules stay about processes.

use serde::Deserialize;

use crate::contract::{Match, MatchKind, RankKind, Ranked, Submatch};

/// Parse `--rank` stdout into [`Ranked`] rows in the engine's definition-first
/// order, dropping the interleaved timing/blank lines. Timing prints to stderr,
/// so stdout is rows-only, but the filter is defensive by design.
pub(crate) fn parse_rank(stream: &str) -> Vec<Ranked> {
    stream.lines().filter_map(rank_row).collect()
}

/// Parse one `--rank` row — `  N. path:line  [kind]  ×count  snippet` (rank.zig)
/// — into a [`Ranked`], or `None` if the line isn't a row. The `[kind]` bracket
/// is the anchor: `path:line` sits before it, `×count snippet` after; this
/// mirrors the Python face's `_RANK_ROW` regex without a regex dependency.
fn rank_row(line: &str) -> Option<Ranked> {
    let (kind, open, close) = ["def", "use", "gen"].iter().find_map(|tag| {
        let bracket = format!("[{tag}]");
        let i = line.find(&bracket)?;
        Some((RankKind::parse(tag)?, i, i + bracket.len()))
    })?;

    // Left of the bracket: `<n>. path:line`. The regex's non-greedy path means
    // the line number is the digit run immediately before the bracket.
    let left = line[..open].trim_end();
    let colon = left.rfind(':')?;
    let line_number: u64 = left[colon + 1..].parse().ok()?;
    let path = strip_rank_index(&left[..colon]);
    if path.is_empty() {
        return None;
    }

    // Right of the bracket: `  ×count  snippet` (× is U+00D7, the sign rank.zig
    // prints ahead of the per-file count).
    let rest = line[close..].trim_start().strip_prefix('\u{00d7}')?;
    let digits = rest.find(|c: char| !c.is_ascii_digit())?;
    let count: u64 = rest[..digits].parse().ok()?;

    Some(Ranked {
        path: path.to_owned(),
        line_number,
        kind,
        count,
        snippet: rest[digits..].trim_start().to_owned(),
    })
}

/// Strip the `\s*\d+\.\s*` rank-index prefix, leaving the bare path. Dot-safe:
/// only a leading run of digits followed by `.` is removed, so a dotted path
/// (`atelier.pb.go`) survives intact.
fn strip_rank_index(head: &str) -> &str {
    let h = head.trim_start();
    let digits = h.find(|c: char| !c.is_ascii_digit()).unwrap_or(h.len());
    if digits == 0 {
        return h;
    }
    h[digits..].strip_prefix('.').map_or(h, str::trim_start)
}

// ── `--json` wire records (private; deserialized then mapped to `Match`) ────

#[derive(Deserialize)]
struct Text {
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
struct WireSubmatch {
    #[serde(rename = "match")]
    matched: Text,
    start: usize,
    end: usize,
}

#[derive(Deserialize)]
struct WireData {
    path: Text,
    #[serde(default)]
    line_number: u64,
    lines: Text,
    #[serde(default)]
    submatches: Vec<WireSubmatch>,
}

#[derive(Deserialize)]
struct WireRecord {
    #[serde(rename = "type")]
    kind: String,
    data: WireData,
}

/// Parse ripgrep's JSON-lines record stream into [`Match`] records, preserving
/// engine output order and dropping non-match/context records (begin/end/summary).
pub(crate) fn parse_json(stream: &str) -> Vec<Match> {
    let mut out = Vec::new();
    for line in stream.lines().filter(|l| !l.is_empty()) {
        let Ok(rec) = serde_json::from_str::<WireRecord>(line) else {
            continue;
        };
        let kind = match rec.kind.as_str() {
            "match" => MatchKind::Match,
            "context" => MatchKind::Context,
            _ => continue,
        };
        out.push(Match {
            path: rec.data.path.text,
            line_number: rec.data.line_number,
            text: rec.data.lines.text.trim_end_matches('\n').to_owned(),
            kind,
            submatches: rec
                .data
                .submatches
                .into_iter()
                .map(|s| Submatch {
                    text: s.matched.text,
                    start: s.start,
                    end: s.end,
                })
                .collect(),
        });
    }
    out
}
