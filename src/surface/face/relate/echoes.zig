//! relate — the `echoes` verb: DRY candidates the byte channel cannot see.
//!
//!   relate echoes [--min-echo E] [--top N] [--json] [--no-index] [ROOT...]
//!       file pairs that are much closer in STRUCTURE than in bytes —
//!       same skeleton, different vocabulary — ranked by that gap.
//!
//! Why a verb of its own: `dups` finds copy-paste (close in bytes); the
//! interesting DRY case is the pair that would never surface there — two
//! modules that repeat a shape under different identifiers (Type-2 clones,
//! Roy–Cordy taxonomy). Neither channel alone can report it: byte distance
//! calls the pair unrelated, and structure distance alone has no clean
//! absolute threshold (measured on the graduation eval: family-max vs
//! cross-min overlap at every winnow setting). The DIFFERENCE is the signal:
//!
//!   echo = distance_bytes − distance_structure
//!
//! High echo reads "these two files share far more shape than vocabulary" —
//! an abstraction candidate, self-calibrated per pair (a pair close in both
//! channels is plain duplication and ranks low here; `dups` already owns it).
//! On the graduation eval the echo list hit P@10 = 100% against an 11.9%
//! base rate on the Python family corpus, and surfaced true structural kin
//! (twin generated tables, two persisted-blob formats) beyond the labels.
//!
//! Candidates come from silhouette seed buckets (structure-close nominates —
//! the same bottom-16 machinery `dups` rides, pointed at the other channel);
//! every emitted pair is exactly verified against BOTH full records. Ordering
//! is total: echo desc, then path asc. Emitted members pass the deletion gate
//! when answering from the atlas.
//!
//! Two noise classes are dropped before scoring — the DRY question wants
//! authored abstraction candidates, not artifacts of that shape:
//!   • Codegen. Twin templates are the densest structural clones on earth
//!     (identical shape, renamed symbols → structure 0), but the fix lives in
//!     the template, never the output — so a generated pair is demoted the way
//!     `gist --rank` sinks codegen (path suffix only, no byte re-read).
//!   • Sub-mass files. A file too short to shed `min_mass` fingerprints
//!     (fixture formats, tiny configs, fuzz seeds) has a structure distance
//!     estimated over a handful of KMV samples — `structure ≈ 0` there is
//!     small-sample noise, and a `[]byte("…")` fixture pair repeating a
//!     serialization format is never an abstraction candidate.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const cli_args = @import("../../exec/cold/argv/args.zig");
const sketch = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const signals = @import("../../../kernel/rank/signals.zig");
const kinship = @import("kinship.zig");
const emit = @import("../../cli/emit.zig");

const nowNs = cli_args.nowNs;
const ms = cli_args.ms;

/// A file needs at least this many structural fingerprints for a
/// structure-kinship claim to rest on a real KMV sample (not a coincidence of
/// a few shingles) and to carry enough shape to be a refactor candidate.
/// Anchored to the bottom-k seed width — below it a record barely buckets.
const min_mass = kinship.seed_hashes;

/// One verified echo pair (i < j), in the total (echo desc, path, path) order.
const Echo = struct {
    echo: f64,
    d_bytes: f64,
    d_structure: f64,
    i: u32,
    j: u32,

    fn less(paths: []const []const u8, x: Echo, y: Echo) bool {
        if (x.echo != y.echo) return x.echo > y.echo; // widest gap first
        const c = std.mem.order(u8, paths[x.i], paths[y.i]);
        if (c != .eq) return c == .lt;
        return std.mem.order(u8, paths[x.j], paths[y.j]) == .lt;
    }
};

pub fn runEchoes(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: kinship.Opts = .{ .top = 50 };
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try kinship.parseOpts(gpa, argv, &o, &roots, .{ .min_echo = true, .no_index = true, .strict = "echoes" });

    const t0 = nowNs(io);
    var view = try kinship.resolve(gpa, io, roots.items, o.no_index, .structure);
    defer view.deinit();

    // Structure-close nominates; both channels verify exactly. A pair below
    // the echo floor is dropped here, not at the bucket stage — the bucket
    // may only skip work, never decide.
    const Ctx = struct {
        gpa: std.mem.Allocator,
        paths: []const []const u8,
        sketches: []const kinship.Sketch,
        silhouettes: []const kinship.Silhouette,
        min_echo: f64,
        pairs: std.ArrayList(Echo) = .empty,

        fn visit(self: *@This(), a: u32, z: u32) error{OutOfMemory}!void {
            // Codegen is the densest structural-clone source (twin templates
            // land at structure 0), but a generated pair is never a refactor
            // candidate — the template is the source. Demote it the same way
            // `gist --rank` sinks codegen; path-only, no re-read of the bytes.
            if (signals.isGeneratedPath(self.paths[a]) or signals.isGeneratedPath(self.paths[z])) return;
            // Both files must carry enough structure to make "shared shape" a
            // real claim — see min_mass. Skips fixture/config noise at the source.
            if (self.silhouettes[a].len < min_mass or self.silhouettes[z].len < min_mass) return;
            const ds = silhouette_mod.distance(&self.silhouettes[a], &self.silhouettes[z]);
            const db = sketch.distance(&self.sketches[a], &self.sketches[z]);
            const echo = db - ds;
            if (echo >= self.min_echo)
                try self.pairs.append(self.gpa, .{ .echo = echo, .d_bytes = db, .d_structure = ds, .i = a, .j = z });
        }
    };
    var ctx = Ctx{ .gpa = gpa, .paths = view.paths, .sketches = view.sketches, .silhouettes = view.silhouettes, .min_echo = o.min_echo };
    defer ctx.pairs.deinit(gpa);
    try kinship.forEachCandidatePair(kinship.Silhouette, gpa, view.silhouettes, &ctx, Ctx.visit);
    std.mem.sort(Echo, ctx.pairs.items, view.paths, Echo.less);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var emitted: usize = 0;
    for (ctx.pairs.items) |p| {
        if (emitted >= o.top) break;
        if (!view.gate(p.i) or !view.gate(p.j)) continue; // deleted since the anchor
        emitted += 1;
        emit.emitRow(&buf, gpa, o.json, .{
            .{ "a", "s", view.paths[p.i] },
            .{ "b", "s", view.paths[p.j] },
            .{ "echo", "d:.4", p.echo },
            .{ "bytes", "d:.4", p.d_bytes },
            .{ "structure", "d:.4", p.d_structure },
        }, "{d:.4}  (bytes {d:.4} · structure {d:.4})  {s}  {s}\n", .{
            p.echo, p.d_bytes, p.d_structure, view.paths[p.i], view.paths[p.j],
        });
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("echoes: {d} files ({s}{d} refreshed) · {d} pair(s) ≥ {d:.2} · {d:.0} ms\n", .{
        view.paths.len,
        if (view.from_atlas) "atlas, " else "live, ",
        view.refreshed,
        ctx.pairs.items.len,
        o.min_echo,
        ms(nowNs(io) - t0),
    });
}
