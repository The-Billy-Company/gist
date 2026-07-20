//! gist `index` — build + persist the trigram index and freshness anchor.
//!
//! The one mutating lifecycle action behind the `gist index` verb. It scans the
//! corpus (every non-binary file under the resolved roots — explicit argv, else
//! `corpus.resolveRoots`), builds the trigram `Index`, and generation-publishes
//! it plus the doc→path table, the build roots (`roots.list`), and the
//! freshness anchor (`corpus/fresh.zig`) that later queries map back zero-copy.
//! The persisted index is what the unified engine's read-elision path
//! (`run.zig` `IndexSkip`) and the ranked view (`rank.zig`) consume — building
//! it lives here, beside them, now that the engines have merged (hoisted out of
//! the former `commands/search/drivers.zig` when that module was deleted).

const std = @import("std");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const fresh = @import("../../../../corpus/index/trigrams/fresh.zig");
const persist = @import("../../../../corpus/index/trigrams/persist.zig");
const crest_sidecar = @import("../../../../corpus/index/crest/sidecar.zig");
const Index = @import("../../../../corpus/index/trigrams/trigram.zig").Index;
const nowNs = @import("../../../exec/cold/argv/args.zig").nowNs;
const ms = @import("../../../exec/cold/argv/args.zig").ms;

/// Build once, persist the index + the doc→path table (NUL-separated, doc-id
/// order) so a later fresh process can map candidate ids back to files.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    const t0 = nowNs(io);
    // Wall-clock anchor captured BEFORE the read, so a file touched during the
    // build has mtime or status-ctime ≥ anchor and is re-verified next query.
    const built_ns = std.Io.Clock.now(.real, io).nanoseconds;
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();
    // Crest sidecar (the class-run sieve, research/crest/): one parallel pass
    // over the already-loaded docs. Best-effort — an OOM here costs only the
    // sieve, never the index build.
    const crest_vectors: ?[]const @import("../../../../kernel/primitives/crest.zig").Vector =
        crest_sidecar.build(gpa, corpus.docs) catch null;
    defer if (crest_vectors) |cv| gpa.free(cv);

    // Generation-atomic publish: all blobs stage under gens/<id>/, then
    // pair.gen flips — concurrent loaders never see a mixed old/new set.
    const index_bytes = try persist.persistIndexAndPaths(gpa, io, &idx, corpus.paths, roots, crest_vectors);
    try fresh.writeAnchor(io, built_ns); // T3 freshness anchor

    std.debug.print("indexed {d} files · {d:.1} MiB corpus · {d:.1} MiB index · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(index_bytes)) / (1 << 20),
        ms(nowNs(io) - t0),
        corpus_mod.outDir(),
    });
}
