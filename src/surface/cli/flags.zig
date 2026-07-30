//! Shared CLI vocabulary — argv value parsing + corpus-root resolution.
//!
//! The face-agnostic plumbing every product face (`gist` · `relate` ·
//! `irregex`) and their verb-support modules speak: pull the value after a
//! flag, parse a bounded number, resolve positional args to corpus roots, test
//! root membership. It lives once here so no face re-spells `parseInt … catch
//! die` and no face forks the root-boundary rule.

const std = @import("std");
const corpus_mod = @import("irregex").corpus;
const scope = @import("irregex").commands.scope.filter;

const die = @import("irregex").inner.cli.outcome.die;

/// The value slot after a flag, or `die(msg)` when argv ends first.
pub fn need(argv: []const []const u8, i: *usize, comptime msg: []const u8) []const u8 {
    i.* += 1;
    if (i.* >= argv.len) die(msg, .{});
    return argv[i.*];
}

/// Parse the value of an integer flag (`--top 5`), dying with a uniform
/// bad-number message keyed on `flag` — the shared int-flag parse every
/// face's verb consumes instead of re-spelling `parseInt … catch die`.
pub fn count(argv: []const []const u8, i: *usize, comptime flag: []const u8) usize {
    return std.fmt.parseInt(usize, need(argv, i, flag ++ " needs a number\n"), 10) catch
        die(flag ++ ": bad number: {s}\n", .{argv[i.*]});
}

/// Parse `--min-size`: an integer ≥ 2, since a family needs at least two
/// members. Read wherever `--shape families` is.
pub fn minSize(argv: []const []const u8, i: *usize) usize {
    const n = count(argv, i, "--min-size");
    if (n < 2) die("--min-size: a family needs at least 2 members\n", .{});
    return n;
}

/// Parse a finite distance/echo threshold. NaN and infinities must not enter
/// ordering predicates: they make every comparison false and silently empty
/// otherwise-valid result sets.
pub fn unitFloat(raw: []const u8, flag: []const u8) f64 {
    const value = std.fmt.parseFloat(f64, raw) catch die("{s}: bad number: {s}\n", .{ flag, raw });
    if (!std.math.isFinite(value) or value < 0.0 or value > 1.0)
        die("{s}: expected a finite number in [0,1], got {s}\n", .{ flag, raw });
    return value;
}

/// The whole argv is empty or repetitions of `flag` (returns whether it was
/// present); anything else dies with `usage_msg` — the lifecycle verbs' parse.
pub fn onlyFlag(argv: []const []const u8, comptime flag: []const u8, comptime usage_msg: []const u8) bool {
    for (argv) |arg| if (!std.mem.eql(u8, arg, flag)) die(usage_msg, .{});
    return argv.len > 0;
}

/// Positional args → corpus roots (already normalized); empty → the corpus
/// for this working directory (`corpus.resolveRoots`). `deinit` releases only
/// what resolution allocated — a borrow of the positionals frees nothing.
pub const Roots = struct {
    items: []const []const u8,
    owned: bool = false,

    pub fn deinit(self: Roots, gpa: std.mem.Allocator) void {
        if (self.owned) corpus_mod.freeRoots(gpa, self.items);
    }
};

pub fn rootsOf(gpa: std.mem.Allocator, positional: []const []const u8) !Roots {
    if (positional.len > 0) return .{ .items = positional };
    return .{ .items = try corpus_mod.resolveRoots(gpa), .owned = true };
}

/// Strip one exact leading `./` — the canonical shape for comparing a user
/// arg against a walk-produced path (never trims `..`).
pub fn stripDotSlash(p: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, p, "./")) p[2..] else p;
}

/// Is `path` at, or under, any of `roots`? Empty roots = the whole corpus.
/// The shared `scope/glob.zig` boundary rule: exact file hit, or a directory
/// prefix ending at `/` (so `services` never admits `services_old`).
pub fn underAnyRoot(path: []const u8, roots: []const []const u8) bool {
    if (roots.len == 0) return true;
    for (roots) |r| if (scope.underRoot(path, std.mem.trimEnd(u8, scope.normalizeRoot(r), "/"))) return true;
    return false;
}
