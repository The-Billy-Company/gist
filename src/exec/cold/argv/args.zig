//! gist `rg` — the ripgrep-compatible CLI flag surface (parsing only).
//!
//! This file is the argv package's **interface**: the names the rest of the tree
//! may use, and nothing else. Thirty-odd modules — every engine, emitter, face
//! verb, and the FFI session — import exactly this path, so what they depend on
//! is this list rather than the grammar's internals, and the package can be
//! re-cut underneath them without a single call-site edit.
//!
//! Split from `run.zig` (the walk + match + emit shell) the same way the grep
//! verb's `args.zig` splits from its `emit.zig`: this package owns the argv →
//! `Opts` lowering and the type/glob `Filter`, and nothing about IO or matching.
//! It implements ripgrep's DEFAULT flag semantics — short-flag bundling, `--flag`
//! and `--flag=value`, `-A/-B` precedence over `-C`, the `-u/-uu` unrestrict
//! tiers, `-t/-T/-g/--glob/--iglob` scoping with `!`-exclude + leading-`/`
//! anchoring. gist now accepts or honors the entire rg flag surface — the
//! fail-loud bucket is empty. `flag_catalog` is the parser and `--schema`
//! compatibility source of truth.
//!
//! Six implementation modules, each owning one axis of "what was asked for":
//!
//!   * [`intent.zig`](intent.zig)       — the request: `Opts`, `Filter`, `Parsed`,
//!                       and the `Builder` that accumulates them while argv arrives
//!   * [`catalog.zig`](catalog.zig)     — `flag_catalog`: every flag declared once,
//!                       as the table both the parser and `gist --schema` read
//!   * [`grammar.zig`](grammar.zig)     — the walk: bundling, `=value`, and every
//!                       precedence rule that can only settle after argv ends
//!   * [`verdict.zig`](verdict.zig)     — what a flag's value may be, and the exit-2
//!                       it earns when it isn't that
//!   * [`answer.zig`](answer.zig)       — the `Mode` a run resolves to and its
//!                       last-wins precedence over the presentation flags
//!   * [`preference.zig`](preference.zig) — personal preferences (machine-local,
//!                       TTY-gated, catalog-validated)
//!
//! Nothing here re-implements; the aliases below are the package's whole public
//! vocabulary. `Act`, `Builder`, `setVal`, and the value decoders are absent on
//! purpose — they are how the package works, not what it offers.

const catalog = @import("catalog.zig");
const grammar = @import("grammar.zig");
const intent = @import("intent.zig");
const verdict = @import("verdict.zig");

// The request, and the enums its fields are spelled in.
pub const Filename = intent.Filename;
pub const ColorChoice = intent.ColorChoice;
pub const Hyperlink = intent.Hyperlink;
pub const Encoding = intent.Encoding;
pub const encodingFromLabel = intent.encodingFromLabel;
pub const Engine = intent.Engine;
pub const SortKey = intent.SortKey;
pub const Filter = intent.Filter;
pub const Opts = intent.Opts;
pub const Parsed = intent.Parsed;

/// Parse a full `rg [flags] <pattern> [PATH...]` argv into a `Parsed`. Fails loud
/// (exit 2) on a missing pattern, a bad numeric value, or an unsupported flag.
pub const parseArgv = grammar.parseArgv;

/// Fatal exit with ripgrep's error code (2), and the OOM exit for `… catch
/// oom()`. Defined in `cli/outcome.zig` beside the other ways a face ends.
const die = @import("../../../surface/cli/outcome.zig").die;
const oom = @import("../../../surface/cli/outcome.zig").oom;

/// Codepoint-aware uppercase detection — shared with `emit/hints.zig` so a
/// no-match hint reasons about smart-case exactly as the parser did.
pub const hasUpper = verdict.hasUpper;

// The declarative flag contract `face/gist/schema/` renders into `--schema`.
pub const Compatibility = catalog.Compatibility;
pub const FlagSpec = catalog.FlagSpec;
pub const flag_catalog = catalog.flag_catalog;
/// How far a flag's effect travels — rendered into `--schema` beside each row,
/// and the ceiling a persisted configuration layer is judged against.
pub const Reach = catalog.Reach;
pub const reachOf = catalog.reachOf;

test {
    // Zig analyzes a `pub const` alias lazily, so re-exporting the surface above
    // is NOT enough to pull the implementation into a test build — without this
    // block the package's parse tests silently stop running while still passing.
    // Same reason `root.zig` wires its tiers by hand.
    _ = catalog;
    _ = grammar;
    _ = intent;
    _ = verdict;
}
