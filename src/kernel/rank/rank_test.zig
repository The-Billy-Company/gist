//! gist T4 RRF-ranking tests — split from `rank.zig` to keep each tier file lean
//! and tests in a sibling. Pulled into `zig build test` via `root.zig`'s test
//! block. Asserts the editorial fusion calls: a definition beats a far hotter
//! call site (symbol weight), density-then-shallowness orders the rest, the
//! optional external graph signal fuses in and is weight-controlled, and the
//! trivial 0/1-doc sizes are well-defined.

const std = @import("std");
const rank_mod = @import("rank.zig");
const Doc = rank_mod.Doc;
const rank = rank_mod.rank;

test "rrf: definition beats a higher-frequency call site" {
    const docs = [_]Doc{
        .{ .id = 10, .matches = 50, .is_def = false, .best_line = 5, .depth = 3 }, // hot usage
        .{ .id = 20, .matches = 2, .is_def = true, .best_line = 1, .depth = 3 }, // the def
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    // The symbol signal (weight 2) lifts the definition above the 25×-hotter usage.
    try std.testing.expectEqual(@as(u32, 1), order[0]); // docs[1] == the def
    try std.testing.expectEqual(@as(u32, 0), order[1]);
}

test "rrf: full definition beats a type-only declaration" {
    const docs = [_]Doc{
        .{ .id = 1, .matches = 2, .is_def = true, .definition = 1, .best_line = 2, .depth = 2 },
        .{ .id = 2, .matches = 2, .is_def = true, .definition = 3, .best_line = 4, .depth = 2 },
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(u32, 1), order[0]);
}

test "rrf: relate-style shape pricing discounts repeated use geometry" {
    const docs = [_]Doc{
        .{ .id = 1, .matches = 1, .is_def = false, .shape_hash = 11, .best_line = 1, .depth = 2 },
        .{ .id = 2, .matches = 1, .is_def = false, .shape_hash = 11, .best_line = 1, .depth = 2 },
        .{ .id = 3, .matches = 1, .is_def = false, .shape_hash = 11, .best_line = 1, .depth = 2 },
        .{ .id = 4, .matches = 1, .is_def = false, .shape_hash = 99, .best_line = 1, .depth = 2 },
    };
    const order = try rank(std.testing.allocator, &docs, .{
        .lexical = 0,
        .symbol = 0,
        .structure = 1,
        .shallow = 0,
        .graph = 0,
        .generated = 0,
    }, null);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(u32, 3), order[0]);
}

test "rrf: among non-defs, density then shallowness win" {
    const docs = [_]Doc{
        .{ .id = 1, .matches = 1, .is_def = false, .best_line = 9, .depth = 6 },
        .{ .id = 2, .matches = 9, .is_def = false, .best_line = 2, .depth = 2 },
        .{ .id = 3, .matches = 9, .is_def = false, .best_line = 2, .depth = 5 },
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(u32, 1), order[0]); // most matches AND shallowest
    try std.testing.expectEqual(@as(u32, 2), order[1]); // same matches, deeper
    try std.testing.expectEqual(@as(u32, 0), order[2]); // fewest matches
}

test "rrf: a generated file is demoted below authored code despite winning lexical+symbol" {
    // The context.Context pollution: a `*_grpc.pb.go` stub wins lexical (×100
    // occurrences) AND symbol (its boilerplate `func (c *…)` parses as a def),
    // so without the authored signal it floods the head. The authored weight (3)
    // must outrank that double boost and sink it below real code.
    const docs = [_]Doc{
        .{ .id = 0, .matches = 100, .is_def = true, .best_line = 50, .depth = 4, .is_generated = true }, // codegen flood
        .{ .id = 1, .matches = 4, .is_def = true, .best_line = 10, .depth = 3 }, // the authored def
        .{ .id = 2, .matches = 8, .is_def = false, .best_line = 2, .depth = 5 }, // hot authored usage
        .{ .id = 3, .matches = 2, .is_def = false, .best_line = 1, .depth = 2 }, // sparse authored usage
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    // The generated stub (idx 0), despite ×100 + def, is sunk to LAST; the
    // authored definition (idx 1) rightfully takes the head, the authored usages
    // follow, and only then the codegen flood.
    try std.testing.expectEqual(@as(u32, 1), order[0]); // authored def, #1
    try std.testing.expectEqual(@as(u32, 0), order[3]); // generated stub, last
}

test "rrf: the authored signal only reorders generated vs authored, never within a class" {
    // When every match is generated (a proto-only symbol), the demotion is
    // uniform, so it must not perturb the def-first ordering among them.
    const docs = [_]Doc{
        .{ .id = 0, .matches = 50, .is_def = false, .best_line = 5, .depth = 3, .is_generated = true },
        .{ .id = 1, .matches = 2, .is_def = true, .best_line = 1, .depth = 3, .is_generated = true },
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(u32, 1), order[0]); // the generated def still beats the hotter generated usage
    try std.testing.expectEqual(@as(u32, 0), order[1]);
}

test "rrf: a cached source mirror is demoted below its canonical file" {
    const docs = [_]Doc{
        .{ .id = 0, .matches = 20, .is_def = true, .best_line = 8, .depth = 7, .is_mirror = true },
        .{ .id = 1, .matches = 2, .is_def = true, .best_line = 8, .depth = 3 },
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(u32, 1), order[0]);
    try std.testing.expectEqual(@as(u32, 0), order[1]);
}

test "rrf: external graph ranking fuses in and drives the order" {
    const docs = [_]Doc{
        .{ .id = 100, .matches = 5, .is_def = false, .best_line = 3, .depth = 4 },
        .{ .id = 200, .matches = 5, .is_def = false, .best_line = 3, .depth = 4 },
    };
    // A dominant graph signal puts whichever id it ranks first on top, and flipping the order flips the result —
    // proving the optional signal fuses in and is weight-controlled.
    const graph_a = [_]u32{ 200, 100 };
    const a = try rank(std.testing.allocator, &docs, .{ .graph = 100 }, &graph_a);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(@as(u32, 1), a[0]); // docs[1].id == 200

    const graph_b = [_]u32{ 100, 200 };
    const b = try rank(std.testing.allocator, &docs, .{ .graph = 100 }, &graph_b);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u32, 0), b[0]); // docs[0].id == 100
}

test "rank: trivial sizes are well-defined" {
    const empty = try rank(std.testing.allocator, &[_]Doc{}, .{}, null);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const one = [_]Doc{.{ .id = 7, .matches = 1, .is_def = false, .best_line = 1, .depth = 1 }};
    const got = try rank(std.testing.allocator, &one, .{}, null);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(u32, 0), got[0]);
}
