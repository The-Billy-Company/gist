//! Shared CLI vocabulary — how a face ends.
//!
//! ripgrep's contract is three codes (`contract/search_api.toml [exit_codes]`):
//! `0` a match, `1` a clean miss, `2` an error — "never a silent empty result".
//! Every face owes the caller exactly that, and until this module each of the
//! fourteen exit sites re-derived it inline as a nested ternary. That is how the
//! two rules below came to sit two hundred lines apart in the same engine, joined
//! only by a comment.
//!
//! One module owns every way the process stops, so no face can invent a fourth:
//! `die` (the caller's input was unusable), `oom` (allocation failed), `fatal`
//! (an error escaped a face's `run`), and `Outcome.exit` (the search itself
//! concluded). The first three are all exit `2` and differ only in what they
//! say; keeping them adjacent is what stops one of them drifting onto a
//! different code, which is exactly the silent-wrong-exit failure the contract
//! forbids. `die`/`oom` used to live in the ripgrep flag parser
//! (`exec/cold/argv/`), which meant a module needed the argv grammar in scope
//! just to report an allocation failure.
//!
//! There are genuinely **two** precedences, and the difference is ripgrep's
//! rather than ours:
//!
//!   * Normally a fault outranks a match. A walk that failed to read part of the
//!     tree cannot honestly claim `0`, because the answer it owed might be in
//!     what it could not read.
//!   * Under `--quiet` a match outranks a fault. Quiet short-circuits on the
//!     first hit and stops looking, so a later unreadable path is a question it
//!     never got around to asking. `rg -q p found missing` exits `0`, and gist
//!     matches it byte for byte.
//!
//! Collapsing those into one rule would silently break `-q` parity, which is why
//! the choice is a named variant rather than a bool: a call site has to say which
//! contract it is under, and the only reason the second one exists is spelled out
//! in the name.

const std = @import("std");
const assay = @import("../../assay/assay.zig");
const corpus = @import("../../corpus/tree/corpus.zig");
const paths = @import("../../corpus/scope/paths.zig");
const reprise = @import("reprise.zig");

/// Fatal exit with ripgrep's error code (2) and a formatted reason — the way a
/// face rejects input it cannot honor (an unknown flag, a bad number, a glob
/// that will not compile). Routed through `assay.diag` so a `dark` sink stays
/// silent and a `buffer` sink captures the message for the client (ADR-373
/// law 6) — the same reason `fatal` below takes this path.
pub fn die(comptime msg: []const u8, args: anytype) noreturn {
    // A fatal exit never routes through `reprise.seal` (an error is not an
    // answer), so it settles the stdout buffering policy itself: results already
    // printed before the fault are still owed to the reader.
    corpus.flushStdout();
    assay.diag(msg, args);
    std.process.exit(2);
}

/// The one OOM exit — sugar for the ubiquitous `… catch oom()`, which is this
/// CLI's contract for allocation failure (fail loud, exit 2). It *is*
/// `paths.allocFailure`: the corpus layer and the CLI reported OOM with two
/// separately-written functions that already had to emit one shared message
/// (`paths.oom_notice`) to stay in step, so this is now the same function under
/// the name call sites read best.
pub const oom = paths.allocFailure;

/// A verb needs a persisted artifact and there isn't a usable one: say which
/// state it is in, where it should live, and the command that produces it.
///
/// Fail-closed by contract. The artifacts that *can* degrade (the kinship atlas,
/// the fragment atlas) answer live instead and never reach here; the ones that
/// cannot — the codex shelf, whose whole claim is an exact count — must refuse
/// rather than serve a lesser answer under the same name. Three faces read that
/// one shelf, and a per-face copy of this sentence is how two of them end up
/// naming a command the third renamed.
///
/// Takes the loader's error rather than a bool so a third state (a foreign
/// tree, a version behind) becomes one more arm here instead of a second
/// argument at every call site.
pub fn needArtifact(e: anyerror, what: []const u8, path: []const u8, rebuild: []const u8) noreturn {
    const gone = e == error.FileNotFound;
    die("{s} {s} at {s} — run {s} to {s} it\n", .{
        if (gone) "no" else "corrupt",
        what,
        path,
        rebuild,
        if (gone) "build" else "rebuild",
    });
}

/// The last resort: an error escaped a face's `run`. Render it on the fault
/// channel and exit `2`.
///
/// This exists because Zig's default handler for `pub fn main() !void` is
/// actively wrong for a CLI under the rg contract: it prints a stack trace and
/// exits **1** — the code that means "searched fine, found nothing". A face
/// that could not open its index would report a clean miss, which is precisely
/// the silent-empty-result failure `contract/search_api.toml` forbids. So no
/// face returns an error union from `main`; each catches into here instead.
///
/// Routed through `assay.diag` rather than `std.debug.print` so it obeys the
/// installed sink — the FFI's `dark` sink stays silent (a library must never
/// write to the host's stderr) and a `buffer` sink captures it for a test.
pub fn fatal(face: []const u8, e: anyerror) noreturn {
    die("{s}: {t}\n", .{ face, e });
}

/// What a face is about to exit with: whether it matched, whether anything
/// faulted, and which of ripgrep's two precedences applies.
pub const Outcome = struct {
    matched: bool,
    faulted: bool = false,
    precedence: Precedence = .fault_first,

    /// Which of a match and a fault wins when a run has both.
    pub const Precedence = enum {
        /// The default: a fault outranks a match, because an incomplete walk
        /// cannot prove the match set is complete.
        fault_first,
        /// `--quiet` stopped at the first hit and never reached the fault.
        /// Pinned to ripgrep: `rg -q p found missing` → 0.
        quiet_short_circuit,
    };

    /// The rg-contract exit code. The two arms are deliberately written out in
    /// full rather than folded together — they are the two rules, and reading
    /// them side by side is the point.
    pub fn code(o: Outcome) u8 {
        return switch (o.precedence) {
            .fault_first => if (o.faulted) 2 else if (o.matched) 0 else 1,
            .quiet_short_circuit => if (o.matched) 0 else if (o.faulted) 2 else 1,
        };
    }

    /// Exit the process on this outcome — the one place a face terminates on a
    /// search result, which is why it is also where an answer becomes reusable.
    /// A `die`/`fatal` exit deliberately does NOT pass here: an error is not an
    /// answer, and nothing about it should be held.
    pub fn exit(o: Outcome) noreturn {
        reprise.depart(o.code());
    }
};

test "default precedence: a fault outranks a match" {
    const O = Outcome;
    try std.testing.expectEqual(@as(u8, 0), (O{ .matched = true }).code());
    try std.testing.expectEqual(@as(u8, 1), (O{ .matched = false }).code());
    try std.testing.expectEqual(@as(u8, 2), (O{ .matched = false, .faulted = true }).code());
    // The load-bearing row: matched AND faulted still exits 2.
    try std.testing.expectEqual(@as(u8, 2), (O{ .matched = true, .faulted = true }).code());
}

test "quiet short-circuit: a match outranks a fault (rg -q p found missing → 0)" {
    const O = Outcome;
    const q: Outcome.Precedence = .quiet_short_circuit;
    try std.testing.expectEqual(@as(u8, 0), (O{ .matched = true, .faulted = true, .precedence = q }).code());
    try std.testing.expectEqual(@as(u8, 2), (O{ .matched = false, .faulted = true, .precedence = q }).code());
    try std.testing.expectEqual(@as(u8, 1), (O{ .matched = false, .precedence = q }).code());
}

test "the two precedences differ on exactly one input" {
    var differed: usize = 0;
    for ([_]bool{ false, true }) |m| for ([_]bool{ false, true }) |f| {
        const a = (Outcome{ .matched = m, .faulted = f }).code();
        const b = (Outcome{ .matched = m, .faulted = f, .precedence = .quiet_short_circuit }).code();
        if (a != b) differed += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), differed);
}
