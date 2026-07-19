//! The unified `SearchRequest` (ADR-352) — one search expressed once, runnable
//! on any face.
//!
//! It carries only match-finding *intent*; presentation, ranking, stats,
//! replace, and stdin stay CLI-only. A chainable builder gives Rust the
//! ergonomics Python gets from keyword arguments, and `to_argv` lowers the
//! request into the exact rg-parity argv the certified `gist` binary accepts —
//! so the crate never reimplements search, it drives the same engine.
//!
//! The field set mirrors `contract/search_api.toml`'s `[request_options]`; the
//! crate's parity test asserts the two never drift.

use std::path::PathBuf;
use std::time::Duration;

use crate::contract::Match;
use crate::engine::{self, DEFAULT_TIMEOUT};
use crate::error::Result;

/// Which matcher runs the pattern. Mirrors `[request_options].engine`: the
/// linear-time engine is the default, `Auto` escalates to PCRE2 only when the
/// pattern needs it, and `Pcre2` forces the vendored JIT backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SearchEngine {
    /// Trigram + DFA + Pike VM linear-time matcher (the default).
    #[default]
    Linear,
    /// Run linear first, escalate to PCRE2 only for constructs it can't express.
    Auto,
    /// The vendored PCRE2 10.x JIT backend (`-P`).
    Pcre2,
}

/// A search expressed once. Build it with [`SearchRequest::new`] then chain
/// setters; run it with [`run`](SearchRequest::run) / [`files`](SearchRequest::files)
/// / [`count`](SearchRequest::count).
///
/// ```no_run
/// let hits = gist::SearchRequest::new(r"func\s+\w+")
///     .path("services/backend")
///     .ignore_case()
///     .glob("*.go")
///     .run()?;
/// # Ok::<(), gist::Error>(())
/// ```
#[derive(Debug, Clone)]
pub struct SearchRequest {
    /// The regex (or literal, with [`fixed`](SearchRequest::fixed)) to find.
    pub pattern: String,
    /// Roots to search; empty means the engine's default roots (or CWD live-walk).
    pub paths: Vec<String>,
    pub fixed: bool,
    pub ignore_case: bool,
    pub smart_case: bool,
    pub word: bool,
    pub invert: bool,
    pub globs: Vec<String>,
    pub iglobs: Vec<String>,
    pub types: Vec<String>,
    pub not_types: Vec<String>,
    pub before: u32,
    pub after: u32,
    pub context: u32,
    pub max_count: u32,
    pub max_depth: u32,
    pub hidden: bool,
    pub no_ignore: bool,
    pub follow: bool,
    pub no_index: bool,
    /// Which matcher runs the pattern (`--engine`/`-P`).
    pub engine: SearchEngine,
    /// Allow a match to span line boundaries (`-U`).
    pub multiline: bool,
    /// Make `.` match newlines; implies [`multiline`](Self::multiline)
    /// (`--multiline-dotall`).
    pub multiline_dotall: bool,
    /// Explicit Unicode (`Some(true)`) or ASCII (`Some(false)`) semantics;
    /// `None` keeps the engine's own defaults (`--unicode`/`--no-unicode`).
    pub unicode: Option<bool>,
    /// Raw argv flags an advanced caller needs before the crate grows a
    /// first-class option — appended last so they never shadow the contract.
    pub extra_flags: Vec<String>,
    /// Working directory to run the engine in (`None` = the caller's CWD).
    pub cwd: Option<PathBuf>,
    /// Wall-clock ceiling for the child process.
    pub timeout: Duration,
}

impl SearchRequest {
    /// A request for `pattern` with every option at its default.
    #[must_use]
    pub fn new(pattern: impl Into<String>) -> Self {
        Self {
            pattern: pattern.into(),
            paths: Vec::new(),
            fixed: false,
            ignore_case: false,
            smart_case: false,
            word: false,
            invert: false,
            globs: Vec::new(),
            iglobs: Vec::new(),
            types: Vec::new(),
            not_types: Vec::new(),
            before: 0,
            after: 0,
            context: 0,
            max_count: 0,
            max_depth: 0,
            hidden: false,
            no_ignore: false,
            follow: false,
            no_index: false,
            engine: SearchEngine::Linear,
            multiline: false,
            multiline_dotall: false,
            unicode: None,
            extra_flags: Vec::new(),
            cwd: None,
            timeout: DEFAULT_TIMEOUT,
        }
    }

    /// Add one search root.
    #[must_use]
    pub fn path(mut self, p: impl Into<String>) -> Self {
        self.paths.push(p.into());
        self
    }

    /// Add several search roots.
    #[must_use]
    pub fn paths<I, S>(mut self, it: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.paths.extend(it.into_iter().map(Into::into));
        self
    }

    /// Add one include/exclude glob (a leading `!` excludes).
    #[must_use]
    pub fn glob(mut self, g: impl Into<String>) -> Self {
        self.globs.push(g.into());
        self
    }

    /// Add several globs.
    #[must_use]
    pub fn globs<I, S>(mut self, it: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.globs.extend(it.into_iter().map(Into::into));
        self
    }

    /// Restrict to a registered file type (e.g. `"py"`), repeatable.
    #[must_use]
    pub fn type_(mut self, t: impl Into<String>) -> Self {
        self.types.push(t.into());
        self
    }

    /// Exclude a registered file type, repeatable.
    #[must_use]
    pub fn not_type(mut self, t: impl Into<String>) -> Self {
        self.not_types.push(t.into());
        self
    }

    /// Add a case-insensitive glob, repeatable.
    #[must_use]
    pub fn iglob(mut self, g: impl Into<String>) -> Self {
        self.iglobs.push(g.into());
        self
    }

    /// Treat the pattern as a literal string (`-F`).
    #[must_use]
    pub fn fixed(mut self) -> Self {
        self.fixed = true;
        self
    }

    /// ASCII case-insensitive (`-i`).
    #[must_use]
    pub fn ignore_case(mut self) -> Self {
        self.ignore_case = true;
        self
    }

    /// Case-insensitive unless the pattern has an uppercase byte (`-S`).
    #[must_use]
    pub fn smart_case(mut self) -> Self {
        self.smart_case = true;
        self
    }

    /// Match whole words (`-w`).
    #[must_use]
    pub fn word(mut self) -> Self {
        self.word = true;
        self
    }

    /// Select non-matching lines (`-v`).
    #[must_use]
    pub fn invert(mut self) -> Self {
        self.invert = true;
        self
    }

    /// Search hidden files/dirs (`--hidden`).
    #[must_use]
    pub fn hidden(mut self) -> Self {
        self.hidden = true;
        self
    }

    /// Disable `.gitignore`/`.ignore`/`.rgignore` filtering (`--no-ignore`).
    #[must_use]
    pub fn no_ignore(mut self) -> Self {
        self.no_ignore = true;
        self
    }

    /// Follow symlinks (`-L`).
    #[must_use]
    pub fn follow(mut self) -> Self {
        self.follow = true;
        self
    }

    /// Force the pure live walk, skipping index acceleration (`--no-index`).
    #[must_use]
    pub fn no_index(mut self) -> Self {
        self.no_index = true;
        self
    }

    /// Select the matcher engine — [`SearchEngine::Auto`] (`--engine auto`) or
    /// [`SearchEngine::Pcre2`] (`-P`); the default is linear-time.
    #[must_use]
    pub fn engine(mut self, e: SearchEngine) -> Self {
        self.engine = e;
        self
    }

    /// Allow a match to span line boundaries (`-U`).
    #[must_use]
    pub fn multiline(mut self) -> Self {
        self.multiline = true;
        self
    }

    /// Make `.` match newlines; implies [`multiline`](Self::multiline)
    /// (`--multiline-dotall`).
    #[must_use]
    pub fn multiline_dotall(mut self) -> Self {
        self.multiline_dotall = true;
        self
    }

    /// Set explicit Unicode (`true`) or ASCII (`false`) semantics
    /// (`--unicode`/`--no-unicode`); unset keeps the engine's own defaults.
    #[must_use]
    pub fn unicode(mut self, on: bool) -> Self {
        self.unicode = Some(on);
        self
    }

    /// Lines of leading context (`-B`).
    #[must_use]
    pub fn before(mut self, n: u32) -> Self {
        self.before = n;
        self
    }

    /// Lines of trailing context (`-A`).
    #[must_use]
    pub fn after(mut self, n: u32) -> Self {
        self.after = n;
        self
    }

    /// Lines of context on both sides (`-C`).
    #[must_use]
    pub fn context(mut self, n: u32) -> Self {
        self.context = n;
        self
    }

    /// Stop after N matches per file (`-m`; 0 = unlimited).
    #[must_use]
    pub fn max_count(mut self, n: u32) -> Self {
        self.max_count = n;
        self
    }

    /// Cap directory descent depth (`--max-depth`; 0 = unlimited).
    #[must_use]
    pub fn max_depth(mut self, n: u32) -> Self {
        self.max_depth = n;
        self
    }

    /// Append a raw argv flag (escape hatch for a flag with no first-class setter).
    #[must_use]
    pub fn flag(mut self, f: impl Into<String>) -> Self {
        self.extra_flags.push(f.into());
        self
    }

    /// Run the engine in `dir` instead of the caller's CWD.
    #[must_use]
    pub fn cwd(mut self, dir: impl Into<PathBuf>) -> Self {
        self.cwd = Some(dir.into());
        self
    }

    /// Override the wall-clock ceiling for the child process.
    #[must_use]
    pub fn timeout(mut self, d: Duration) -> Self {
        self.timeout = d;
        self
    }

    /// Lower the option set into the flag argv (without pattern/paths, which the
    /// engine adapter positions). Order is deterministic and mirrors the Python
    /// face so the two build byte-identical argv.
    #[must_use]
    pub(crate) fn to_argv(&self) -> Vec<String> {
        let mut argv: Vec<String> = Vec::new();
        let mut push = |flag: &str| argv.push(flag.to_owned());
        if self.fixed {
            push("-F");
        }
        if self.ignore_case {
            push("-i");
        }
        if self.smart_case {
            push("-S");
        }
        if self.word {
            push("-w");
        }
        if self.invert {
            push("-v");
        }
        if self.hidden {
            push("--hidden");
        }
        if self.no_ignore {
            push("--no-ignore");
        }
        if self.follow {
            push("-L");
        }
        if self.no_index {
            push("--no-index");
        }
        // engine/multiline/unicode selectors — same order and spelling as the
        // Python face so both lower to byte-identical argv.
        match self.engine {
            SearchEngine::Auto => {
                argv.push("--engine".to_owned());
                argv.push("auto".to_owned());
            },
            SearchEngine::Pcre2 => argv.push("-P".to_owned()),
            SearchEngine::Linear => {},
        }
        if self.multiline || self.multiline_dotall {
            argv.push("-U".to_owned());
        }
        if self.multiline_dotall {
            argv.push("--multiline-dotall".to_owned());
        }
        if let Some(on) = self.unicode {
            let prefix = if on { "" } else { "no-" };
            argv.push(format!("--{prefix}unicode"));
            argv.push(format!("--{prefix}pcre2-unicode"));
        }
        for g in &self.globs {
            argv.push("-g".to_owned());
            argv.push(g.clone());
        }
        for g in &self.iglobs {
            argv.push("--iglob".to_owned());
            argv.push(g.clone());
        }
        for t in &self.types {
            argv.push("-t".to_owned());
            argv.push(t.clone());
        }
        for t in &self.not_types {
            argv.push("-T".to_owned());
            argv.push(t.clone());
        }
        // -A/-B take precedence over -C in the engine; emit the explicit sides
        // when set, else the symmetric context.
        if self.before > 0 {
            argv.push("-B".to_owned());
            argv.push(self.before.to_string());
        }
        if self.after > 0 {
            argv.push("-A".to_owned());
            argv.push(self.after.to_string());
        }
        if self.context > 0 && self.before == 0 && self.after == 0 {
            argv.push("-C".to_owned());
            argv.push(self.context.to_string());
        }
        if self.max_count > 0 {
            argv.push("-m".to_owned());
            argv.push(self.max_count.to_string());
        }
        if self.max_depth > 0 {
            argv.push("--max-depth".to_owned());
            argv.push(self.max_depth.to_string());
        }
        argv.extend(self.extra_flags.iter().cloned());
        argv
    }

    /// Execute and return structured matches (and any requested context lines),
    /// in engine output order.
    ///
    /// # Errors
    /// [`Error::UnsupportedPattern`](crate::Error::UnsupportedPattern) for a
    /// pattern outside the linear-time engine, [`Error::Failed`](crate::Error::Failed)
    /// on an I/O/walk/timeout failure, [`Error::NotFound`](crate::Error::NotFound)
    /// when no binary resolves.
    pub fn run(&self) -> Result<Vec<Match>> {
        engine::run(self)
    }

    /// Paths of files with ≥1 matching line (`-l`), sorted.
    ///
    /// # Errors
    /// As [`run`](SearchRequest::run).
    pub fn files(&self) -> Result<Vec<String>> {
        engine::files(self)
    }

    /// Total matching lines across the searched tree (`--count-matches`).
    ///
    /// # Errors
    /// As [`run`](SearchRequest::run).
    pub fn count(&self) -> Result<usize> {
        engine::count(self)
    }

    /// Run, then aggregate the matches along `by` into buckets ranked by
    /// descending count — [`run`](SearchRequest::run) then [`crate::tally`].
    ///
    /// # Errors
    /// As [`run`](SearchRequest::run).
    pub fn summary(&self, by: crate::Axis) -> Result<crate::Tally> {
        Ok(crate::tally(self.run()?, by))
    }

    /// The engine's definition-first `--rank` view for this request: the
    /// top-`limit` files (`0` = the engine default), each tagged `def`/`use`/`gen`.
    /// Ranking needs a persisted index; with none, the result is empty.
    ///
    /// # Errors
    /// As [`run`](SearchRequest::run); the ranked rows are parsed from the
    /// engine's `--rank` stdout.
    pub fn rank(&self, limit: u32) -> Result<Vec<crate::Ranked>> {
        engine::rank(self, limit)
    }
}

impl<S: Into<String>> From<S> for SearchRequest {
    /// A bare pattern is a request with default options.
    fn from(pattern: S) -> Self {
        Self::new(pattern)
    }
}
