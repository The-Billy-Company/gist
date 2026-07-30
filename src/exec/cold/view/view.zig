//! The native-lens dispatch — gist's own ways of looking at a match, as opposed
//! to ripgrep's.
//!
//! A **lens** answers the same compiled query over the same PATH scope, but
//! presents it in a shape `rg` has no flag for. Each one branches BEFORE the
//! certified rg-parity walk/emit path and finishes the run itself, which is
//! what keeps the parity certificate intact: a lens cannot thread its own
//! awareness through the machinery rgsuite measures, because it never reaches
//! it. Two ship today — `--rank` (definition-first RRF) and
//! `--in-comments`/`--in-code` (comment/code-scoped matches).
//!
//! `dispatch` is the single seam. This used to be two `if` blocks with their
//! orchestration written inline in `serial.run`; a third lens would have been a
//! third block, each re-deriving the file set, the filename-visibility rule,
//! and the exit shape by hand. Written once here, adding a lens is adding a
//! case — not re-deriving the run (ADR-376).

const std = @import("std");
const args = @import("../argv/args.zig");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const hints = @import("../emit/hints.zig");
const ingest = @import("../read/ingest.zig");
const legible = @import("../../../corpus/read/legible.zig");
const intake = @import("../quarry/intake.zig");
const render = @import("../emit/render.zig");
const writ_mod = @import("../writ/writ.zig");
const Outcome = @import("../../../surface/cli/outcome.zig").Outcome;
const commentscope = @import("commentscope.zig");
const ranked = @import("ranked.zig");

const Opts = args.Opts;
const die = @import("../../../surface/cli/outcome.zig").die;
const oom = @import("../../../surface/cli/outcome.zig").oom;
const stripBom = legible.stripBom;

/// Whether a lens claimed the run. A lens that owns an rg-shaped exit code never
/// returns at all (`Outcome.exit`); `.done` is for the one path that finishes
/// with a plain return — a `--rank` view, whose no-match is an empty view rather
/// than rg's exit-1 "nothing found".
pub const Claim = enum { unclaimed, done };

/// Everything a lens needs to answer, and nothing it doesn't. `w` in particular
/// arrives with every prune guard already resolved, so a lens never re-derives
/// a gate (see `../writ/writ.zig`).
pub const Run = struct {
    gpa: std.mem.Allocator,
    /// Run arena. A lens result lives until process exit, so nothing here frees.
    a: std.mem.Allocator,
    io: std.Io,
    parsed: args.Parsed,
    o: Opts,
    w: *const writ_mod.Writ,
    icfg: *const ingest.Config,
    /// Latched `--pre` failure — folded into a lens exit like any path error.
    pre_error: *std.atomic.Value(bool),

    /// The lens file set: every file the WALK admits, read whole. A lens presents
    /// matches in its own shape rather than rg's line stream, so the whole-file
    /// gate — proven against "would this file emit an rg line?" — does not apply;
    /// only the line needle, a property of the pattern itself, carries over.
    ///
    /// The index prefilter DOES apply, and passing it is what lets a lens present
    /// the walk's file set at the walk's cost instead of reading the whole corpus.
    /// `filters`/`sieve` are necessary conditions on the pattern's own literals,
    /// so a file they prune cannot hold a match in any shape a lens could
    /// present — and the `Writ` already emptied both for every mode that observes
    /// non-matching bytes (`-v`, `--include-zero`, a transforming `-z`/`--pre`
    /// read that the index cannot speak about), so a lens inherits those guards
    /// instead of re-deriving them. Elision only skips a READ; the walk stays the
    /// sole authority on WHAT to search (ADR-373 law 1), which is what keeps a
    /// lens's file set equal to the same query's `-l` set.
    fn collect(r: Run) intake.Collected {
        return intake.collectFiles(r.a, r.gpa, r.io, r.parsed, r.w.filters, r.w.sieve, r.w.line_needle, r.icfg);
    }

    /// rg's filename-visibility rule: `auto` shows paths as soon as more than
    /// one file could appear in the output.
    fn showNames(r: Run, c: intake.Collected) bool {
        return switch (r.o.filename) {
            .always => true,
            .never => false,
            .auto => c.recursive or c.files.len > 1 or r.parsed.roots.len > 1,
        };
    }

    /// A latched `--pre` failure is an error exit, exactly like an unopenable
    /// explicit path (rg parity).
    fn faulted(r: Run) bool {
        return r.pre_error.load(.seq_cst);
    }

    /// The shared no-match stderr coaching channel, keyed to this query's shape.
    fn noMatches(r: Run, searched: ?usize) void {
        hints.noMatches(hints.shape(r.parsed.patterns, r.o, r.parsed.roots, r.parsed.roots.len > 0), searched);
    }
};

/// Run the lens the flags selected, if any. `.unclaimed` — the overwhelmingly
/// common answer — means the query belongs to the ordinary rg path.
pub fn dispatch(r: Run) !Claim {
    if (r.o.rank) return rank(r);
    if (r.o.in_comments or r.o.in_code) commentScoped(r);
    return .unclaimed;
}

/// `--rank[=N]`: definition-first ranked view over the SAME compiled pattern,
/// PATH scope, and walk the unranked search would use — the RRF kernel only
/// reorders that set. It is the one lens built on the linear engine's AST
/// analysis (definition-shape ranking), so it declines LOUD under `-P` rather
/// than silently ignoring the backend the user asked for.
///
/// The ranked set is `gist -l`'s set by CONSTRUCTION, because it is produced by
/// the same walk. It used to be enumerated from the persisted index's path table
/// instead, which made the index a semantic structure rather than an
/// acceleration one (ADR-373 law 1) and cost the view every file the index's
/// corpus policy excludes but a search walk enters: `corpus/tree/haystack.zig`'s
/// generic skip-dir baseline prunes `vendor/` (right for the kinship corpus,
/// wrong for a search), so a ranked `graphify` silently dropped 470 real hits,
/// and no walk-widening flag reached the view at all — `-uu`, whose walk admits
/// 15× the files, ranked the default corpus and called it an answer.
fn rank(r: Run) !Claim {
    if (r.w.is_pcre) die("--rank uses gist's linear engine and is unavailable with a PCRE2 pattern (-P/--pcre2, or an --engine auto escalation) — drop one\n", .{});
    const c = r.collect();
    const live = r.a.alloc(ranked.LiveFile, c.files.len) catch oom();
    for (c.files, live) |file, *dst| dst.* = .{ .path = file.path, .bytes = file.bytes };
    const n = try ranked.run(r.gpa, r.io, &r.w.re.linear, live, r.o.rank_k, r.w.binary_detect);
    if (c.path_error or r.faulted()) std.process.exit(2);
    // `walked`, not the read set: index elision leaves a proven non-matcher
    // unread, and a hint that reported only the files it opened would tell an
    // agent its scope was narrower than the walk it actually ran.
    if (n == 0) r.noMatches(c.walked);
    return .done;
}

/// `--in-comments` / `--in-code`: the comment/code-scoped view. The exact engine
/// still decides IF a line matches; the span lexer only filters WHICH matches
/// survive by comment membership, so a scoped result is always a subset of the
/// same query's plain result. Owns its rg-shaped exit, so it never returns.
fn commentScoped(r: Run) noreturn {
    if (r.o.in_comments and r.o.in_code) die("--in-comments and --in-code are mutually exclusive\n", .{});
    const c = r.collect();
    const scoped = r.a.alloc(commentscope.File, c.files.len) catch oom();
    for (c.files, scoped) |file, *dst| dst.* = .{ .path = file.path, .bytes = ingest.visibleBody(r.o.encoding, file.bytes) };
    var out: std.ArrayList(u8) = .empty;
    const kept = commentscope.run(r.a, &r.w.re, r.o, scoped, r.showNames(c), &out);
    if (!r.o.quiet) corpus_mod.emitStdout(out.items);
    render.pcreFaultExit(&r.w.re);
    (Outcome{ .matched = kept > 0, .faulted = c.path_error or r.faulted() }).exit();
}
