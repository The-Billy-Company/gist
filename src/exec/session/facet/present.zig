//! The rendered faces — the answers that come back as finished BYTES rather
//! than a set, a count, or a record stream.
//!
//! What unites them is that none of them formats anything: each gathers warm
//! docs and then hands them to a renderer the COLD path owns — `render.zig`
//! (which drives the cold engine's own `Emitter` + `binary.handleBinary`) for
//! the default `path:text` / `-n` presentation, and `ranked.renderLive` for
//! `--rank`. Byte-parity with a piped cold run is therefore by construction, not
//! by a re-derived formatter that could drift.
//!
//! `queryLinesShm` is `queryLines` with the transport chosen by answer size:
//! above the caller's floor the rendered bytes ride an anonymous-shm fd instead
//! of traversing the socket, and any shm failure falls open to the identical
//! `chunk` bytes.

const std = @import("std");
const render = @import("render.zig");
// The gist-native `--rank` kernel: its `renderLive` extracts features over
// in-memory `LiveFile`s, fuses via RRF, and renders the top-K — the SAME
// emission cold's `runLive` produces, returned to buffer instead of stdout.
// A one-way edge (ranked never imports session), so no cycle.
const ranked = @import("../../cold/view/ranked.zig");
const answer = @import("../answer/answer.zig");
const gather = @import("../answer/gather.zig");
const reconcile = @import("../reconcile/reconcile.zig");
const resident = @import("../warm/resident.zig");
const ResidentSession = resident.ResidentSession;
const Lines = answer.Lines;
const QueryError = answer.QueryError;
const Request = resident.Request;

/// Answer a bare `gist <pattern>` (`.lines`) request: the default
/// `path:text` / `-n` `path:line:text` presentation, pre-rendered into one
/// buffer through the cold engine's OWN Emitter (`render.zig`) so the bytes
/// cannot drift from a piped cold run. Same reconcile + freshness barrier +
/// trigram prefilter + fail-closed existence check as `fold.query`; docs render
/// in the warm canonical `pathLess` file order (see `answer.docLess`); binary
/// docs get cold's exact NUL-cut policy. `arena` owns the returned bytes.
/// A pattern outside the linear engine declines with `freshness_unprovable`;
/// a mid-render OOM remains `OutOfMemory`. The daemon sends only the former
/// through the cold-fallback route.
pub fn queryLines(self: *ResidentSession, arena: std.mem.Allocator, req: Request) QueryError!answer.Answer(Lines) {
    if (req.matchNothing()) return .{ .got = .{ .out = "", .matched = false } }; // `-m0` (see `fold.query`)
    var tripped: std.atomic.Value(bool) = .init(false);
    var held = switch (try self.beginRead(&tripped)) {
        .got => |h| h,
        .declined => |d| return .{ .declined = d },
    };
    defer held.lease.release();
    switch (try reconcile.guardExtras(self, &held, req)) {
        .got => {},
        .declined => |d| return .{ .declined = d },
    }
    const ceil = held.ceil;

    var cq = switch (try gather.compileFor(self, req, .files)) {
        .got => |compiled| compiled,
        .declined => |d| return .{ .declined = d },
    }; // the whole-doc gate; presentation is render's job
    defer cq.deinit(self.gpa);
    var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
    defer sc.deinit();

    // Admit every doc (binary included — the renderer applies cold's cut).
    // The whole-doc gate over full bytes is a sound superset: a binary doc
    // whose only match sits past its NUL buffer renders to nothing, exactly
    // as cold's emit loop produces nothing for it. Under `-v` every text
    // doc is admitted whole (a doc with zero matching lines is entirely
    // selected), so the emit gather walks every doc — the invert emit's own
    // cost, which Lever B parallelizes.
    const docs = try gather.matchingDocs(self, arena, &cq, req.filter, &sc, .lines, req.invert, .{}, ceil);
    var out: std.ArrayList(u8) = .empty;
    // Both faces shard the emit over cores through the SAME primitive
    // (`render.renderLinesParallel` → `parallel.shardBounds`): `-v` selects
    // nearly every line of every doc, and a common positive token prunes to
    // a candidate set large enough that the serial render is the
    // 1-core-vs-16-core loss to cold's fused scan. Below the shared byte
    // floor it falls through to the serial core; either way the concatenated
    // bytes are identical to the serial render.
    const matched = render.renderLinesParallel(self.gpa, arena, req, docs, &out) catch |e| switch (e) {
        error.OutOfMemory => return QueryError.OutOfMemory,
        error.Unsupported => return .{ .declined = .freshness_unprovable },
    };
    if (ceil.declined()) return .{ .declined = .freshness_unprovable };
    return .{ .got = .{ .out = out.items, .matched = matched } };
}

/// Zero-copy sibling of `queryLines`: gather the SAME path-sorted docs under
/// the same lock+reconcile, then render through `render.renderLinesShm`, which
/// chooses the transport by answer size — at/above `floor` the daemon hands the
/// client a shared-memory fd (the answer never traverses the socket); below it,
/// or on any shm failure, the SAME bytes come back to stream as `chunk` frames.
/// The caller owns any returned buffer (must close it). Byte-identical to
/// `queryLines` for the same corpus state; `-m0` is the empty chunk answer.
pub fn queryLinesShm(self: *ResidentSession, arena: std.mem.Allocator, req: Request, floor: usize) QueryError!answer.Answer(render.LinesEmit) {
    if (req.matchNothing()) return .{ .got = .{ .chunk = .{ .bytes = "", .matched = false } } };
    var tripped: std.atomic.Value(bool) = .init(false);
    var held = switch (try self.beginRead(&tripped)) {
        .got => |h| h,
        .declined => |d| return .{ .declined = d },
    };
    defer held.lease.release();
    switch (try reconcile.guardExtras(self, &held, req)) {
        .got => {},
        .declined => |d| return .{ .declined = d },
    }
    const ceil = held.ceil;

    var cq = switch (try gather.compileFor(self, req, .files)) {
        .got => |compiled| compiled,
        .declined => |d| return .{ .declined = d },
    };
    defer cq.deinit(self.gpa);
    var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
    defer sc.deinit();

    const docs = try gather.matchingDocs(self, arena, &cq, req.filter, &sc, .lines, req.invert, .{}, ceil);
    const rendered = render.renderLinesShm(self.gpa, arena, req, docs, floor) catch |e| switch (e) {
        error.OutOfMemory => return QueryError.OutOfMemory,
        error.Unsupported => return .{ .declined = .freshness_unprovable },
    };
    return if (ceil.declined()) .{ .declined = .freshness_unprovable } else .{ .got = rendered };
}

/// Answer a `--rank[=N]` request over resident bytes: gist's definition-first
/// ranked view (`ranked.zig`), the one shape rg can't express. The candidate
/// set is the SAME trigram-pruned, scope-gated ids the line faces gather (so a
/// caseless rank prunes soundly instead of scanning the whole tree), gathered
/// as in-memory `LiveFile`s in ASCENDING mirror-id order — the exact id order
/// cold's index rank path appends in, so the RRF tiebreak (`rank.zig`: fused
/// score desc, then array position) is byte-identical on a quiescent tree.
/// `arena` owns the returned rendered bytes; the overlay's fresher-than-index
/// docs fold in after the base half (empty on a quiescent tree, so
/// parity-neutral — under churn warm is simply fresher, the daemon's standing
/// contract). A pattern outside the linear engine (declined `-F`, or a
/// compile decline) returns `freshness_unprovable`; OOM remains a fault.
/// `k` is the surfaced-row cap (`0` ⇒ cold's default 20).
pub fn queryRank(self: *ResidentSession, arena: std.mem.Allocator, req: Request, k: usize) QueryError!answer.Answer([]const u8) {
    var tripped: std.atomic.Value(bool) = .init(false);
    var held = switch (try self.beginRead(&tripped)) {
        .got => |h| h,
        .declined => |d| return .{ .declined = d },
    };
    defer held.lease.release();
    switch (try reconcile.guardExtras(self, &held, req)) {
        .got => {},
        .declined => |d| return .{ .declined = d },
    }
    const ceil = held.ceil;

    // The whole-doc gate doubles as the candidate compiler; its regex body IS
    // the linear engine cold ranks with (`serial.zig`'s `re.linear`), compiled
    // from the same pattern/case/unicode — reuse it (no second compile).
    // `--rank` declines `-F` in `classify`, so the body is always a regex here.
    var cq = switch (try gather.compileFor(self, req, .files)) {
        .got => |compiled| compiled,
        .declined => |d| return .{ .declined = d },
    };
    defer cq.deinit(self.gpa);
    // `--rank` is linear-only: `classify` declines `-F` AND `-P` alongside
    // it, so the body is always the linear arm here (the AST `ranked` ranks
    // with). A PCRE2 or literal body defensively declines → cold.
    const rex = switch (cq.body) {
        .engine => |*m| switch (m.*) {
            .linear => |*r| r,
            .pcre => return .{ .declined = .freshness_unprovable },
        },
        .literal => return .{ .declined = .freshness_unprovable },
    };

    var cand_buf: ?[]u32 = null;
    defer if (cand_buf) |c| self.gpa.free(c);
    const cand = try gather.candidateIds(self, &cq, req.filter, &cand_buf);

    // Base candidates in ascending id order (cold's index-rank append order),
    // then the bounded overlay — `renderLive`'s `fileDoc` re-verifies each and
    // drops trigram false positives, so the surviving ranked set is identical
    // to cold's, and the array position (the RRF tiebreak) matches too.
    var files: std.ArrayList(ranked.LiveFile) = .empty;
    for (cand, 0..) |id, i| {
        if (ceil.over(self.io, i)) {
            self.noteBudgetAbort();
            return .{ .declined = .freshness_unprovable };
        }
        const path = self.mir.paths[id];
        if (self.overlay.contains(path)) continue; // the overlay pass owns it
        files.append(arena, .{ .path = path, .bytes = self.mir.docs[id] }) catch return QueryError.OutOfMemory;
    }
    var it = self.overlay.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .tombstone => {},
        .doc => |d| {
            if (!req.filter.admits(e.key_ptr.*)) continue;
            files.append(arena, .{ .path = e.key_ptr.*, .bytes = d.bytes }) catch return QueryError.OutOfMemory;
        },
    };

    var out: std.ArrayList(u8) = .empty;
    // `binary_detect=true` = cold's `!-a` default: `renderLive`'s `fileDoc`
    // clips a NUL-bearing walked file to its committed prefix, so warm rank
    // excludes compiled-binary symbol hits exactly as cold does (the search
    // visitors above already drop them; `-a` is an exotic flag that falls to
    // cold, so the resident rank path never needs to read a binary as text).
    _ = ranked.renderLive(arena, self.io, rex, files.items, k, &out, true) catch |err|
        return if (err == error.OutOfMemory) QueryError.OutOfMemory else .{ .declined = .freshness_unprovable };
    return .{ .got = out.items };
}
