//! Kinship channels, their calibrated grades, and the weak-result verdict.
//!
//! A distance is not an answer. `relate similar fresh.zig` returning 0.7813
//! looks like a result and reads like a result, but every row is past the 0.50
//! line where kinship stops meaning "related" and starts meaning "both are
//! Zig" — and nothing in the output said so. The calibration lived only in
//! prose (`.cursor/rules/irregex.mdc`), which the binary's caller does not
//! have. This module moves it into the engine.
//!
//! Two things live here because they are one idea:
//!
//!   • **Channel** — which kinship question is being asked, named for what it
//!     finds rather than the metric it runs. `copies` (verbatim/drifted
//!     duplication), `twins` (same skeleton, renamed vocabulary), `shapes`
//!     (shared skeleton regardless of vocabulary), `any` (closest in either).
//!     One enum for every verb and every face: before this, `--lens` named two
//!     incompatible enums, so `similar --lens echo` and `concepts --lens fused`
//!     both failed for no principled reason.
//!
//!   • **Grade** — where a score falls on that channel's calibrated bands, so
//!     a caller can tell a real twin from statistical background. Cut points
//!     are the ones the tool already documented and defaulted to (0.05 / 0.25 /
//!     0.50 for distances; the 0.15 `--min-echo` floor for gaps), promoted from
//!     prose to a typed value that rides `--json` rows, drives `--min-grade`,
//!     and fires a stderr verdict when the whole answer is background.
//!
//! Polarity differs by channel and that is load-bearing: `copies`/`shapes`/
//! `any` score a DISTANCE (lower is closer), `twins` scores a GAP (higher is
//! stronger). One flag spelling for both would silently invert a threshold, so
//! the CLI keeps `--max-distance` and `--min-echo` distinct and this module
//! makes the polarity explicit rather than remembered.

const std = @import("std");
const corpus_mod = @import("../../corpus/tree/corpus.zig");
const guide = @import("guide.zig");

/// Which kinship question a verb is answering. Tags are the user-facing
/// vocabulary; `metric` names the underlying channel for diagnostics.
pub const Channel = enum {
    /// LZJD distance over raw bytes — copy-paste and its drift.
    copies,
    /// byte distance − structure distance — the same skeleton wearing
    /// different vocabulary (Type-2 clones), the abstraction candidate.
    twins,
    /// Normalized-structure silhouette distance — shared skeleton, whether or
    /// not the vocabulary also matches.
    shapes,
    /// min(copies, shapes) — close in EITHER channel counts.
    any,

    /// Whether a higher or lower score is the stronger relation.
    pub const Polarity = enum { distance, gap };

    pub fn polarity(self: Channel) Polarity {
        return if (self == .twins) .gap else .distance;
    }

    /// The underlying metric's name, for stderr diagnostics and prior-art
    /// cross-reference (the literature calls these LZJD / winnowed silhouette).
    pub fn metric(self: Channel) []const u8 {
        return switch (self) {
            .copies => "bytes",
            .twins => "echo",
            .shapes => "structure",
            .any => "fused",
        };
    }

    /// Combine a pair's two measured distances into this channel's score — the
    /// ONE definition of what each channel means in terms of the metrics.
    /// `copies` ignores `structure`, so a caller that never built silhouettes
    /// may pass anything for it.
    pub fn score(self: Channel, bytes: f64, structure: f64) f64 {
        return switch (self) {
            .copies => bytes,
            .shapes => structure,
            .twins => bytes - structure,
            .any => @min(bytes, structure),
        };
    }

    /// Accept the user-facing vocabulary and the metric names it replaced, so
    /// a caller who learned `--lens bytes` is not stranded. One enum either
    /// way — the aliases are spellings, not a second code path.
    pub fn parse(s: []const u8) ?Channel {
        const table = .{
            .{ "copies", Channel.copies }, .{ "bytes", Channel.copies },
            .{ "twins", Channel.twins },   .{ "echo", Channel.twins },
            .{ "shapes", Channel.shapes }, .{ "structure", Channel.shapes },
            .{ "any", Channel.any },       .{ "fused", Channel.any },
        };
        inline for (table) |row| if (std.mem.eql(u8, s, row[0])) return row[1];
        return null;
    }
};

/// Where a score falls on its channel's calibrated bands. Ordered strongest
/// first, so `@intFromEnum` ascending is confidence descending.
pub const Grade = enum {
    /// Distance channels only: the same bytes or the same skeleton.
    identical,
    /// A real relation — the `--max-distance 0.25` band `dups` ships with.
    strong,
    /// Related, worth a look, not a fork.
    moderate,
    /// Past the line where kinship means "same language, same house style".
    weak,
    /// Background. Reporting this as a result is reporting noise.
    none,

    pub fn label(self: Grade) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Grade {
        return std.meta.stringToEnum(Grade, s);
    }

    /// Is `self` at least as strong as `floor`? The `--min-grade` predicate.
    pub fn meets(self: Grade, floor: Grade) bool {
        return @intFromEnum(self) <= @intFromEnum(floor);
    }
};

/// Grade `score` on `channel`'s bands.
///
/// Distance cut points are the ones already documented and defaulted to:
/// 0.05 "near-exact copy", 0.25 "same thing, drifted" (the `dups`/`clusters`
/// admission default), 0.50 "shares style, not substance". Gap cut points
/// scale from the 0.15 `--min-echo` floor, below which a structure-close pair
/// is small-sample noise rather than a shared skeleton.
pub fn of(channel: Channel, score: f64) Grade {
    if (std.math.isNan(score)) return .none;
    return switch (channel.polarity()) {
        .distance => if (score <= 0.05)
            .identical
        else if (score <= 0.25)
            .strong
        else if (score <= 0.50)
            .moderate
        else if (score <= 0.75)
            .weak
        else
            .none,
        // A gap can never mean "identical": two files with identical bytes
        // have a zero gap, which is the weakest twin signal there is.
        .gap => if (score >= 0.45)
            .strong
        else if (score >= 0.30)
            .moderate
        else if (score >= 0.15)
            .weak
        else
            .none,
    };
}

// ── the verdict ──

/// What an answer amounted to, for the stderr guidance channel. A verb fills
/// this while emitting and hands it over once; nothing here costs a second
/// pass over the corpus.
pub const Verdict = struct {
    channel: Channel,
    /// The strongest score in the answer (`null` = nothing scored at all).
    best: ?f64 = null,
    /// Rows actually emitted to stdout.
    shown: usize = 0,
    /// Candidates the best score was drawn from — the population that makes
    /// "nearest" mean something.
    scored: usize = 0,
    /// Rows a `--min-grade` floor withheld.
    withheld: usize = 0,
    /// The floor in force, if any.
    floor: ?Grade = null,
    /// Explicit ROOT args were given (a widen hint applies).
    scoped: bool = false,

    /// What the answer amounted to. The distinction is load-bearing: an answer
    /// trimmed by an explicit floor is a GOOD answer that owes the caller an
    /// accounting, not a failure that should be talked out of its channel.
    pub const Outcome = enum { empty, weak, trimmed };

    /// The grade of the best score, or `.none` when nothing scored.
    pub fn grade(self: Verdict) Grade {
        return if (self.best) |b| of(self.channel, b) else .none;
    }

    pub fn outcome(self: Verdict) Outcome {
        if (self.shown == 0) return .empty;
        return if (self.grade().meets(.moderate)) .trimmed else .weak;
    }

    /// Does this answer deserve an explanation? A strong, unabridged result
    /// stays silent — the same posture as gist's no-match hints.
    pub fn notable(self: Verdict) bool {
        return self.outcome() != .trimmed or self.withheld > 0;
    }

    /// The rg-shaped process code this answer speaks: 0 with rows, 1 without.
    /// Withholding every candidate under a floor is still a clean no-match —
    /// the caller asked for kin at grade G and there are none.
    pub fn code(self: Verdict) u8 {
        return if (self.shown == 0) 1 else 0;
    }
};

/// Render the verdict + up to three ranked hints. Pure, so tests assert bytes.
pub fn render(a: std.mem.Allocator, out: *std.ArrayList(u8), tool: []const u8, subject: []const u8, v: Verdict) !void {
    const g = v.grade();
    const outcome = v.outcome();

    // ── the outcome, one line ────────────────────────────────────────────
    const max_display = 64;
    const shown_subject = subject[0..@min(subject.len, max_display)];
    try out.print(a, "{s}: ", .{tool});
    switch (outcome) {
        .empty => try out.print(a, "no kin", .{}),
        .weak => try out.print(a, "no strong kin", .{}),
        .trimmed => try out.print(a, "{d} kin", .{v.shown}),
    }
    try out.print(a, " for '{s}{s}'", .{ shown_subject, if (subject.len > max_display) "…" else "" });
    if (v.best) |b| try out.print(a, " · nearest {d:.4} ({s})", .{ b, g.label() });
    if (v.scored > 0) try out.print(a, " · {d} scored", .{v.scored});
    if (v.withheld > 0) try out.print(a, " · {d} withheld", .{v.withheld});
    try out.append(a, '\n');

    // ── the hints, ranked by how often each is the actual fix, capped at 3 ─
    var left: usize = 3;
    if (v.floor) |floor| {
        if (v.withheld > 0)
            try guide.linef(a, out, &left, tool, .note, "{d} row(s) scored below --min-grade {s}; the best was {s}", .{ v.withheld, floor.label(), g.label() });
    }
    // A trimmed answer found what it was asked for. Coaching it toward another
    // channel would talk the caller out of a real finding.
    if (outcome == .trimmed) return;

    switch (v.channel.polarity()) {
        .distance => if (v.best) |b| {
            if (b > 0.50)
                try guide.linef(a, out, &left, tool, .note, "every row is past 0.50 — shares style, not substance", .{});
        },
        .gap => if (v.best) |b| {
            if (b < 0.15)
                try guide.linef(a, out, &left, tool, .note, "the widest gap was {d:.4}, under the 0.15 floor where a shared skeleton stops being sample noise", .{b});
        },
    }
    // The channel that most often holds the answer this one missed.
    switch (v.channel) {
        .copies => {
            try guide.line(a, out, &left, tool, .act, "--as twins — byte kinship cannot see a shared skeleton that renamed its vocabulary");
            try guide.line(a, out, &left, tool, .act, "--as any — score the closest of either channel instead of bytes alone");
        },
        .shapes => try guide.line(a, out, &left, tool, .act, "--as twins — rank by how much MORE shape than vocabulary a pair shares"),
        .twins => try guide.line(a, out, &left, tool, .act, "--as copies — no shared skeleton here; verbatim duplication may still exist"),
        .any => try guide.line(a, out, &left, tool, .act, "--as twins — score how much MORE shape than vocabulary a pair shares"),
    }
    if (v.scoped)
        try guide.line(a, out, &left, tool, .act, "a wider scope — drop the ROOT args to score the whole corpus");
}

/// The verbs' one-call guidance hook: render to stderr, honoring `GIST_HINTS`.
/// Never fails — guidance is a courtesy, never a result.
pub fn report(tool: []const u8, subject: []const u8, v: Verdict) void {
    if (!v.notable() or !corpus_mod.hintsEnabled()) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    render(arena.allocator(), &out, tool, subject, v) catch return;
    std.debug.print("{s}", .{out.items});
}

/// The verbs' one-call exit hook, and the last thing a kinship verb does.
///
/// An answer with no rows is exit 1 — `no_match` in `contract/search_api.toml`,
/// the same code `gist` returns for a pattern that matches no line. The
/// kinship verbs used to exit 0 either way, which made `relate similar X &&
/// …` a lie: a shell (or an agent) reading `$?` could not tell a corpus with
/// no twins from one full of them. `Verdict` already knows the difference, so
/// the contract only needed wiring, not deciding.
///
/// Call it AFTER the run's trace line: how long the query took is a fact about
/// the run, not about whether it found anything.
pub fn settle(v: Verdict) void {
    if (v.code() != 0) std.process.exit(v.code());
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "one Lens: both vocabularies parse into the same channel" {
    try t.expectEqual(Channel.copies, Channel.parse("copies").?);
    try t.expectEqual(Channel.copies, Channel.parse("bytes").?);
    try t.expectEqual(Channel.twins, Channel.parse("twins").?);
    try t.expectEqual(Channel.twins, Channel.parse("echo").?);
    try t.expectEqual(Channel.shapes, Channel.parse("structure").?);
    try t.expectEqual(Channel.any, Channel.parse("fused").?);
    try t.expectEqual(@as(?Channel, null), Channel.parse("sideways"));
}

test "distance bands match the documented cut points" {
    try t.expectEqual(Grade.identical, of(.copies, 0.00));
    try t.expectEqual(Grade.identical, of(.copies, 0.05));
    try t.expectEqual(Grade.strong, of(.copies, 0.25)); // the dups default
    try t.expectEqual(Grade.moderate, of(.shapes, 0.50));
    try t.expectEqual(Grade.weak, of(.copies, 0.60)); // past "shares style, not substance"
    try t.expectEqual(Grade.weak, of(.copies, 0.75));
    // The measured `similar fresh.zig` nearest neighbour over 21091 files: far
    // enough out that calling it a neighbour at all is reporting background.
    try t.expectEqual(Grade.none, of(.copies, 0.7813));
}

test "gap bands invert, and a gap is never identical" {
    try t.expectEqual(Grade.strong, of(.twins, 0.6261)); // the schema.zig pair
    try t.expectEqual(Grade.moderate, of(.twins, 0.3655));
    try t.expectEqual(Grade.weak, of(.twins, 0.15)); // the --min-echo floor
    try t.expectEqual(Grade.none, of(.twins, 0.14));
    // Byte-identical files share every fingerprint, so their gap is zero —
    // the weakest twin evidence, not the strongest.
    try t.expectEqual(Grade.none, of(.twins, 0.0));
}

test "meets orders strongest-first for the --min-grade floor" {
    try t.expect(Grade.identical.meets(.strong));
    try t.expect(Grade.strong.meets(.strong));
    try t.expect(!Grade.moderate.meets(.strong));
    try t.expect(Grade.none.meets(.none));
}

test "a strong answer stays silent; a weak one explains itself" {
    try t.expect(!(Verdict{ .channel = .copies, .best = 0.12, .shown = 5 }).notable());
    try t.expect((Verdict{ .channel = .copies, .best = 0.7813, .shown = 5 }).notable());
    try t.expect((Verdict{ .channel = .copies, .shown = 0 }).notable());
    try t.expect((Verdict{ .channel = .twins, .best = 0.6261, .shown = 3, .withheld = 2 }).notable());
}

test "a floor that trims a real answer accounts for it without recanting" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    // The measured `echoes src --min-grade strong` run: the schema.zig pair is
    // a genuine find, and 76 weaker pairs were withheld on purpose.
    try render(a, &out, "relate", "this corpus", .{
        .channel = .twins,
        .best = 0.6261,
        .shown = 1,
        .scored = 263,
        .withheld = 76,
        .floor = .strong,
        .scoped = true,
    });
    try t.expectEqualStrings(
        \\relate: 1 kin for 'this corpus' · nearest 0.6261 (strong) · 263 scored · 76 withheld
        \\relate: note: 76 row(s) scored below --min-grade strong; the best was strong
        \\
    , out.items);
}

test "the fresh.zig verdict names the band and the channel that would help" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try render(a, &out, "relate", "fresh.zig", .{
        .channel = .copies,
        .best = 0.7813,
        .shown = 5,
        .scored = 21091,
    });
    try t.expectEqualStrings(
        \\relate: no strong kin for 'fresh.zig' · nearest 0.7813 (none) · 21091 scored
        \\relate: note: every row is past 0.50 — shares style, not substance
        \\relate: try --as twins — byte kinship cannot see a shared skeleton that renamed its vocabulary
        \\relate: try --as any — score the closest of either channel instead of bytes alone
        \\
    , out.items);
}

test "an answer with no rows speaks rg's no-match code, whatever emptied it" {
    // The ranking verbs used to exit 0 either way, so `relate similar X && …`
    // could not tell a corpus with no twins from one full of them.
    try t.expectEqual(@as(u8, 0), (Verdict{ .channel = .copies, .best = 0.12, .shown = 5 }).code());
    try t.expectEqual(@as(u8, 1), (Verdict{ .channel = .copies, .scored = 21091 }).code());
    // Withheld-to-empty is still a clean no-match: kin at that grade, none.
    try t.expectEqual(@as(u8, 1), (Verdict{
        .channel = .copies,
        .best = 0.7734,
        .scored = 752,
        .withheld = 752,
        .floor = .strong,
    }).code());
}

test "an empty answer under a floor reports what it withheld" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try render(a, &out, "relate", "corpus.zig", .{
        .channel = .twins,
        .best = 0.09,
        .shown = 0,
        .scored = 412,
        .withheld = 7,
        .floor = .moderate,
        .scoped = true,
    });
    try t.expectEqualStrings(
        \\relate: no kin for 'corpus.zig' · nearest 0.0900 (none) · 412 scored · 7 withheld
        \\relate: note: 7 row(s) scored below --min-grade moderate; the best was none
        \\relate: note: the widest gap was 0.0900, under the 0.15 floor where a shared skeleton stops being sample noise
        \\relate: try --as copies — no shared skeleton here; verbatim duplication may still exist
        \\
    , out.items);
}
