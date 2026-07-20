//! relate — the `clusters` verb: fork families over the near-duplicate graph.
//!
//!   relate clusters [--max-distance T] [--min-size N] [--top N] [--json]
//!                   [--no-index] [ROOT...]
//!       connected components of the verified dup graph, largest families
//!       first — the whole fixture farm or mirrored module tree in one
//!       answer, not a flat pair list the caller re-joins.
//!
//! Why a verb of its own: `dups` answers "which two files drifted?"; a
//! restructure/dedup sweep asks the transitive question — "which files are
//! all the same thing?" A pair list makes the caller run its own union-find
//! (and every consumer has, in Python); the engine already holds the
//! verified edges, so the component pass is engine-side and total-ordered.
//! Token-parsing dup tools (jscpd, PMD CPD) stop at per-language pair lists;
//! the LZJD graph is language-blind and clusters any byte kin.
//!
//! Edges come from the same machinery as `dups` (`kinship.verifiedPairs`:
//! bottom-16 seed buckets nominate, both full sketches verify exactly), so a
//! cluster is precisely the transitive closure of what `dups` would emit at
//! the same threshold. Ordering is total: families by size desc, then
//! exemplar path asc; members path-asc within a family. Emitted members pass
//! the deletion gate when answering from the atlas.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const cli_args = @import("../../exec/cold/argv/args.zig");
const families = @import("../../../kernel/kinship/cluster/families.zig");
const kinship = @import("kinship.zig");
const emit = @import("../../cli/emit.zig");

const oom = cli_args.oom;
const nowNs = cli_args.nowNs;
const ms = cli_args.ms;

const Forest = families.Forest;

/// One family, materialized for the sort: member doc ids (path-asc) and the
/// tightest edge distance range observed inside it.
const Family = struct {
    members: []u32,
    max_edge: f64,

    fn less(paths: []const []const u8, x: Family, y: Family) bool {
        if (x.members.len != y.members.len) return x.members.len > y.members.len;
        return std.mem.order(u8, paths[x.members[0]], paths[y.members[0]]) == .lt;
    }
};

pub fn runClusters(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: kinship.Opts = .{ .top = 50 };
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try kinship.parseOpts(gpa, argv, &o, &roots, .{ .max_dist = true, .min_size = true, .no_index = true, .strict = "clusters" });

    const t0 = nowNs(io);
    var view = try kinship.resolve(gpa, io, roots.items, o.no_index, .bytes);
    defer view.deinit();
    const pairs = try kinship.verifiedPairs(gpa, view.paths, view.sketches, o.max_dist);
    defer gpa.free(pairs);

    var forest = try Forest.init(gpa, view.paths.len);
    defer gpa.free(forest.parent);
    for (pairs) |p| forest.join(p.i, p.j);

    // Materialize components ≥ min_size, dropping members deleted since the
    // atlas anchor (a family that shrinks below min_size drops with them).
    // One map per component root: the tightest-edge range AND the member list
    // (an absent root after the pairs pass = singleton, no verified edge).
    const Group = struct { members: std.ArrayList(u32) = .empty, max_edge: f64 = 0.0 };
    var groups: std.AutoArrayHashMapUnmanaged(u32, Group) = .empty;
    defer {
        for (groups.values()) |*g| g.members.deinit(gpa);
        groups.deinit(gpa);
    }
    for (pairs) |p| {
        const gop = try groups.getOrPut(gpa, forest.find(p.i));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.max_edge = @max(gop.value_ptr.max_edge, p.dist);
    }
    for (0..view.paths.len) |d| {
        const id: u32 = @intCast(d);
        const g = groups.getPtr(forest.find(id)) orelse continue; // singleton: no verified edge
        if (!view.gate(d)) continue; // deleted since the atlas anchor
        try g.members.append(gpa, id);
    }

    var fams: std.ArrayList(Family) = .empty;
    defer {
        for (fams.items) |f| gpa.free(f.members);
        fams.deinit(gpa);
    }
    for (groups.values()) |*g| {
        if (g.members.items.len < o.min_size) continue;
        const members = try gpa.dupe(u32, g.members.items);
        std.mem.sort(u32, members, view.paths, struct {
            fn less(paths: []const []const u8, a: u32, b: u32) bool {
                return std.mem.order(u8, paths[a], paths[b]) == .lt;
            }
        }.less);
        try fams.append(gpa, .{ .members = members, .max_edge = g.max_edge });
    }
    std.mem.sort(Family, fams.items, view.paths, Family.less);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const n = @min(o.top, fams.items.len);
    for (fams.items[0..n]) |f| {
        if (o.json) {
            buf.print(gpa, "{{\"size\":{d},\"max_distance\":{d:.4},\"paths\":[", .{ f.members.len, f.max_edge }) catch oom();
            for (f.members, 0..) |m, k| {
                if (k > 0) buf.append(gpa, ',') catch oom();
                emit.jsonStr(&buf, gpa, view.paths[m]);
            }
            buf.appendSlice(gpa, "]}\n") catch oom();
        } else {
            buf.print(gpa, "{d} files · ≤ {d:.4}\n", .{ f.members.len, f.max_edge }) catch oom();
            for (f.members) |m| buf.print(gpa, "  {s}\n", .{view.paths[m]}) catch oom();
        }
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("clusters: {d} files ({s}{d} refreshed) · {d} famil{s} ≥ {d} member(s) at ≤ {d:.2} · {d:.0} ms\n", .{
        view.paths.len,
        view.provenance(),
        view.refreshed,
        fams.items.len,
        if (fams.items.len == 1) "y" else "ies",
        o.min_size,
        o.max_dist,
        ms(nowNs(io) - t0),
    });
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "Family.less: size desc, then exemplar path asc" {
    const paths = [_][]const u8{ "a", "b", "c" };
    var big = [_]u32{ 0, 1 };
    var small_b = [_]u32{1};
    var small_c = [_]u32{2};
    const fx: Family = .{ .members = &big, .max_edge = 0.5 };
    const fy: Family = .{ .members = &small_b, .max_edge = 0.1 };
    const fz: Family = .{ .members = &small_c, .max_edge = 0.1 };

    try t.expect(Family.less(&paths, fx, fy)); // bigger family first
    try t.expect(Family.less(&paths, fy, fz)); // size tie: exemplar path asc
    try t.expect(!Family.less(&paths, fz, fy));
    try t.expect(!Family.less(&paths, fy, fy)); // strict: never self-less
}
