//! The closed vocabularies an analytic row field can hold (`[row_enums]`) and
//! the calibration that gives their scores meaning (`[irregex.channels]`,
//! `[irregex.grades]`).
//!
//! These are the one place a raw number becomes a judgment. A distance of 0.78
//! is not "the eighth-nearest file", it is *background* — so every kinship row
//! carries a [`Grade`], and a caller filtering on `>= Grade::Strong` gets an
//! empty answer rather than five strangers. The bands and their polarity live
//! here, next to the enums, because reading a score without them is the
//! specific mistake the calibration exists to prevent.

use super::schema::ENUMS;

/// An enum-tagged row field as it came off the wire.
///
/// `[row_enums]` is **append-only**: a newer engine may report an ordinal past
/// the end of the table this build was generated from. That is not corruption
/// and it is not guessable, so the ordinal is kept verbatim and
/// [`name`](Self::name) reports `None` — the caller decides whether an unknown
/// variant is fatal for *its* question.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Variant {
    /// The `[row_enums]` id (1-based) the ordinal is drawn from.
    pub enum_id: u32,
    /// The wire ordinal, preserved even when this build cannot name it.
    pub ordinal: i64,
}

impl Variant {
    /// The declared spelling, or `None` for an ordinal this build's table does
    /// not cover (a newer engine, or a genuinely out-of-range value).
    #[must_use]
    pub fn name(self) -> Option<&'static str> {
        let variants = ENUMS
            .get(usize::try_from(self.enum_id).ok()?.checked_sub(1)?)?
            .1;
        usize::try_from(self.ordinal)
            .ok()
            .and_then(|i| variants.get(i))
            .copied()
    }

    /// The `[row_enums]` key this variant belongs to (`"grade"`, `"channel"`…).
    #[must_use]
    pub fn enum_name(self) -> Option<&'static str> {
        Some(
            ENUMS
                .get(usize::try_from(self.enum_id).ok()?.checked_sub(1)?)?
                .0,
        )
    }
}

impl std::fmt::Display for Variant {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.name() {
            Some(n) => f.write_str(n),
            // Spelled so a log line says which vocabulary drifted, not just that one did.
            None => write!(f, "{}?{}", self.enum_name().unwrap_or("enum"), self.ordinal),
        }
    }
}

/// Build the `ordinal ↔ variant ↔ name` trio every row enum needs, checked
/// against the generated table so a reordered `[row_enums]` fails the crate's
/// parity test instead of silently re-labeling rows.
macro_rules! row_enum {
    ($(#[$outer:meta])* $name:ident = $id:expr, $($variant:ident => $spelling:literal),+ $(,)?) => {
        $(#[$outer])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum $name { $($variant),+ }

        impl $name {
            /// The `[row_enums]` id this vocabulary is declared under.
            pub const ENUM_ID: u32 = $id;
            /// Every variant, weakest/first-declared first — the declaration order
            /// *is* the wire ordinal order.
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];

            /// The contract spelling.
            #[must_use]
            pub const fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $spelling),+ }
            }

            /// The wire ordinal. Unsigned because a *declared* variant always
            /// has one; only a value read off the wire can be out of range,
            /// and that is what [`Variant::ordinal`] keeps signed for.
            #[must_use]
            pub fn ordinal(self) -> u32 {
                Self::ALL.iter().position(|v| *v == self)
                    .and_then(|i| u32::try_from(i).ok())
                    .unwrap_or(0)
            }

            /// Resolve a wire ordinal, or `None` when this build cannot name it.
            #[must_use]
            pub fn from_ordinal(ordinal: i64) -> Option<Self> {
                usize::try_from(ordinal).ok().and_then(|i| Self::ALL.get(i)).copied()
            }

            /// Resolve a [`Variant`] carrying this vocabulary's id.
            #[must_use]
            pub fn from_variant(v: Variant) -> Option<Self> {
                (v.enum_id == Self::ENUM_ID).then(|| Self::from_ordinal(v.ordinal)).flatten()
            }

            /// Parse the contract spelling (what `--min-grade` / `--as` accept).
            #[must_use]
            pub fn parse(name: &str) -> Option<Self> {
                Self::ALL.iter().copied().find(|v| v.as_str() == name)
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str(self.as_str())
            }
        }
    };
}

row_enum! {
    /// How much a kinship score is worth. Ordered weakest-first, so `>=` is the
    /// threshold test `--min-grade` performs — and [`None`](Self::None) is
    /// *background*, not a weak hit.
    Grade = 1,
    None => "none",
    Weak => "weak",
    Moderate => "moderate",
    Strong => "strong",
    Identical => "identical",
}

row_enum! {
    /// Which kinship signal produced a score. The vocabulary is the same on
    /// every verb; only the metric behind it changes.
    Channel = 2,
    Copies => "copies",
    Twins => "twins",
    Shapes => "shapes",
    Any => "any",
}

row_enum! {
    /// The comparison unit a kinship row was computed over.
    Unit = 3,
    File => "file",
    Function => "function",
    Match => "match",
}

/// Whether higher or lower is *closer* for a channel — the reason one band
/// table cannot serve both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Polarity {
    /// Lower is closer (`copies`, `shapes`, `any`); admitted by `--max-distance`.
    Distance,
    /// Higher is stronger (`twins`); admitted by `--min-echo`. Byte-identical
    /// files score zero here, which is the weakest twin evidence there is.
    Gap,
}

/// `[irregex.grades].distance` — the inclusive upper bound of each band,
/// strongest-first. Anything above `weak` is [`Grade::None`].
pub const DISTANCE_BANDS: &[(Grade, f64)] = &[
    (Grade::Identical, 0.05),
    (Grade::Strong, 0.25),
    (Grade::Moderate, 0.50),
    (Grade::Weak, 0.75),
];

/// `[irregex.grades].gap` — the inclusive lower bound of each band,
/// strongest-first. A gap is never [`Grade::Identical`].
pub const GAP_BANDS: &[(Grade, f64)] = &[
    (Grade::Strong, 0.45),
    (Grade::Moderate, 0.30),
    (Grade::Weak, 0.15),
];

impl Channel {
    /// The underlying metric name (`--lens`), which is how the CLI and the
    /// older `--lens` aliases still spell these channels.
    #[must_use]
    pub const fn metric(self) -> &'static str {
        match self {
            Self::Copies => "bytes",
            Self::Twins => "echo",
            Self::Shapes => "structure",
            Self::Any => "fused",
        }
    }

    /// Which direction means "closer" on this channel.
    #[must_use]
    pub const fn polarity(self) -> Polarity {
        match self {
            Self::Twins => Polarity::Gap,
            _ => Polarity::Distance,
        }
    }

    /// The flag that admits a candidate on this channel.
    #[must_use]
    pub const fn admits(self) -> &'static str {
        match self.polarity() {
            Polarity::Gap => "--min-echo",
            Polarity::Distance => "--max-distance",
        }
    }

    /// Accept either the channel name or its metric alias (`--as copies` and
    /// `--lens bytes` name the same thing).
    #[must_use]
    pub fn parse_any(name: &str) -> Option<Self> {
        Self::parse(name).or_else(|| Self::ALL.iter().copied().find(|c| c.metric() == name))
    }
}

impl Grade {
    /// Band a raw score for `channel`, applying that channel's polarity.
    ///
    /// This is the calibration in one call: the same 0.20 is
    /// [`Strong`](Self::Strong) as a distance and [`Moderate`](Self::Moderate)
    /// as a gap, and reading it without the channel is the mistake.
    #[must_use]
    pub fn band(score: f64, channel: Channel) -> Self {
        match channel.polarity() {
            // Both tables read strongest-first, so the first band that contains
            // the score is the tightest one that does.
            Polarity::Distance => DISTANCE_BANDS
                .iter()
                .find(|(_, hi)| score <= *hi)
                .map_or(Self::None, |(g, _)| *g),
            Polarity::Gap => GAP_BANDS
                .iter()
                .find(|(_, lo)| score >= *lo)
                .map_or(Self::None, |(g, _)| *g),
        }
    }

    /// Whether this band clears a `--min-grade` floor.
    #[must_use]
    pub fn admits(self, floor: Self) -> bool {
        self >= floor
    }
}
