//! The weak-result verdict: what an answer amounted to, said out loud.
//!
//! `relate similar fresh.zig` returning 0.7813 looks like a result and reads
//! like a result, but every row is past the 0.50 line where kinship stops
//! meaning "related" and starts meaning "both are Zig" — and nothing in the
//! output said so. The calibration lived only in prose
//! (`.cursor/rules/irregex.mdc`), which the binary's caller does not have.
//!
//! The vocabulary and its bands are kernel facts and live there
//! (`kernel/kinship/metric/channel.zig`); this module re-exports them so every
//! face keeps one import, and owns the two surface halves:
//!
//!   • **Sift** — the emit ledger every ranking verb runs: cap at `--top`, gate
//!     rows whose file vanished since the index anchor, remember the strongest
//!     score BEFORE withholding, withhold anything under `--min-grade`. Four
//!     verbs each hand-rolled this loop and drifted; now they share it.
//!   • **Verdict** — what the answer amounted to, rendered on stderr in gist's
//!     hint grammar, plus the rg-shaped exit code that goes with it.

const std = @import("std");
const corpus_mod = @import("../../corpus/tree/corpus.zig");
const channel_mod = @import("../../kernel/kinship/metric/channel.zig");
const guide = @import("guide.zig");

/// The one channel vocabulary + its calibrated bands (kernel-owned).
pub const Channel = channel_mod.Channel;
pub const Grade = channel_mod.Grade;
pub const of = channel_mod.of;

// ── the emit ledger ──

/// The shared shape of "emit at most `top` rows, honestly".
///
/// Every ranking verb needs the same five decisions per row, in the same
/// order, and getting the order wrong is a silent lie: record the best score
/// before a floor withholds it, or the verdict claims there was nothing there.
/// `Sift` is that order, once.
pub const Sift = struct {
    verdict: Verdict,
    top: usize,

    pub fn init(chan: Channel, top: usize, floor: ?Grade, scored: usize, scoped: bool) Sift {
        return .{
            .verdict = .{ .channel = chan, .scored = scored, .floor = floor, .scoped = scoped },
            .top = top,
        };
    }

    /// Has the answer filled its `--top` budget? The loop's break condition.
    pub fn full(self: *const Sift) bool {
        return self.verdict.shown >= self.top;
    }

    /// Judge one row, strongest-first order assumed. Returns its grade when the
    /// row may be emitted, `null` when a `--min-grade` floor withheld it —
    /// either way the row is now accounted for in the verdict.
    pub fn judge(self: *Sift, score: f64) ?Grade {
        const g = of(self.verdict.channel, score);
        if (self.verdict.best == null) self.verdict.best = score;
        if (self.verdict.floor) |floor| if (!g.meets(floor)) {
            self.verdict.withheld += 1;
            return null;
        };
        self.verdict.shown += 1;
        return g;
    }

    /// Account for a row this channel's bands cannot judge — the complement
    /// shapes, where the score means the OPPOSITE of confidence. `distinct`
    /// ranks by how far the nearest miss is, so grading it on kinship bands
    /// would call the strongest answer "weak" precisely when it was strongest.
    /// The row still counts toward `--top` and the exit code; it just carries no
    /// grade, and `best` stays null so the verdict coaches nothing.
    pub fn count(self: *Sift) void {
        self.verdict.shown += 1;
    }

    /// Judge a row whose score is NOT in the answer's sort order — a family
    /// graded by its loosest edge, say, where the tightest family may land
    /// anywhere in a size-ranked list. `best` becomes the strongest seen.
    pub fn judgeUnordered(self: *Sift, score: f64) ?Grade {
        const stronger = switch (self.verdict.channel.polarity()) {
            .distance => self.verdict.best == null or score < self.verdict.best.?,
            .stronger => self.verdict.best == null or score > self.verdict.best.?,
        };
        if (stronger) self.verdict.best = score;
        const g = of(self.verdict.channel, score);
        if (self.verdict.floor) |floor| if (!g.meets(floor)) {
            self.verdict.withheld += 1;
            return null;
        };
        self.verdict.shown += 1;
        return g;
    }

    /// Render the verdict to stderr and exit with its rg-shaped code — the last
    /// two things a ranking verb does, in the order that keeps the run's trace
    /// line before its judgment.
    pub fn settle(self: *const Sift, tool: []const u8, subject: []const u8) void {
        report(tool, subject, self.verdict);
        if (self.verdict.code() != 0) std.process.exit(self.verdict.code());
    }
};

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
    /// An exact `--matching` filter narrowed the population first, so a thin
    /// answer means "few matches", not "little kinship" — and widening the
    /// pattern is the fix, not switching channels.
    narrowed: bool = false,
    /// What this answer's rows ARE, when they are not kinship rows: the
    /// complement shapes find `"distinct units"`, and "no kin" would be the
    /// opposite of what happened. Null takes the channel's own noun.
    noun: ?[]const u8 = null,

    /// What the answer amounted to. The distinction is load-bearing: an answer
    /// trimmed by an explicit floor is a GOOD answer that owes the caller an
    /// accounting, not a failure that should be talked out of its channel.
    pub const Outcome = enum { empty, weak, trimmed };

    /// What this answer was looking for, in one word.
    pub fn found(self: Verdict) []const u8 {
        if (self.noun) |n| return n;
        return switch (self.channel) {
            .recall => "source",
            .context => "picks",
            else => "kin",
        };
    }

    /// The grade of the best score, or `.none` when nothing scored.
    pub fn grade(self: Verdict) Grade {
        return if (self.best) |b| of(self.channel, b) else .none;
    }

    pub fn outcome(self: Verdict) Outcome {
        if (self.shown == 0) return .empty;
        // Being "weak" requires a measured score to be weak about. A shape whose
        // rows this channel cannot grade (the complement) has rows, and they
        // are the answer — not a disappointing version of one.
        if (self.best == null) return .trimmed;
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
    const found = v.found();

    // ── the outcome, one line ────────────────────────────────────────────
    const max_display = 64;
    const shown_subject = subject[0..@min(subject.len, max_display)];
    try out.print(a, "{s}: ", .{tool});
    switch (outcome) {
        .empty => try out.print(a, "no {s}", .{found}),
        .weak => try out.print(a, "no strong {s}", .{found}),
        .trimmed => try out.print(a, "{d} {s}", .{ v.shown, found }),
    }
    try out.print(a, " for '{s}{s}'", .{ shown_subject, if (subject.len > max_display) "…" else "" });
    if (v.best) |b| try out.print(a, " · {s} {d:.4} ({s})", .{
        if (v.channel.polarity() == .distance) "nearest" else "best",
        b,
        g.label(),
    });
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

    // An exact filter ran first, so the population — not the channel — is what
    // a thin answer is about. Coaching channels here sends the caller the wrong
    // way: there may be nothing to compare yet.
    if (v.narrowed) {
        try guide.line(a, out, &left, tool, .act, "a wider --matching pattern — kinship was scored only inside the exact match");
        try guide.line(a, out, &left, tool, .note, "drop --matching to ask the same question of the whole scope");
        return;
    }

    // A shape whose rows are not kinship rows has no channel to be coached
    // toward: reaching here means the COMPLEMENT came back empty, and another
    // `--as` would not change that every unit in scope has a relative.
    if (v.noun != null) {
        try guide.line(a, out, &left, tool, .note, "every unit in scope has a relative at this threshold");
        try guide.line(a, out, &left, tool, .act, "a tighter threshold — raise the bar for what counts as kin, then ask again");
        return;
    }

    switch (v.channel) {
        .recall => {
            if (v.best) |b| if (b < 0.30)
                try guide.linef(a, out, &left, tool, .note, "the best gain was {d:.4} — this corpus has no cheaper way to say it than from scratch", .{b});
            try guide.line(a, out, &left, tool, .act, "fewer, more specific words — a short query is cheap to explain anywhere, which reads as weak everywhere");
            try guide.line(a, out, &left, tool, .act, "gist '<a literal you expect>' — an exact miss is a faster answer than a weak gain");
        },
        // A thin pack is a statement about the corpus, not about a channel:
        // no `--as` changes how much of the question these files answer.
        .context => {
            if (v.best) |b|
                try guide.linef(a, out, &left, tool, .note, "the picks explain {d:.0}% of the priced query — nothing here is really about it", .{b * 100.0});
            try guide.line(a, out, &left, tool, .act, "the words the answer would use, not the words the question uses — an aspect no file holds is priced out, not searched harder");
            try guide.line(a, out, &left, tool, .act, "relate similar '<text>' — rank single files by coding gain when no SET covers the question");
        },
        else => {
            switch (v.channel.polarity()) {
                .distance => if (v.best) |b| {
                    if (b > 0.50)
                        try guide.line(a, out, &left, tool, .note, "every row is past 0.50 — shares style, not substance");
                },
                .stronger => if (v.best) |b| {
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
                .recall, .context => unreachable,
            }
        },
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
        \\relate: 1 kin for 'this corpus' · best 0.6261 (strong) · 263 scored · 76 withheld
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

test "a weak text probe is coached on the query, not on kinship channels" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    // The measured nonsense query: nothing in the corpus explains it cheaply,
    // and no `--as` flag can change that.
    try render(a, &out, "relate", "purple monkey dishwasher", .{
        .channel = .recall,
        .best = 0.2316,
        .shown = 3,
        .scored = 16,
    });
    try t.expectEqualStrings(
        \\relate: no strong source for 'purple monkey dishwasher' · best 0.2316 (none) · 16 scored
        \\relate: note: the best gain was 0.2316 — this corpus has no cheaper way to say it than from scratch
        \\relate: try fewer, more specific words — a short query is cheap to explain anywhere, which reads as weak everywhere
        \\relate: try gist '<a literal you expect>' — an exact miss is a faster answer than a weak gain
        \\
    , out.items);
}

test "a narrowed answer is coached on the pattern, not on the channel" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    // Three files matched the pattern and none are kin: telling the caller to
    // try another channel would be answering a question they did not ask.
    try render(a, &out, "relate", "handler.zig", .{
        .channel = .shapes,
        .best = 0.81,
        .shown = 2,
        .scored = 3,
        .narrowed = true,
    });
    try t.expectEqualStrings(
        \\relate: no strong kin for 'handler.zig' · nearest 0.8100 (none) · 3 scored
        \\relate: try a wider --matching pattern — kinship was scored only inside the exact match
        \\relate: note: drop --matching to ask the same question of the whole scope
        \\
    , out.items);
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
        \\relate: no kin for 'corpus.zig' · best 0.0900 (none) · 412 scored · 7 withheld
        \\relate: note: 7 row(s) scored below --min-grade moderate; the best was none
        \\relate: note: the widest gap was 0.0900, under the 0.15 floor where a shared skeleton stops being sample noise
        \\relate: try --as copies — no shared skeleton here; verbatim duplication may still exist
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

test "the complement's rows are the answer, not a weak version of one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `--shape distinct` ranks by how FAR the nearest miss is, so grading it on
    // kinship bands would have called its best answer "weak". Unscored rows are
    // simply an answer: nothing to explain, so nothing is printed.
    var counted = Sift.init(.shapes, 10, null, 14, false);
    counted.verdict.noun = "distinct units";
    counted.count();
    counted.count();
    try t.expectEqual(Verdict.Outcome.trimmed, counted.verdict.outcome());
    try t.expect(!counted.verdict.notable());
    try t.expectEqual(@as(u8, 0), counted.verdict.code());

    // Empty is the interesting case, and it must not read "no kin": every unit
    // in scope having a relative is the strong finding here.
    var out: std.ArrayList(u8) = .empty;
    try render(a, &out, "relate", "this corpus", .{
        .channel = .shapes,
        .shown = 0,
        .scored = 14,
        .noun = "distinct units",
    });
    try t.expect(std.mem.startsWith(u8, out.items, "relate: no distinct units for 'this corpus'"));
}

test "Sift records the best score before a floor withholds it" {
    var sift = Sift.init(.copies, 3, .strong, 100, false);
    // A weak first row is still the best the answer had — a verdict that
    // reported `null` here would claim the corpus was empty.
    try t.expectEqual(@as(?Grade, null), sift.judge(0.62));
    try t.expectEqual(@as(?f64, 0.62), sift.verdict.best);
    try t.expectEqual(@as(usize, 1), sift.verdict.withheld);
    try t.expectEqual(@as(usize, 0), sift.verdict.shown);
    try t.expect(!sift.full());
}

test "Sift caps at --top and judgeUnordered tracks the strongest either polarity" {
    var sift = Sift.init(.copies, 2, null, 10, false);
    try t.expectEqual(Grade.identical, sift.judge(0.01).?);
    try t.expectEqual(Grade.strong, sift.judge(0.20).?);
    try t.expect(sift.full()); // two shown, budget spent
    try t.expectEqual(@as(?f64, 0.01), sift.verdict.best);

    // Families arrive size-ranked, not score-ranked: the tightest one may be
    // third. `best` must still end up the tightest, not the first seen.
    var fams = Sift.init(.copies, 10, null, 10, false);
    _ = fams.judgeUnordered(0.30);
    _ = fams.judgeUnordered(0.10);
    _ = fams.judgeUnordered(0.50);
    try t.expectEqual(@as(?f64, 0.10), fams.verdict.best);
    // On a `stronger` channel the strongest is the largest.
    var gaps = Sift.init(.twins, 10, null, 10, false);
    _ = gaps.judgeUnordered(0.20);
    _ = gaps.judgeUnordered(0.55);
    _ = gaps.judgeUnordered(0.31);
    try t.expectEqual(@as(?f64, 0.55), gaps.verdict.best);
}
