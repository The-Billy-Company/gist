//! Runtime mirror of `contract/search_api.toml` (ADR-352) plus the result
//! records the engine's `--json` stream reports.
//!
//! The package embeds the contract's load-bearing constants so it carries no
//! runtime dependency on the repo file (an OSS checkout ships without it); the
//! crate's parity test reads the canonical TOML and asserts this mirror matches
//! it — the standard registry-as-contract shape, so the two cannot silently
//! drift from the engine.

use serde::Deserialize;

// ── `[meta]` ─────────────────────────────────────────────────────────────
/// C-ABI compatibility integer (tracks `src/root.zig` `abi()`).
pub const ABI_VERSION: u32 = 2;
/// Engine semver (tracks `src/root.zig` `version_string`).
pub const ENGINE_VERSION: &str = "0.1.0";
/// The Python distribution name (this crate is the Rust face of the same contract).
pub const PACKAGE_DIST: &str = "billy-gist";
/// The Python import name.
pub const PACKAGE_IMPORT: &str = "gist";

/// Mirrors `[request_options]` — the deep [`crate::SearchRequest`] surface. The
/// parity test asserts this set equals the TOML keys.
pub const REQUEST_OPTIONS: &[&str] = &[
    "pattern",
    "paths",
    "fixed",
    "ignore_case",
    "smart_case",
    "word",
    "invert",
    "globs",
    "iglobs",
    "types",
    "not_types",
    "before",
    "after",
    "context",
    "max_count",
    "max_depth",
    "hidden",
    "no_ignore",
    "follow",
    "no_index",
    "engine",
    "multiline",
    "multiline_dotall",
    "unicode",
];

/// Mirrors `[match_kinds]`.
pub const MATCH_KINDS: &[&str] = &["match", "context"];

// ── `[exit_codes]` — ripgrep's process codes, preserved end-to-end ─────────
/// At least one match.
pub const EXIT_MATCHED: i32 = 0;
/// Ran cleanly, found nothing.
pub const EXIT_NO_MATCH: i32 = 1;
/// Unsupported pattern/flag or an I/O/walk error — never a silent empty result.
pub const EXIT_ERROR: i32 = 2;

/// Mirrors `[tool_boundary.aliases]` — a tool-boundary parameter name → its
/// canonical request option (the agent / code-place seam lives in the Python
/// face; carried here for the parity gate's completeness).
pub const ALIASES: &[(&str, &str)] = &[
    ("query", "pattern"),
    ("glob", "globs"),
    ("context_lines", "context"),
];

/// Mirrors `[tool_boundary.routing_keys]` — recognized-but-ignored place/rank
/// selectors that stay outside GIST.
pub const ROUTING_KEYS: &[&str] = &["place", "at", "semantic"];

// ── result records ─────────────────────────────────────────────────────────

/// What a [`Match`] line is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchKind {
    /// A line containing at least one submatch.
    Match,
    /// A leading/trailing context line (`-A`/`-B`/`-C`, no submatches).
    Context,
}

impl MatchKind {
    /// The contract spelling (`"match"` / `"context"`).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Match => "match",
            Self::Context => "context",
        }
    }
}

/// One matched span within a line: its `text` and byte offsets `[start, end)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Submatch {
    /// The matched substring.
    pub text: String,
    /// Byte offset of the span start within the line.
    pub start: usize,
    /// Byte offset of the span end within the line.
    pub end: usize,
}

/// One structured result line, as the engine's `--json` stream reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    /// Path of the file the line lives in.
    pub path: String,
    /// 1-based line number (0 when the engine omitted it).
    pub line_number: u64,
    /// The line's text, trailing newline stripped.
    pub text: String,
    /// Whether this is a match line or a context line.
    pub kind: MatchKind,
    /// The matched spans (empty for a context line).
    pub submatches: Vec<Submatch>,
}

impl Match {
    /// 1-based column of the first submatch (0 when a context line).
    #[must_use]
    pub fn column(&self) -> usize {
        self.submatches.first().map_or(0, |s| s.start + 1)
    }
}

// ── ranked view (`gist --rank`) ──────────────────────────────────────────────

/// How the engine's `--rank` view classified a file — the property `grep` can't
/// express (`src/rank/signals.zig`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RankKind {
    /// A match on one of this file's lines *defines* the symbol.
    Def,
    /// Only call sites / references — no definition here.
    Use,
    /// A generated file (codegen), demoted by the authored boost.
    Gen,
}

impl RankKind {
    /// The contract spelling (`"def"` / `"use"` / `"gen"`).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Def => "def",
            Self::Use => "use",
            Self::Gen => "gen",
        }
    }

    /// Parse the engine's one-word tag; `None` for anything else.
    fn parse(tag: &str) -> Option<Self> {
        match tag {
            "def" => Some(Self::Def),
            "use" => Some(Self::Use),
            "gen" => Some(Self::Gen),
            _ => None,
        }
    }
}

/// One row of the engine's `--rank` view: a file ranked definition-first by the
/// RRF kernel and tagged with the engine's own class. This is gist's native
/// ranked shape (no rg equivalent) — a *presentation* result, deliberately not a
/// wire-contract [`MatchKind`], so it lives beside [`Match`] but outside the
/// [`crate::SearchRequest`] contract.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ranked {
    /// Path of the ranked file.
    pub path: String,
    /// The best line to surface — the definition, when the file has one.
    pub line_number: u64,
    /// The engine's classification of the file.
    pub kind: RankKind,
    /// Matching lines in this file.
    pub count: u64,
    /// The surfaced line, trimmed by the engine.
    pub snippet: String,
}

impl Ranked {
    /// True for codegen the engine demotes — never the agent's edit target.
    #[must_use]
    pub fn generated(&self) -> bool {
        self.kind == RankKind::Gen
    }
}

/// Parse `--rank` stdout into [`Ranked`] rows in the engine's definition-first
/// order, dropping the interleaved timing/blank lines. Timing prints to stderr,
/// so stdout is rows-only, but the filter is defensive by design.
pub(crate) fn parse_rank(stream: &str) -> Vec<Ranked> {
    stream.lines().filter_map(parse_rank_row).collect()
}

/// Parse one `--rank` row — `  N. path:line  [kind]  ×count  snippet` (rank.zig)
/// — into a [`Ranked`], or `None` if the line isn't a row. The `[kind]` bracket
/// is the anchor: `path:line` sits before it, `×count snippet` after; this
/// mirrors the Python face's `_RANK_ROW` regex without a regex dependency.
fn parse_rank_row(line: &str) -> Option<Ranked> {
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

#[cfg(test)]
mod rank_parse {
    use super::{RankKind, Ranked, parse_rank};

    // A captured `--rank` stdout block (rank.zig's exact
    // ` N. path:line  [kind]  ×count  snippet`; × is U+00D7).
    const SAMPLE: &str = concat!(
        " 1. pkg/kernels/irregex/bindings/rust/src/request.rs:33  [def]  \u{00d7}11  pub struct SearchRequest {\n",
        " 2. pkg/kernels/irregex/bindings/rust/tests/session.rs:15  [use]  \u{00d7}19  use gist::{SearchRequest};\n",
        " 3. services/backend/api/internal/pb/grpc/atelierpb/atelier.pb.go:2227  [gen]  \u{00d7}52  type SearchRequest struct {\n",
    );

    #[test]
    fn reads_every_field() {
        let rows = parse_rank(SAMPLE);
        assert_eq!(rows.len(), 3);
        assert_eq!(
            rows[0],
            Ranked {
                path: "pkg/kernels/irregex/bindings/rust/src/request.rs".to_owned(),
                line_number: 33,
                kind: RankKind::Def,
                count: 11,
                snippet: "pub struct SearchRequest {".to_owned(),
            }
        );
    }

    #[test]
    fn classifies_kinds() {
        let kinds: Vec<RankKind> = parse_rank(SAMPLE).iter().map(|r| r.kind).collect();
        assert_eq!(kinds, [RankKind::Def, RankKind::Use, RankKind::Gen]);
    }

    #[test]
    fn generated_flags_only_gen() {
        let flags: Vec<bool> = parse_rank(SAMPLE).iter().map(Ranked::generated).collect();
        assert_eq!(flags, [false, false, true]);
    }

    #[test]
    fn dotted_generated_path_survives() {
        // The rank-index prefix strip must not eat the `.pb.go` dots in the path.
        let row = &parse_rank(SAMPLE)[2];
        assert_eq!(
            row.path,
            "services/backend/api/internal/pb/grpc/atelierpb/atelier.pb.go"
        );
        assert_eq!(row.line_number, 2227);
        assert_eq!(row.count, 52);
    }

    #[test]
    fn skips_timing_and_blank_lines() {
        // Timing prints to stderr; a defensive parse still drops any non-row.
        let noisy = format!(
            "{SAMPLE}\n— 3 ranked matches (top 3) · read 24/26456 candidates · total 48.4 ms\n"
        );
        assert_eq!(parse_rank(&noisy).len(), 3);
    }
}
