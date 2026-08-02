//! What this package promises to be called, and what a tool may call it.
//!
//! Mirrors this repository's `contract/surface.toml` — the published names and
//! the tool boundary. The substrate mirrors its own contracts in
//! [`irgx::contract`]; these four constants are gist's, and they live here for
//! the reason every mirror lives next to its contract: the parity test that
//! holds them true reads a TOML from this repository, so a checkout of the
//! engine alone should neither carry them nor be gated on them.
//!
//! They were mirrored in the substrate crate until the packages split, which
//! meant the engine's own test suite could not run without a gist checkout
//! beside it. The constants did not move because they were unused there — they
//! moved because a substrate that needs its consumer checked out is a
//! substrate its consumer cannot be released without.

/// The published distribution name (`[package].dist` in `contract/surface.toml`).
///
/// Not the import name: the crate and the Python module are both `gist`, while
/// the PyPI distribution is `gist-search`, the name that was available.
pub const PACKAGE_DIST: &str = "gist-search";

/// The published import name (`[package].import` in `contract/surface.toml`).
pub const PACKAGE_IMPORT: &str = "gist";

/// Mirrors `[tool_boundary.aliases]` — a tool-boundary parameter name → its
/// canonical request option.
///
/// An agent driving this package by name says `query`; a caller writing Rust
/// says `pattern`. The alias table is what makes those the same request, and
/// the seam that applies it lives in the Python face; this mirror exists so the
/// parity gate holds the whole boundary in one place.
pub const ALIASES: &[(&str, &str)] = &[
    ("query", "pattern"),
    ("glob", "globs"),
    ("context_lines", "context"),
];

/// Mirrors `[tool_boundary.routing_keys]` — recognized-but-ignored place/rank
/// selectors that stay outside GIST.
pub const ROUTING_KEYS: &[&str] = &["place", "at", "semantic"];
