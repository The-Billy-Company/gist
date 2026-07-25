//! The kinship family: seven verbs, one question shape.
//!
//! `similar · dups · clusters · echoes · concepts · fragments · distinct` all
//! ask "what resembles what, and how much is that worth?", so they share one
//! `[analytic.params]` struct and one builder. Which verb you picked decides the
//! row schema and how the corpus is walked; every axis below —
//! [`channel`](Kinship::channel), [`unit`](Kinship::unit), the admission
//! threshold, [`min_grade`](Kinship::min_grade) — means the same thing on all of
//! them, which is the property `relate --help` calls "one vocabulary, every
//! verb".
//!
//! The wire keeps seven ops because `[analytic.verbs]` is append-only, but the
//! `relate` binary has since folded five of them into two verbs plus a `--shape`
//! axis. [`Form`] is where that translation lives, and it is the only place in
//! the crate that knows the CLI spelling differs from the contract's.

use std::path::PathBuf;

use crate::contract::schema::VERBS;
use crate::contract::{Channel, Grade, Polarity, Unit};
use crate::runtime::relay::{Bin, Invocation};
use crate::runtime::{Error, Query, Result, Rows, Wire, answer, struct_size, sys};

/// How one contract op is spelled by today's `relate`, and which defaults the
/// verb implies. `shape` is the axis the fold introduced; `thresholds` is false
/// for the one verb (`similar`) that ranks rather than admits, and so takes no
/// cutoff flag.
struct Form {
    cli: &'static str,
    shape: Option<&'static str>,
    channel: Channel,
    unit: Unit,
    thresholds: bool,
}

const fn form(op: u32) -> Form {
    let (cli, shape, channel, unit, thresholds) = match op {
        super::OP_DUPS => ("echoes", Some("pairs"), Channel::Copies, Unit::File, true),
        super::OP_CLUSTERS => (
            "echoes",
            Some("families"),
            Channel::Copies,
            Unit::File,
            true,
        ),
        super::OP_ECHOES => ("echoes", Some("pairs"), Channel::Twins, Unit::File, true),
        super::OP_CONCEPTS => (
            "echoes",
            Some("families"),
            Channel::Shapes,
            Unit::Function,
            true,
        ),
        super::OP_FRAGMENTS => (
            "echoes",
            Some("families"),
            Channel::Twins,
            Unit::Function,
            true,
        ),
        super::OP_DISTINCT => (
            "echoes",
            Some("distinct"),
            Channel::Copies,
            Unit::File,
            true,
        ),
        // OP_SIMILAR, and any op a newer contract adds to this family.
        _ => ("similar", None, Channel::Copies, Unit::File, false),
    };
    Form {
        cli,
        shape,
        channel,
        unit,
        thresholds,
    }
}

/// A kinship question, built axis by axis and asked with [`rows`](Self::rows).
///
/// Nothing runs until then, and the same request answers through whichever tier
/// is available — in-process when the analytic plane is present, the `relate`
/// binary otherwise, with identical rows either way.
#[derive(Debug, Clone)]
pub struct Kinship {
    op: u32,
    /// A file path, `path#Lnnn`, or probe text; absent = the corpus-wide sweep.
    target: Option<String>,
    roots: Vec<PathBuf>,
    matching: Vec<String>,
    channel: Channel,
    unit: Unit,
    max_distance: Option<f64>,
    min_echo: Option<f64>,
    min_grade: Grade,
    min_size: u32,
    min_lines: u32,
    top: u32,
    no_index: bool,
}

impl Kinship {
    /// One probe against the corpus.
    pub(crate) fn targeted(op: u32, target: String) -> Self {
        Self::seeded(op, Some(target))
    }

    /// The corpus against itself.
    pub(crate) fn sweeping(op: u32) -> Self {
        Self::seeded(op, None)
    }

    fn seeded(op: u32, target: Option<String>) -> Self {
        let f = form(op);
        Self {
            op,
            target,
            roots: Vec::new(),
            matching: Vec::new(),
            channel: f.channel,
            unit: f.unit,
            max_distance: None,
            min_echo: None,
            min_grade: Grade::None,
            min_size: 0,
            min_lines: 0,
            top: 0,
            no_index: false,
        }
    }

    /// Scope the corpus. No roots = the CWD walk, exactly as a bare CLI run.
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

    /// Price kinship only inside the files an exact pattern admits (ADR-367).
    /// Repeatable; see [`crate::compose`] for the composed verbs built on it.
    #[must_use]
    pub fn matching(mut self, pattern: impl Into<String>) -> Self {
        self.matching.push(pattern.into());
        self
    }

    /// Which kinship signal to read (`--as`). Also selects which admission
    /// threshold applies — see [`Channel::polarity`].
    #[must_use]
    pub fn channel(mut self, channel: Channel) -> Self {
        self.channel = channel;
        self
    }

    /// What a row *is*: a whole file, a function, or a single match.
    #[must_use]
    pub fn unit(mut self, unit: Unit) -> Self {
        self.unit = unit;
        self
    }

    /// Admit a candidate at distance ≤ `t` (the distance-polarity channels).
    #[must_use]
    pub fn max_distance(mut self, t: f64) -> Self {
        self.max_distance = Some(t);
        self
    }

    /// Admit a candidate whose bytes−structure gap is ≥ `e` (the `twins` channel).
    #[must_use]
    pub fn min_echo(mut self, e: f64) -> Self {
        self.min_echo = Some(e);
        self
    }

    /// Withhold anything weaker than `grade`. Empty beats background.
    #[must_use]
    pub fn min_grade(mut self, grade: Grade) -> Self {
        self.min_grade = grade;
        self
    }

    /// Smallest family worth reporting.
    #[must_use]
    pub fn min_size(mut self, n: u32) -> Self {
        self.min_size = n;
        self
    }

    /// Smallest fragment worth comparing — the sub-file noise floor.
    #[must_use]
    pub fn min_lines(mut self, n: u32) -> Self {
        self.min_lines = n;
        self
    }

    /// Cap the answer. `0` = the engine's default.
    #[must_use]
    pub fn top(mut self, n: u32) -> Self {
        self.top = n;
        self
    }

    /// Force the live build, skipping the persisted atlas. Acceleration never
    /// changes the answer, so this is a diagnostic lever, not a correctness one.
    #[must_use]
    pub fn no_index(mut self) -> Self {
        self.no_index = true;
        self
    }

    /// Ask the question.
    ///
    /// # Errors
    /// [`Error::Unrepresentable`] when a threshold contradicts the channel's
    /// polarity; [`Error::SchemaDrift`] when a loaded library's row tables
    /// disagree with this build; otherwise the usual spawn / engine failures.
    pub fn rows(&self) -> Result<Rows> {
        // Fail closed rather than send a threshold this channel ignores: a
        // silently dropped `--max-distance` on `twins` reads as an unfiltered
        // answer, which is the one failure mode calibration exists to prevent.
        match (self.channel.polarity(), self.max_distance, self.min_echo) {
            (Polarity::Gap, Some(_), _) | (Polarity::Distance, _, Some(_)) => {
                return Err(Error::Unrepresentable(format!(
                    "channel `{}` admits on {}, not the other threshold",
                    self.channel,
                    self.channel.admits()
                )));
            },
            _ => {},
        }
        answer(self)
    }

    /// The threshold flag this channel admits on, paired with its value.
    fn threshold(&self) -> Option<(&'static str, f64)> {
        match self.channel.polarity() {
            Polarity::Gap => self.min_echo.map(|e| ("--min-echo", e)),
            Polarity::Distance => self.max_distance.map(|t| ("--max-distance", t)),
        }
    }
}

impl Query for Kinship {
    fn op(&self) -> u32 {
        self.op
    }

    fn roots(&self) -> &[PathBuf] {
        &self.roots
    }

    fn wire(&self) -> Wire<'_> {
        let target = self.target.as_deref().unwrap_or_default().as_bytes();
        let mut flags = 0;
        if self.max_distance.is_some() {
            flags |= sys::AN_MAX_DISTANCE;
        }
        if self.min_echo.is_some() {
            flags |= sys::AN_MIN_ECHO;
        }
        if self.no_index {
            flags |= sys::AN_NO_INDEX;
        }
        if self.op == super::OP_DISTINCT {
            flags |= sys::AN_DISTINCT;
        }
        Wire::Kinship(
            sys::KinshipParams {
                struct_size: struct_size::<sys::KinshipParams>(),
                flags,
                target: if self.target.is_some() {
                    target.as_ptr()
                } else {
                    std::ptr::null()
                },
                target_len: target.len(),
                channel: self.channel.ordinal(),
                unit: self.unit.ordinal(),
                max_distance: self.max_distance.unwrap_or_default(),
                min_echo: self.min_echo.unwrap_or_default(),
                min_grade: self.min_grade.ordinal(),
                min_size: self.min_size,
                min_lines: self.min_lines,
                top: self.top,
            },
            std::marker::PhantomData,
        )
    }

    fn argv(&self) -> Result<Invocation> {
        let f = form(self.op);
        let schema = VERBS
            .get(self.op.saturating_sub(1) as usize)
            .map_or(0, |v| v.schema);
        let mut args = vec![f.cli.to_owned()];
        if let Some(t) = &self.target {
            args.push(t.clone());
        }
        args.extend(["--as".to_owned(), self.channel.as_str().to_owned()]);
        args.extend(["--unit".to_owned(), self.unit.as_str().to_owned()]);
        if let Some(shape) = f.shape {
            args.extend(["--shape".to_owned(), shape.to_owned()]);
        }
        for pattern in &self.matching {
            args.extend(["--matching".to_owned(), pattern.clone()]);
        }
        if f.thresholds {
            if let Some((flag, value)) = self.threshold() {
                args.extend([flag.to_owned(), format!("{value}")]);
            }
            if self.min_size > 0 {
                args.extend(["--min-size".to_owned(), self.min_size.to_string()]);
            }
            if self.min_lines > 0 {
                args.extend(["--min-lines".to_owned(), self.min_lines.to_string()]);
            }
        }
        if self.min_grade != Grade::None {
            args.extend(["--min-grade".to_owned(), self.min_grade.as_str().to_owned()]);
        }
        if self.top > 0 {
            args.extend(["--top".to_owned(), self.top.to_string()]);
        }
        if self.no_index {
            args.push("--no-index".to_owned());
        }
        args.push("--json".to_owned());
        args.extend(self.roots.iter().map(|p| p.display().to_string()));
        Ok(Invocation::json(Bin::Relate, schema, args))
    }
}
