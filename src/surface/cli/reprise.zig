//! Asking the same question twice — the CLI's side of the resident answer keep.
//!
//! Most of this package makes an expensive question cheaper. Some questions
//! have no cheaper form: `relate echoes --shape distinct` asks which of twenty
//! thousand files has no kin, which is a statement about every pair, and there
//! is no index over "every pair". The sweep is the answer, so the only thing
//! left to elide is a sweep already done over the same bytes.
//!
//! This module is that elision, and it is deliberately shaped so it cannot be
//! anything else:
//!
//! * **The daemon never computes.** It holds rendered bytes against a corpus
//!   change epoch and compares numbers. A keep that cannot recompute cannot
//!   recompute differently.
//! * **The key is the whole question.** Not a hash — the literal tool, verb,
//!   argv, working directory, every environment knob that can move an answer,
//!   and the identity of the binary that produced it. Two runs share an entry
//!   only if there is nothing left that could make them differ.
//! * **The copy is a tee, not a buffer.** Output goes to the terminal as it
//!   always did (`corpus.carbonOn`); the copy rides alongside. An early exit or
//!   a closed pipe costs a keep entry, never a byte of the answer.
//! * **A recall says so.** Stdout is byte-identical to the cold run — that is
//!   the whole contract — but stderr closes with a `recalled` line instead of
//!   the verb's own summary, because that summary's counts and milliseconds
//!   describe work this run did not do.
//!
//! Every failure is silence. No daemon, a stale protocol, a watcher that cannot
//! vouch for an epoch, an oversized answer — the verb then behaves exactly as
//! it did before this module existed. It never STARTS a daemon either: that
//! lifecycle is `gist`'s, and the keep is a passenger on it.

const std = @import("std");
const assay = @import("../../assay/assay.zig");
const corpus = @import("../../corpus/tree/corpus.zig");
const keep = @import("../face/gist/daemon/client/keep.zig");
const paths = @import("../../corpus/scope/paths.zig");
const serve = @import("../face/gist/daemon/serve/serve.zig");

/// Environment knobs that can change WHAT a verb prints. Anything that only
/// changes how fast it prints it (`GIST_NO_PARALLEL`) or what lands on stderr
/// (`GIST_TRACE`) is deliberately absent: those must not split the keep.
const scoping_env = [_][]const u8{
    "GIST_DIR",
    "GIST_ROOTS",
    "GIST_SKIP",
    "GIST_MAX_OUTPUT_BYTES",
    "GIST_UNCAP",
    "GIST_SESSION_SOCK",
    "NO_COLOR",
};

/// What `seal` needs to finish the errand, parked here because a verb exits the
/// process from inside its own run (`outcome.Outcome.exit`) rather than
/// returning an exit code up to `drive`. One CLI runs one verb, so one slot.
var pending: ?struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    socket: []const u8,
    key: []const u8,
    epoch: u64,
    body: *std.ArrayList(u8),
} = null;

/// Try to answer from the keep before the verb runs.
///
/// On a hit this writes the held answer and EXITS with its code — the verb
/// never runs. On a miss it arms the stdout copy so `seal` can offer the
/// answer back. Returns either way to a caller that just proceeds normally.
pub fn attempt(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    tool: []const u8,
    verb: []const u8,
    argv: []const []const u8,
) void {
    if (env.get("GIST_NO_KEEP") != null) return;
    // The terminal is out of the keep's envelope for the same reason it is out
    // of the daemon's: an interactive run may color, page, or width-clip, and
    // the held bytes were rendered for a pipe.
    if (std.Io.File.stdout().isTty(io) catch false) return;

    const socket = serve.socketPath(gpa, env) catch return;
    const key = mint(gpa, io, tool, verb, argv, env) orelse {
        gpa.free(socket);
        return;
    };
    switch (keep.ask(gpa, io, socket, key)) {
        .unusable => {
            // Deliberately does NOT spawn a daemon. `gist` owns that lifecycle
            // (`client/spawn.zig`), and its self-spawn execs `<this binary>
            // serve` — which from `relate` or `irregex` is an unknown verb, not
            // a daemon. The keep is a passenger on the resident session, never
            // a reason to start one.
            assay.trace(.warm, "{s} {s}: no keep (no resident daemon on {s})\n", .{ tool, verb, socket });
            gpa.free(key);
            gpa.free(socket);
        },
        .hit => |h| {
            if (h.bytes.len > 0) _ = corpus.writeStdoutCapped(h.bytes);
            corpus.finishOutput();
            recite(gpa, verb, argv, h.epoch, h.bytes.len);
            std.process.exit(h.code);
        },
        .miss => |epoch| {
            assay.trace(.warm, "{s} {s}: keep miss at epoch {d} — computing\n", .{ tool, verb, epoch });
            const body = gpa.create(std.ArrayList(u8)) catch {
                gpa.free(key);
                gpa.free(socket);
                return;
            };
            body.* = .empty;
            pending = .{ .gpa = gpa, .io = io, .socket = socket, .key = key, .epoch = epoch, .body = body };
            corpus.carbonOn(body, gpa);
        },
    }
}

/// Say that the answer was recalled, in the grammar every verb's own summary
/// uses. A cold run closes with one stderr line naming the tier that answered
/// and what it cost; a kept run must not simply fall silent, or the reader
/// cannot tell a recalled answer from a recomputed one. Replaying the ORIGINAL
/// summary was the alternative, and it is the wrong one: that line's file
/// counts and milliseconds describe work this run did not do.
fn recite(gpa: std.mem.Allocator, verb: []const u8, argv: []const []const u8, epoch: u64, bytes: usize) void {
    const json = for (argv) |a| {
        if (std.mem.eql(u8, a, "--json")) break true;
    } else false;
    assay.summary(gpa, json, "{s}: recalled · epoch {d} · {d} B\n", .{ verb, epoch, bytes }, .{
        .{ "verb", "s", verb },
        .{ "tier", "s", "keep" },
        .{ "epoch", "d", epoch },
        .{ "bytes", "d", bytes },
    });
}

/// Offer what the verb just printed back to the keep.
///
/// Idempotent, because a face can finish in three shapes and only one of them
/// is a call: an rg-shaped `Outcome`, a grade verdict that exits on an empty
/// answer, or simply returning from `run`. Each routes here once; a second
/// call finds nothing pending and does nothing. A FATAL exit deliberately
/// never routes here at all — an error is not an answer.
pub fn seal(code: u8) void {
    const p = pending orelse return;
    pending = null;
    const bytes = corpus.carbonOff() orelse {
        assay.trace(.warm, "keep: copy torn — nothing offered\n", .{});
        return;
    };
    assay.trace(.warm, "keep: offering {d} B at epoch {d} (exit {d})\n", .{ bytes.len, p.epoch, code });
    keep.offer(p.gpa, p.io, p.socket, p.key, p.epoch, code, bytes);
}

/// Seal and terminate — the door for a face that exits on a result from inside
/// its own run rather than returning a code up to `drive`.
pub fn depart(code: u8) noreturn {
    seal(code);
    std.process.exit(code);
}

/// Mint the key: everything that could make two runs of the same verb print
/// different bytes, laid out as `\x00`-separated fields.
///
/// The binary's own identity (size + modification time) is a field, so a
/// rebuilt verb cannot be served an answer its previous build rendered — the
/// hazard a version string would miss, because a version string does not change
/// between two builds of the same working tree.
fn mint(
    gpa: std.mem.Allocator,
    io: std.Io,
    tool: []const u8,
    verb: []const u8,
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
) ?[]u8 {
    var k: std.ArrayList(u8) = .empty;
    errdefer k.deinit(gpa);
    // Canonical, not as-spelled: relative roots resolve against it, so two
    // spellings of one directory are one question and must share one entry.
    const cwd = paths.realpathAlloc(gpa, ".") orelse return null;
    defer gpa.free(cwd);

    field(&k, gpa, tool) catch return null;
    field(&k, gpa, verb) catch return null;
    field(&k, gpa, cwd) catch return null;
    for (argv) |a| field(&k, gpa, a) catch return null;
    k.appendSlice(gpa, "\x00env\x00") catch return null;
    for (scoping_env) |name| {
        field(&k, gpa, name) catch return null;
        field(&k, gpa, env.get(name) orelse "") catch return null;
    }
    const build = selfStamp(gpa, io);
    k.print(gpa, "\x00build\x00{d}\x00{d}", .{ build.size, build.mtime }) catch return null;
    return k.toOwnedSlice(gpa) catch null;
}

fn field(k: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try k.appendSlice(gpa, s);
    try k.append(gpa, 0);
}

/// The running binary's size + mtime — a build fingerprint that costs one stat.
/// Zeroes when it cannot be read, which merely widens the key's sharing to the
/// pre-fingerprint behavior rather than failing the errand.
const Stamp = struct { size: u64, mtime: i128 };

fn selfStamp(gpa: std.mem.Allocator, io: std.Io) Stamp {
    const unread: Stamp = .{ .size = 0, .mtime = 0 };
    const path = std.process.executablePathAlloc(io, gpa) catch return unread;
    defer gpa.free(path);
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return unread;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}
