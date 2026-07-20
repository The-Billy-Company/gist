//! relate — the `index` and `status` lifecycle verbs. relate owns its warm
//! state the way `gist` owns the trigram index: a full engine, not a shim.
//!
//!   relate index [--shelf]     build + persist the kinship atlas
//!                              (`kinship.atlas`: one LZJD sketch + one
//!                              structure silhouette per corpus file —
//!                              index/atlas/atlas.zig); `--shelf` also
//!                              rebuilds the codex shelf `quote` reads (the
//!                              same artifact `gist codex build` writes — one
//!                              shelf, two product faces)
//!   relate status [--json]     is the atlas ready, how big, how fresh — and
//!                              is the codex shelf `quote` needs present
//!
//! The anchor is captured BEFORE the corpus read (the T3 convention), so a
//! file touched mid-build reports as changed on the next query's fold.
//! Persistence is atomic (temp-then-rename) — ~10 coworking agents can race
//! `relate index` against a mid-query load and never observe torn bytes.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const fresh = @import("../../../corpus/index/trigrams/fresh.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const atlas_mod = @import("../../../corpus/index/atlas/atlas.zig");
const frag_mod = @import("../../../corpus/index/frag/frag.zig");
const codex_face = @import("../gist/lifecycle/codex.zig");
const cli_args = @import("../../exec/cold/argv/args.zig");
const kinship = @import("kinship.zig");

const nowNs = cli_args.nowNs;
const ms = cli_args.ms;
const Dir = std.Io.Dir;

/// Version of the `status --json` machine contract; bump on breaking change.
pub const schema_version = 1;

/// `relate index [--shelf]` — sketch the index corpus, persist the atlas
/// atomically; `--shelf` also rebuilds the codex shelf from the same read.
pub fn runIndex(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const with_shelf = kinship.onlyFlag(argv, "--shelf", "usage: relate index [--shelf]\n");

    const t0 = nowNs(io);
    const built_ns: i64 = @intCast(std.Io.Clock.now(.real, io).nanoseconds);
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();

    const sketches = kinship.buildSketches(gpa, corpus.docs);
    defer gpa.free(sketches);
    const silhouettes = kinship.buildSilhouettes(gpa, corpus.docs);
    defer gpa.free(silhouettes);
    const blob = try atlas_mod.save(gpa, corpus.paths, sketches, silhouettes, built_ns, roots);
    defer gpa.free(blob);
    try persist.writeAtomic(io, atlas_mod.atlasFile(), blob);
    std.debug.print("atlas: {d} files · {d:.1} MiB corpus → {d:.1} MiB atlas · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(blob.len)) / (1 << 20),
        ms(nowNs(io) - t0),
        atlas_mod.atlasFile(),
    });

    // The fragment tier rides the same corpus read + anchor: one silhouette per
    // extracted function, so `relate concepts` answers warm.
    const f0 = nowNs(io);
    var fbuild = try frag_mod.buildAll(gpa, &corpus);
    defer fbuild.deinit();
    const fblob = try frag_mod.save(gpa, &fbuild, built_ns, roots);
    defer gpa.free(fblob);
    try persist.writeAtomic(io, frag_mod.fragFile(), fblob);
    std.debug.print("frag:  {d} fragment(s) → {d:.1} MiB · {d:.0} ms → {s}\n", .{
        fbuild.count(),
        @as(f64, @floatFromInt(fblob.len)) / (1 << 20),
        ms(nowNs(io) - f0),
        frag_mod.fragFile(),
    });

    if (with_shelf) {
        const s0 = nowNs(io);
        const shelf = try codex_face.persistShelf(gpa, io, &corpus, built_ns);
        std.debug.print("shelf: {d:.1} MiB ({d:.2} bits/char) · {d:.0} ms → {s}\n", .{
            @as(f64, @floatFromInt(shelf.bytes)) / (1 << 20),
            shelf.bits_per_char,
            ms(nowNs(io) - s0),
            codex_face.shelfFile(),
        });
    }
}

fn fileBytes(io: std.Io, path: []const u8) ?u64 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return null;
    return @intCast(st.size);
}

const Status = struct {
    schema_version: u8 = schema_version,
    atlas: struct {
        state: enum { ready, unavailable },
        files: usize = 0,
        bytes: u64 = 0,
        stale_files: usize = 0,
        built_unix_ns: i64 = 0,
    },
    frag: struct {
        state: enum { ready, unavailable },
        fragments: usize = 0,
        bytes: u64 = 0,
        stale_files: usize = 0,
        built_unix_ns: i64 = 0,
    },
    shelf: struct {
        state: enum { ready, unavailable },
        bytes: u64 = 0,
    },
};

/// `relate status [--json]` — atlas + shelf readiness. Exit 0 when the atlas
/// is ready (the kinship verbs run warm), 1 when it is missing/corrupt (they
/// still answer, live). Shelf detail beyond presence stays with
/// `gist codex status` — one artifact, one deep report.
pub fn runStatus(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const json = kinship.onlyFlag(argv, "--json", "usage: relate status [--json]\n");

    var st = Status{
        .atlas = .{ .state = .unavailable },
        .frag = .{ .state = .unavailable },
        .shelf = .{ .state = .unavailable },
    };
    if (atlas_mod.loadQuiet(gpa, io)) |atl_v| {
        var atl = atl_v;
        defer atl.deinit(gpa);
        st.atlas = .{
            .state = .ready,
            .files = atl.paths.len,
            .bytes = fileBytes(io, atlas_mod.atlasFile()) orelse 0,
            .stale_files = fresh.staleCount(gpa, io, atl.roots, atl.built_ns),
            .built_unix_ns = atl.built_ns,
        };
    }
    if (frag_mod.loadQuiet(gpa, io)) |frag_v| {
        var f = frag_v;
        defer f.deinit(gpa);
        st.frag = .{
            .state = .ready,
            .fragments = f.spans.len,
            .bytes = fileBytes(io, frag_mod.fragFile()) orelse 0,
            .stale_files = fresh.staleCount(gpa, io, f.roots, f.built_ns),
            .built_unix_ns = f.built_ns,
        };
    }
    if (fileBytes(io, codex_face.shelfFile())) |b| st.shelf = .{ .state = .ready, .bytes = b };

    const shelf_line = if (st.shelf.state == .ready) "ready (quote answers)" else "missing — `relate index --shelf` builds it";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (json) {
        const body = try std.json.Stringify.valueAlloc(gpa, st, .{});
        defer gpa.free(body);
        try out.print(gpa, "{s}\n", .{body});
    } else if (st.atlas.state == .ready) {
        const frag_line = if (st.frag.state == .ready) "ready (concepts answers)" else "missing — `relate index` builds it";
        try out.print(gpa,
            \\relate — kinship atlas {s}
            \\  files sketched  {d}
            \\  atlas           {d:.1} MiB
            \\  changed since   {d} file(s) (folded in at query time)
            \\  fragments       {d} · {d:.1} MiB · {d} changed — {s}
            \\  codex shelf     {s}
            \\
        , .{
            atlas_mod.atlasFile(),
            st.atlas.files,
            @as(f64, @floatFromInt(st.atlas.bytes)) / (1 << 20),
            st.atlas.stale_files,
            st.frag.fragments,
            @as(f64, @floatFromInt(st.frag.bytes)) / (1 << 20),
            st.frag.stale_files,
            frag_line,
            shelf_line,
        });
    } else {
        try out.print(gpa,
            \\relate — no kinship atlas at {s} (verbs answer live; `relate index` builds it)
            \\  codex shelf     {s}
            \\
        , .{ atlas_mod.atlasFile(), shelf_line });
    }
    corpus_mod.emitStdout(out.items);
    std.process.exit(if (st.atlas.state == .ready) 0 else 1);
}
