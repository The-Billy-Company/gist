//! relate — the query option surface, declared once for every verb.
//!
//! The kinship verbs differ in what they ask, not in how they are configured:
//! all of them take a scope, a unit, a channel, a threshold, a row budget, a
//! grade floor, and (now) an optional exact filter. Four verbs each parsed a
//! private subset of that, and the subsets drifted — `--lens echo` worked on one
//! verb and failed on another, `--min-lines` existed only for fragments,
//! `--max-distance` and `--min-echo` were sometimes both accepted and sometimes
//! not. One flag loop, one `Opts`, one place to add a knob.
//!
//! `cfg` gates which flags a verb admits, so a verb still refuses a flag it has
//! no meaning for — the loop is shared, the surface is not.

const std = @import("std");
const candidates = @import("../../../kernel/compose/candidates.zig");
const echoes = @import("../../../kernel/kinship/cluster/echoes.zig");
const scope = @import("../../../corpus/scope/filter.zig");
const flags = @import("../../cli/flags.zig");
const grade = @import("../../cli/grade.zig");
const kinship = @import("kinship.zig");
const units = @import("units.zig");

const die = @import("../../cli/outcome.zig").die;
const oom = @import("../../cli/outcome.zig").oom;

pub const Channel = grade.Channel;
pub const Unit = units.Unit;
pub const Shape = echoes.Shape;

/// Every knob the relate query verbs share. A verb seeds its own defaults, then
/// `parse` fills in what the caller asked for.
pub const Opts = struct {
    top: usize,
    json: bool = false,
    brief: bool = false,
    no_index: bool = false,
    channel: Channel = .copies,
    unit: Unit = .file,
    shape: Shape = .pairs,
    /// Did the caller NAME the channel / unit, or are these still defaults? The
    /// neighbor verb needs the difference: a text probe with no `--as` is a
    /// retrieval question, while `--as shapes` over the same text means "find
    /// what is shaped like this snippet". A default must not out-vote the shape
    /// of the argument, and an explicit flag must not be silently overridden.
    channel_set: bool = false,
    unit_set: bool = false,
    /// Distance-channel admission (`copies`/`shapes`/`any`): closer than this.
    max_dist: f64 = 0.25,
    /// Gap-channel admission (`twins`): a bytes−structure gap at least this wide.
    min_echo: f64 = 0.15,
    /// Smallest family surfaced.
    min_size: usize = 2,
    /// Noise floors. Null = the unit's own default, so `--unit function` gets a
    /// fragment-scale floor without the caller restating it.
    min_lines: ?usize = null,
    min_mass: ?usize = null,
    include_generated: bool = false,
    /// Withhold rows weaker than this calibrated grade (`--min-grade`).
    min_grade: ?grade.Grade = null,
    /// The one positional: `similar`'s probe, `pack`/`quote`'s text.
    arg: ?[]const u8 = null,

    // ── the exact filter (`--matching`) ──
    matching: std.ArrayList([]const u8) = .empty,
    match: candidates.Match = .any,
    fixed: bool = false,
    ignore_case: bool = false,
    context: usize = 3,

    pub fn deinit(self: *Opts, gpa: std.mem.Allocator) void {
        self.matching.deinit(gpa);
    }

    /// Move to `unit`, adopting the channel that unit is actually informative
    /// on. Fragment-scale byte kinship is nearly all vocabulary: measured over
    /// this corpus, a function's nearest BYTE neighbor sits at ~0.81 — grade
    /// `none`, indistinguishable from background — while its nearest SILHOUETTE
    /// neighbor sits at 0.52 and is the sibling implementation a reader wanted.
    /// A 40-line body simply cannot fill an LZ78 dictionary the way a file can,
    /// so normalizing the identifiers away is what leaves any signal at all.
    /// The retired `concepts` verb defaulted to the same channel for the same
    /// reason. An explicit `--as` always wins.
    pub fn adopt(self: *Opts, unit: Unit) void {
        self.unit = unit;
        if (!self.channel_set and unit != .file) self.channel = .shapes;
    }

    /// The channel-relative admission threshold, so a verb never has to
    /// remember which polarity its flag carried.
    pub fn floor(self: Opts) f64 {
        return if (self.channel.polarity() == .stronger) self.min_echo else self.max_dist;
    }

    /// The exact filter, or null when the caller named no pattern.
    pub fn narrow(self: *const Opts) ?units.Narrow {
        if (self.matching.items.len == 0) return null;
        return .{
            .patterns = self.matching.items,
            .match = self.match,
            .fixed = self.fixed,
            .ignore_case = self.ignore_case,
            .context = self.context,
        };
    }

    /// What the unit view must resolve for this query.
    pub fn ask(self: *const Opts, roots: []const []const u8) units.Ask {
        return .{
            .unit = self.unit,
            .wants = kinship.wantsOf(self.channel),
            .roots = roots,
            .narrow = self.narrow(),
            .no_index = self.no_index,
        };
    }

    /// What the repetition kernel should look for, with the unit's own noise
    /// floors applied unless the caller overrode them.
    pub fn params(self: *const Opts) echoes.Params {
        return .{
            .channel = self.channel,
            .shape = self.shape,
            .max_dist = self.max_dist,
            .min_echo = self.min_echo,
            .min_lines = self.min_lines orelse self.unit.lineFloor(),
            .min_size = self.min_size,
            // Null flows through: the mass floor follows the CHANNEL's record
            // type, which the kernel that measures it already knows.
            .min_mass = self.min_mass,
            .include_generated = self.include_generated,
            // An exact filter usually leaves dozens of units, where the seed
            // buckets can skip a pair the caller explicitly asked about and the
            // full comparison is cheap. Unnarrowed, it is 20k files and the
            // buckets are the only way through.
            .exhaustive = self.matching.items.len > 0 and self.matching.items.len <= max_exhaustive,
        };
    }
};

/// Above this many narrowed units, fall back to seed-bucket nomination: the
/// quadratic pass is only free while the set is small.
const max_exhaustive = 64;

/// Which flags a verb admits. A flag left false is a fatal unknown-flag on that
/// verb, so `pack --min-echo` still fails loudly instead of being ignored.
pub const Cfg = struct {
    max_dist: bool = false,
    min_echo: bool = false,
    min_size: bool = false,
    min_lines: bool = false,
    min_mass: bool = false,
    include_generated: bool = false,
    no_index: bool = false,
    channel: bool = false,
    unit: bool = false,
    shape: bool = false,
    min_grade: bool = false,
    brief: bool = false,
    matching: bool = false,
    positional: bool = false,
    /// The verb's name, for the unknown-flag death. Null = tolerate unknown
    /// `-flags` as roots (the historical shape for the lax verbs).
    strict: ?[]const u8 = null,
};

/// One flag loop for every relate query verb. With `cfg.positional` the first
/// bare arg fills `opts.arg`; every other bare arg is a normalized root.
pub fn parse(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    opts: *Opts,
    roots: *std.ArrayList([]const u8),
    comptime cfg: Cfg,
) !void {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (cfg.max_dist and std.mem.eql(u8, arg, "--max-distance")) {
            opts.max_dist = flags.unitFloat(flags.need(argv, &i, "--max-distance needs a number in [0,1]\n"), "--max-distance");
        } else if (cfg.min_echo and std.mem.eql(u8, arg, "--min-echo")) {
            opts.min_echo = flags.unitFloat(flags.need(argv, &i, "--min-echo needs a number in [0,1]\n"), "--min-echo");
        } else if (cfg.min_size and std.mem.eql(u8, arg, "--min-size")) {
            opts.min_size = flags.minSize(argv, &i);
        } else if (cfg.min_lines and std.mem.eql(u8, arg, "--min-lines")) {
            opts.min_lines = flags.count(argv, &i, "--min-lines");
        } else if (cfg.min_mass and std.mem.eql(u8, arg, "--min-mass")) {
            opts.min_mass = flags.count(argv, &i, "--min-mass");
        } else if (cfg.include_generated and std.mem.eql(u8, arg, "--include-generated")) {
            opts.include_generated = true;
        } else if (cfg.channel and (std.mem.eql(u8, arg, "--as") or std.mem.eql(u8, arg, "--lens"))) {
            const named = flags.need(argv, &i, "--as needs " ++ Channel.flag_values ++ "\n");
            const parsed = Channel.parse(named) orelse
                die("--as: copies, twins, shapes, or any, not {s}\n", .{named});
            // `recall` is chosen by the probe's shape (text, not a path), never
            // by a flag: naming it here would ask a file to be a query.
            if (!parsed.pairwise())
                die("--as: {s} is not a pairwise channel — pass TEXT instead of a path to score recall\n", .{named});
            opts.channel = parsed;
            opts.channel_set = true;
        } else if (cfg.unit and std.mem.eql(u8, arg, "--unit")) {
            opts.unit = Unit.parse(flags.need(argv, &i, "--unit needs file|function|match\n")) orelse
                die("--unit: file, function, or match, not {s}\n", .{argv[i]});
            opts.unit_set = true;
        } else if (cfg.shape and std.mem.eql(u8, arg, "--shape")) {
            opts.shape = std.meta.stringToEnum(Shape, flags.need(argv, &i, "--shape needs pairs|families|distinct\n")) orelse
                die("--shape: pairs, families, or distinct, not {s}\n", .{argv[i]});
        } else if (cfg.min_grade and std.mem.eql(u8, arg, "--min-grade")) {
            opts.min_grade = grade.Grade.parse(flags.need(argv, &i, "--min-grade needs identical|strong|moderate|weak|none\n")) orelse
                die("--min-grade: identical, strong, moderate, weak, or none, not {s}\n", .{argv[i]});
        } else if (cfg.matching and (std.mem.eql(u8, arg, "--matching") or std.mem.eql(u8, arg, "-e"))) {
            try opts.matching.append(gpa, flags.need(argv, &i, "--matching needs a pattern\n"));
        } else if (cfg.matching and std.mem.eql(u8, arg, "--match")) {
            opts.match = std.meta.stringToEnum(candidates.Match, flags.need(argv, &i, "--match needs any|all\n")) orelse
                die("--match: any or all, not {s}\n", .{argv[i]});
        } else if (cfg.matching and (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings"))) {
            opts.fixed = true;
        } else if (cfg.matching and (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case"))) {
            opts.ignore_case = true;
        } else if (cfg.matching and std.mem.eql(u8, arg, "-C")) {
            opts.context = flags.count(argv, &i, "-C");
        } else if (cfg.brief and std.mem.eql(u8, arg, "--brief")) {
            opts.brief = true;
        } else if (std.mem.eql(u8, arg, "--top")) {
            opts.top = flags.count(argv, &i, "--top");
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (cfg.no_index and std.mem.eql(u8, arg, "--no-index")) {
            opts.no_index = true;
        } else if (cfg.strict != null and std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            die("relate " ++ (comptime cfg.strict.?) ++ ": unknown flag {s}\n", .{arg});
        } else if (cfg.positional and opts.arg == null) {
            opts.arg = arg;
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }
    // Flag order must not change the answer, so the unit's implied channel is
    // settled once the whole argv is known rather than when `--unit` was seen.
    opts.adopt(opts.unit);
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

/// Parse `argv` with the repetition verb's config — the widest surface.
fn parseRepetition(gpa: std.mem.Allocator, argv: []const []const u8, roots: *std.ArrayList([]const u8)) !Opts {
    var o = Opts{ .top = 50, .channel = .twins };
    try parse(gpa, argv, &o, roots, .{
        .max_dist = true,
        .min_echo = true,
        .min_size = true,
        .min_lines = true,
        .min_mass = true,
        .include_generated = true,
        .no_index = true,
        .channel = true,
        .unit = true,
        .shape = true,
        .min_grade = true,
        .brief = true,
        .matching = true,
        .strict = "echoes",
    });
    return o;
}

test "the unit carries its own line floor and defers the mass floor to the channel" {
    const gpa = t.allocator;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);

    var files = try parseRepetition(gpa, &.{}, &roots);
    defer files.deinit(gpa);
    try t.expectEqual(@as(usize, 0), files.params().min_lines); // atlas has no line counts

    var fns = try parseRepetition(gpa, &.{ "--unit", "function" }, &roots);
    defer fns.deinit(gpa);
    try t.expectEqual(@as(usize, 5), fns.params().min_lines);
    // …and the channel that unit is informative on, since fragment byte
    // distances pile up in the background band (see `adopt`).
    try t.expectEqual(Channel.shapes, fns.params().channel);

    // Mass is the one floor the UNIT does not own — thinness belongs to the
    // record, so an unset `--min-mass` reaches the kernel as null and each
    // channel applies its own calibration there.
    try t.expectEqual(@as(?usize, null), files.params().min_mass);
    try t.expectEqual(@as(?usize, null), fns.params().min_mass);

    var override = try parseRepetition(gpa, &.{ "--unit", "function", "--min-lines", "20", "--min-mass", "3" }, &roots);
    defer override.deinit(gpa);
    try t.expectEqual(@as(usize, 20), override.params().min_lines);
    try t.expectEqual(@as(?usize, 3), override.params().min_mass);
}

test "the retired verbs' answers are each one flag combination" {
    const gpa = t.allocator;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);

    // `dups` ≡ copies × pairs.
    var dups = try parseRepetition(gpa, &.{ "--as", "copies" }, &roots);
    defer dups.deinit(gpa);
    try t.expectEqual(Channel.copies, dups.params().channel);
    try t.expectEqual(Shape.pairs, dups.params().shape);
    try t.expectEqual(@as(f64, 0.25), dups.params().floor());

    // `clusters` ≡ copies × families.
    var clusters = try parseRepetition(gpa, &.{ "--as", "copies", "--shape", "families" }, &roots);
    defer clusters.deinit(gpa);
    try t.expectEqual(Shape.families, clusters.params().shape);

    // `concepts` ≡ shapes × families × the function unit.
    var concepts = try parseRepetition(gpa, &.{ "--as", "shapes", "--shape", "families", "--unit", "function" }, &roots);
    defer concepts.deinit(gpa);
    try t.expectEqual(Channel.shapes, concepts.params().channel);
    try t.expectEqual(Unit.function, concepts.unit);

    // `echoes` itself is the default: the gap channel, as pairs.
    var default = try parseRepetition(gpa, &.{}, &roots);
    defer default.deinit(gpa);
    try t.expectEqual(Channel.twins, default.params().channel);
    try t.expectEqual(@as(f64, 0.15), default.params().floor()); // the gap floor, not the distance one
}

test "an exact filter switches nomination to exhaustive and marks the view narrowed" {
    const gpa = t.allocator;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    var o = try parseRepetition(gpa, &.{ "--matching", "async def run", "--match", "all", "-F", "-i", "services/ai" }, &roots);
    defer o.deinit(gpa);

    const n = o.narrow().?;
    try t.expectEqual(@as(usize, 1), n.patterns.len);
    try t.expectEqualStrings("async def run", n.patterns[0]);
    try t.expectEqual(candidates.Match.all, n.match);
    try t.expect(n.fixed and n.ignore_case);
    try t.expectEqualSlices(u8, "services/ai", roots.items[0]);
    // Inside a handful of matches the seed buckets may skip a pair the caller
    // explicitly asked about, and the full pass is cheap.
    try t.expect(o.params().exhaustive);

    var wide = try parseRepetition(gpa, &.{}, &roots);
    defer wide.deinit(gpa);
    try t.expectEqual(@as(?units.Narrow, null), wide.narrow());
    try t.expect(!wide.params().exhaustive);
}

test "-e is accepted as --matching, repeatably, in the order given" {
    const gpa = t.allocator;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    var o = try parseRepetition(gpa, &.{ "-e", "alpha", "--matching", "beta", "-e", "gamma" }, &roots);
    defer o.deinit(gpa);
    try t.expectEqual(@as(usize, 3), o.matching.items.len);
    try t.expectEqualStrings("alpha", o.matching.items[0]);
    try t.expectEqualStrings("beta", o.matching.items[1]);
    try t.expectEqualStrings("gamma", o.matching.items[2]);
}

test "both channel vocabularies parse, and the floor follows the polarity" {
    const gpa = t.allocator;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    // The metric spelling `--lens echo` and the channel spelling `--as twins`
    // are one code path, not two.
    var lens = try parseRepetition(gpa, &.{ "--lens", "echo", "--min-echo", "0.4" }, &roots);
    defer lens.deinit(gpa);
    try t.expectEqual(Channel.twins, lens.channel);
    try t.expectEqual(@as(f64, 0.4), lens.floor());

    var dist = try parseRepetition(gpa, &.{ "--as", "shapes", "--max-distance", "0.1" }, &roots);
    defer dist.deinit(gpa);
    try t.expectEqual(@as(f64, 0.1), dist.floor());
}

test "a named channel outlives the unit's default, whatever order they arrive in" {
    const gpa = t.allocator;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    // The unit implies a channel only while the caller named none — asking for
    // byte-verbatim clones of a FUNCTION is exactly the pasted-helper question,
    // and a default that overrode it would answer a different one.
    for ([_][2][]const u8{
        .{ "--unit", "function" },
        .{ "--as", "copies" },
    }, 0..) |_, order| {
        const argv: []const []const u8 = if (order == 0)
            &.{ "--unit", "function", "--as", "copies" }
        else
            &.{ "--as", "copies", "--unit", "function" };
        var o = try parseRepetition(gpa, argv, &roots);
        defer o.deinit(gpa);
        try t.expectEqual(Channel.copies, o.channel);
        try t.expectEqual(Unit.function, o.unit);
    }
}
