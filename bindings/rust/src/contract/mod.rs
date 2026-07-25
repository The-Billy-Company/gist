//! Runtime mirror of `contract/search_api.toml` (ADR-352, ADR-377) plus the
//! result records both planes report.
//!
//! The package embeds the contract's load-bearing constants so it carries no
//! runtime dependency on the repo file (an OSS checkout ships without it); the
//! crate's parity test reads the canonical TOML and asserts this mirror matches
//! it — the standard registry-as-contract shape, so the two cannot silently
//! drift from the engine.
//!
//! The analytic plane's row-schema table is not hand-mirrored at all: it is
//! lowered from the same TOML into [`schema`] by
//! `tools/build_schema_tables.py`, and [`crate::runtime`] walks it to decode
//! every analytic row.

pub mod calibration;

/// The generated `[row_schemas]` / `[row_enums]` / `[analytic.verbs]` tables.
///
/// The generator writes this file to the crate's `src/` root, so the module is
/// mounted here by path rather than living beside its siblings.
#[path = "../schema.gen.rs"]
pub mod schema;

pub use calibration::{Channel, Grade, Polarity, Unit, Variant};

// ── `[meta]` ─────────────────────────────────────────────────────────────
/// C-ABI compatibility integer (tracks `src/root.zig` `abi()`).
pub const ABI_VERSION: u32 = 2;
/// Engine semver (tracks `src/root.zig` `version_string`).
pub const ENGINE_VERSION: &str = "0.2.0";
/// The Python distribution name (this crate is the Rust face of the same contract).
pub const PACKAGE_DIST: &str = "billy-irregex";
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
    "quiet",
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

// ── `[status_codes]` — the in-process C-ABI return vocabulary ──────────────
// Deliberately NOT folded into the exit codes above: exit 1 is "no match" while
// status 1 is "match", so one merged table would be a live hazard. Mirrored
// here rather than in the FFI module so a subprocess-only build still carries
// the vocabulary its parity test checks.
/// Ran cleanly, no match.
pub const STATUS_OK: i32 = 0;
/// Ran cleanly, at least one match (or: a record/row was written).
pub const STATUS_MATCH: i32 = 1;
/// This tier declines — a **declinature**, not a failure. The caller answers
/// through the next tier down and gets the identical result, so no binding may
/// surface it as an error value.
pub const STATUS_STALE: i32 = -1;
/// Allocation failed (fault domain `resource`).
pub const STATUS_OOM: i32 = -2;
/// The warm corpus could not be stood up (`corpus` / `persist` / `wire`).
pub const STATUS_OPEN_FAILED: i32 = -3;
/// An unknown flag bit or a wrongly-sized request struct — fail-closed.
pub const STATUS_INVALID: i32 = -4;

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
/// express (`src/rank/signals.zig`), and the `rank_kind` row enum on the wire.
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
    /// The CLI spelling (`"def"` / `"use"` / `"gen"`).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Def => "def",
            Self::Use => "use",
            Self::Gen => "gen",
        }
    }

    /// The `[row_enums].rank_kind` spelling the analytic plane carries.
    #[must_use]
    pub const fn variant(self) -> &'static str {
        match self {
            Self::Def => "definition",
            Self::Use => "use",
            Self::Gen => "generated",
        }
    }

    /// Parse either spelling — the CLI's short tag or the row enum's variant.
    /// `None` for anything else, including an ordinal past this build's table.
    #[must_use]
    pub fn parse(tag: &str) -> Option<Self> {
        match tag {
            "def" | "definition" => Some(Self::Def),
            "use" => Some(Self::Use),
            "gen" | "generated" => Some(Self::Gen),
            _ => None,
        }
    }
}

/// One row of the engine's `--rank` view: a file ranked definition-first by the
/// RRF kernel and tagged with the engine's own class. Schema `ranked` (id 22)
/// on the analytic plane; recovered from human stdout on the subprocess tier.
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
    /// The surfaced line, trimmed by the engine (empty when absent).
    pub snippet: String,
}

impl Ranked {
    /// True for codegen the engine demotes — never the agent's edit target.
    #[must_use]
    pub fn generated(&self) -> bool {
        self.kind == RankKind::Gen
    }
}
