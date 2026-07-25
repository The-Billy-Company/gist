//! Stable C-ABI data contract for the analytic plane's rows (ADR-377).
//!
//! `contract.zig` owns the EXACT plane's layout and the one status vocabulary.
//! This module is its analytic sibling: the self-describing row every kinship,
//! retrieval, sweep, and composed verb answers with, plus the arena-backed
//! `Builder` that assembles one.
//!
//! ## Why one row instead of seventeen structs
//!
//! Seventeen verbs times three bindings is fifty-one hand-mirrored result
//! structs with nothing able to prove they agree — the drift
//! `contract/search_api.toml` exists to kill. So a row carries its schema id
//! and a flat value array, `[row_schemas]` declares what that array means, and
//! `tools/build_schema_tables.py` lowers the declaration into `schema.gen.zig`
//! here and into a decoder table in each binding. A verb that reuses a schema
//! costs no new surface at all.
//!
//! ## Absent is not zero
//!
//! `distance = 0.0` means *identical*, so a row cannot spell "no distance" by
//! storing zero. `Row.present` is a bit per field; `Builder.skip` clears one.
//! Every binding is required to read the mask before the value.
//!
//! ## Lifetime
//!
//! Everything a row points at — its values, its texts, its nested rows — lives
//! in ONE arena owned by the cursor that produced it, so a row stays valid
//! until that cursor closes. That is deliberately stronger than the exact
//! plane's `Match`, which borrows a scratch buffer recycled every pull: an
//! analytic answer is materialized whole, so there is nothing to recycle, and a
//! batching host can hold every batch it has pulled without copying.

const std = @import("std");
const contract = @import("contract.zig");

pub const Status = contract.Status;

/// The generated table: `digest`, `schemas`, `verbs`, `Id`, `Op`, `Tag`, and
/// the `[row_enums]` enums. Regenerate with `make gen-gist-schema`.
pub const table = @import("schema.gen.zig");

/// A borrowed UTF-8 span. NOT NUL-terminated — `len` is authoritative.
pub const Text = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn of(s: []const u8) Text {
        return .{ .ptr = s.ptr, .len = s.len };
    }

    pub fn slice(self: Text) []const u8 {
        return self.ptr[0..self.len];
    }
};

/// One field of one row.
///
/// A flat tagged record rather than a C payload union: that union saves sixteen
/// bytes against queries that scan megabytes, and costs every binding an
/// anonymous-type parse its FFI layer may not support (cffi, cgo, and bindgen
/// each have their own trouble with one). `tag` selects exactly one payload;
/// the rest are zero. The pointer alone stays typed in Zig while retaining the
/// single-pointer layout C sees, so constructing and reading a value never
/// erases its pointee type.
pub const Pointer = extern union {
    text: ?[*]const u8,
    texts: ?[*]const Text,
    rows: ?[*]const Row,
    erased: ?*const anyopaque,
};

pub const Value = extern struct {
    tag: u32,
    reserved: u32 = 0,
    /// `i64` · `bool` (0/1) · `enum` ordinal.
    integer: i64 = 0,
    /// `f64`.
    real: f64 = 0,
    /// `text` bytes · `texts` `[*]const Text` · `rows` `[*]const Row`.
    ptr: Pointer = .{ .erased = null },
    /// Element count for `ptr` (bytes for `text`).
    len: usize = 0,

    pub fn text(s: []const u8) Value {
        return .{ .tag = @intFromEnum(table.Tag.text), .ptr = .{ .text = s.ptr }, .len = s.len };
    }
    pub fn int(v: i64) Value {
        return .{ .tag = @intFromEnum(table.Tag.i64), .integer = v };
    }
    pub fn float(v: f64) Value {
        return .{ .tag = @intFromEnum(table.Tag.f64), .real = v };
    }
    pub fn boolean(v: bool) Value {
        return .{ .tag = @intFromEnum(table.Tag.bool), .integer = @intFromBool(v) };
    }
    /// An enum crosses as its ORDINAL, never its text — the label is the
    /// binding's to resolve from the generated table, so a newer variant is
    /// reported as unknown rather than mis-labeled.
    pub fn ordinal(v: anytype) Value {
        return .{ .tag = @intFromEnum(table.Tag.@"enum"), .integer = @intFromEnum(v) };
    }
    pub fn texts(items: []const Text) Value {
        return .{ .tag = @intFromEnum(table.Tag.texts), .ptr = .{ .texts = items.ptr }, .len = items.len };
    }
    pub fn nested(items: []const Row) Value {
        return .{ .tag = @intFromEnum(table.Tag.rows), .ptr = .{ .rows = items.ptr }, .len = items.len };
    }
};

/// One result row. `schema_id` names a `[row_schemas]` table whose field order
/// IS `values`; `present` bit *i* is clear when field *i* is absent.
pub const Row = extern struct {
    schema_id: u32,
    nvalues: u32,
    present: u64,
    values: [*]const Value,

    pub fn valueSlice(self: Row) []const Value {
        return self.values[0..self.nvalues];
    }

    pub fn has(self: Row, index: u6) bool {
        return self.present & (@as(u64, 1) << index) != 0;
    }
};

/// One declared field, for `irregex_schema_get`. `nested` is the schema id for
/// `rows`, the enum id for `enum`, and 0 otherwise.
pub const Field = extern struct {
    name: [*:0]const u8,
    tag: u32,
    nested: u32,
    optional: i32,
    reserved: i32 = 0,
};

/// One declared row schema. `struct_size` is set by the CALLER.
pub const Schema = extern struct {
    struct_size: u32,
    id: u32,
    name: [*:0]const u8,
    nfields: u32,
    reserved: u32 = 0,
    fields: [*]const Field,
};

/// Which tier answered — the fact a warm answer is otherwise indistinguishable
/// from a cold one.
pub const Source = enum(u32) { live, atlas, shelf };

/// Answer-level facts no row can carry.
///
/// `foreign` is the load-bearing one: it counts query fingerprints the corpus
/// has NEVER seen, which is what separates "your text isn't in this repo" from
/// "no results". A binding that drops it turns the first into the second.
pub const Stats = extern struct {
    struct_size: u32,
    source: u32 = @intFromEnum(Source.live),
    elapsed_ns: u64 = 0,
    files_considered: u64 = 0,
    /// Files re-sketched into a warm answer (the atlas freshness fold).
    refreshed: u64 = 0,
    foreign: u64 = 0,
    /// Rows a budget trimmed — so a truncated answer says so.
    omitted: u64 = 0,
    rows: u64 = 0,
};

// ── the params families ─────────────────────────────────────────────────────
// Five shapes, not seventeen: a caller learns one struct per KIND of question.
// Each opens with `struct_size` and is append-only, so an unknown size fails
// closed exactly like `SearchRequest`'s — see `[analytic.params]`.

pub const an_max_distance: u32 = 1 << 0;
pub const an_min_echo: u32 = 1 << 1;
pub const an_no_index: u32 = 1 << 2;
pub const an_fixed: u32 = 1 << 3;
pub const an_ignore_case: u32 = 1 << 4;
pub const an_match_all: u32 = 1 << 5;
pub const an_by_pattern: u32 = 1 << 6;
pub const an_by_file: u32 = 1 << 7;
pub const an_distinct: u32 = 1 << 8;

pub const known_an_flags = an_max_distance | an_min_echo | an_no_index | an_fixed |
    an_ignore_case | an_match_all | an_by_pattern | an_by_file | an_distinct;

/// `similar` · `dups` · `clusters` · `echoes` · `concepts` · `fragments` ·
/// `distinct`. A null `target` is the corpus-wide sweep.
pub const KinshipParams = extern struct {
    struct_size: u32,
    flags: u32,
    target: ?[*]const u8,
    target_len: usize,
    channel: u32,
    unit: u32,
    /// Present only when `an_max_distance` is set — 0.0 is a real threshold.
    max_distance: f64,
    /// Present only when `an_min_echo` is set.
    min_echo: f64,
    min_grade: u32,
    min_size: u32,
    min_lines: u32,
    top: u32,
};

/// `recall` · `pack` · `quote` — free text priced against the corpus.
pub const RetrievalParams = extern struct {
    struct_size: u32,
    flags: u32,
    query: ?[*]const u8,
    query_len: usize,
    top: u32,
    reserved: u32 = 0,
};

/// `patterns` · `pattern_counts` — N patterns, one walk, exact attribution.
pub const SweepParams = extern struct {
    struct_size: u32,
    flags: u32,
    patterns: ?[*]const Text,
    npatterns: usize,
    under: ?[*]const u8,
    under_len: usize,
    top: u32,
    reserved: u32 = 0,
};

/// `context` · `family` · `provenance` · `blast` — an exact `PatternSet`
/// narrows the corpus and the compression kernel reasons inside it.
pub const ComposeParams = extern struct {
    struct_size: u32,
    flags: u32,
    text: ?[*]const u8,
    text_len: usize,
    patterns: ?[*]const Text,
    npatterns: usize,
    max_distance: f64,
    min_echo: f64,
    budget: u32,
    top: u32,
};

/// `rank` — the definition-first view of an exact query.
pub const RankParams = extern struct {
    struct_size: u32,
    flags: u32,
    pattern: ?[*]const u8,
    pattern_len: usize,
    top: u32,
    reserved: u32 = 0,
};

/// The host passes one of these five pointer-compatible shapes. Keeping the
/// family typed at the Zig boundary avoids recovering it from `anyopaque`.
pub const Params = extern union {
    kinship: KinshipParams,
    retrieval: RetrievalParams,
    sweep: SweepParams,
    compose: ComposeParams,
    rank: RankParams,
};

/// Validate one typed params family. An unknown `struct_size` or unassigned
/// flag bit is `.invalid` (fail closed), never partially interpreted.
pub fn params(comptime T: type, p: *const T) ?*const T {
    if (p.struct_size != @sizeOf(T)) return null;
    if (p.flags & ~known_an_flags != 0) return null;
    return p;
}

// ── the schema table, as the C ABI sees it ─────────────────────────────────

/// A sha256 over the canonical table. A binding compares its own generated
/// constant to this at load, so a stale shared library is a loud failure rather
/// than a silently mis-decoded row.
pub fn digest() [*:0]const u8 {
    return table.digest;
}

pub fn schemaCount() u32 {
    return @intCast(table.schemas.len);
}

/// Fill `out` with schema `id` (1-based). `.invalid` for an unknown id or a
/// null / wrongly-sized `out`; the strings and field arrays are static and
/// outlive every call.
pub fn schemaGet(id: u32, out: ?*Schema) Status {
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(Schema)) return .invalid;
    if (id == 0 or id > table.schemas.len) return .invalid;
    slot.* = table.schemas[id - 1];
    return .ok;
}

// ── the builder ─────────────────────────────────────────────────────────────

/// Assembles rows into one arena, checked against the generated schema.
///
/// The point of the check is that a dispatch arm cannot emit a row the
/// bindings' decoders would mis-read: `begin` looks the schema up, and every
/// `set`/`skip` advances one field, so a mismatched arity or a value written
/// with the wrong tag is caught HERE — in the one place that knows both the
/// declaration and the kernel value — rather than three languages downstream.
///
/// Assertions rather than errors on purpose: a wrong tag is a bug in this
/// repository's own dispatch, not a condition a host can provoke or recover
/// from, and the alternative is threading an error through every arm for a
/// case that must never ship.
pub const Builder = struct {
    arena: std.mem.Allocator,
    schema: *const Schema,
    values: []Value,
    present: u64 = 0,
    cursor: u32 = 0,

    /// Start a row of `id`. Fields are then written in declaration order.
    pub fn begin(arena: std.mem.Allocator, id: table.Id) !Builder {
        const schema = &table.schemas[@intFromEnum(id) - 1];
        return .{
            .arena = arena,
            .schema = schema,
            .values = try arena.alloc(Value, schema.nfields),
        };
    }

    /// Write the next declared field. The value's tag must match what the
    /// contract declared for it.
    pub fn set(self: *Builder, v: Value) void {
        std.debug.assert(self.cursor < self.schema.nfields);
        std.debug.assert(v.tag == self.schema.fields[self.cursor].tag);
        self.values[self.cursor] = v;
        self.present |= @as(u64, 1) << @intCast(self.cursor);
        self.cursor += 1;
    }

    /// Leave the next declared field ABSENT — which the contract must have
    /// marked `optional`, since a required field has no absent state.
    pub fn skip(self: *Builder) void {
        std.debug.assert(self.cursor < self.schema.nfields);
        std.debug.assert(self.schema.fields[self.cursor].optional != 0);
        self.values[self.cursor] = .{ .tag = self.schema.fields[self.cursor].tag };
        self.cursor += 1;
    }

    /// Write `v` when non-null, else leave the field absent.
    pub fn maybe(self: *Builder, v: ?Value) void {
        if (v) |value| self.set(value) else self.skip();
    }

    /// Seal the row. Every declared field must have been written or skipped.
    pub fn end(self: *Builder) Row {
        std.debug.assert(self.cursor == self.schema.nfields);
        return .{
            .schema_id = self.schema.id,
            .nvalues = self.schema.nfields,
            .present = self.present,
            .values = self.values.ptr,
        };
    }
};

/// Copy `s` into the arena — for a kernel value whose own storage does not
/// outlive the pull that produced it.
pub fn dupe(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return arena.dupe(u8, s);
}

/// Build a `texts` payload from owned slices already living in the arena.
pub fn textList(arena: std.mem.Allocator, items: []const []const u8) ![]Text {
    const out = try arena.alloc(Text, items.len);
    for (out, items) |*slot, s| slot.* = Text.of(s);
    return out;
}

test "the wire layout matches include/irregex.h byte for byte" {
    const t = std.testing;
    // Three bindings decode these by offset. A silent size change here is a
    // mis-read field in Python, Rust, and Go simultaneously — and nothing else
    // in the build would catch it, because each side compiles fine alone. The
    // numbers are the ones `cc -std=c11` reports for the header's structs.
    try t.expectEqual(@as(usize, 16), @sizeOf(Text));
    try t.expectEqual(@as(usize, 40), @sizeOf(Value));
    try t.expectEqual(@as(usize, 24), @sizeOf(Row));
    try t.expectEqual(@as(usize, 24), @sizeOf(Field));
    try t.expectEqual(@as(usize, 32), @sizeOf(Schema));
    try t.expectEqual(@as(usize, 56), @sizeOf(Stats));
    try t.expectEqual(@as(usize, 64), @sizeOf(KinshipParams));
    try t.expectEqual(@as(usize, 32), @sizeOf(RetrievalParams));
    try t.expectEqual(@as(usize, 48), @sizeOf(SweepParams));
    try t.expectEqual(@as(usize, 64), @sizeOf(ComposeParams));
    try t.expectEqual(@as(usize, 32), @sizeOf(RankParams));

    // The payload offsets a decoder reads directly, rather than only the total.
    try t.expectEqual(@as(usize, 8), @offsetOf(Value, "integer"));
    try t.expectEqual(@as(usize, 16), @offsetOf(Value, "real"));
    try t.expectEqual(@as(usize, 24), @offsetOf(Value, "ptr"));
    try t.expectEqual(@as(usize, 32), @offsetOf(Value, "len"));
    try t.expectEqual(@as(usize, 8), @offsetOf(Row, "present"));
    try t.expectEqual(@as(usize, 16), @offsetOf(Row, "values"));
}

test "the generated table is self-consistent and reachable through the C accessors" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 22), schemaCount());
    try t.expectEqual(@as(usize, 17), table.verbs.len);

    // Ids are the wire discriminant: `schemas[i]` MUST be id i+1, or every
    // `schemaGet` and every `Builder.begin` indexes the wrong declaration.
    for (table.schemas, 1..) |s, want| try t.expectEqual(@as(u32, @intCast(want)), s.id);
    for (table.verbs, 1..) |v, want| try t.expectEqual(@as(u32, @intCast(want)), @intFromEnum(v.op));

    var out: Schema = undefined;
    out.struct_size = @sizeOf(Schema);
    try t.expectEqual(Status.ok, schemaGet(@intFromEnum(table.Id.similar), &out));
    try t.expectEqualStrings("similar", std.mem.span(out.name));
    try t.expectEqual(@as(u32, 4), out.nfields);
    try t.expectEqualStrings("distance", std.mem.span(out.fields[1].name));
    try t.expectEqual(@intFromEnum(table.Tag.f64), out.fields[1].tag);
    // `grade` is an enum field, so it must carry the enum id that lets a
    // binding resolve the ordinal to a label.
    try t.expectEqual(@intFromEnum(table.Tag.@"enum"), out.fields[2].tag);
    try t.expect(out.fields[2].nested != 0);

    // Fail closed, both ways.
    try t.expectEqual(Status.invalid, schemaGet(0, &out));
    try t.expectEqual(Status.invalid, schemaGet(schemaCount() + 1, &out));
    try t.expectEqual(Status.invalid, schemaGet(1, null));
    out.struct_size = 0;
    try t.expectEqual(Status.invalid, schemaGet(1, &out));
}

test "every nested reference resolves, and only optional fields can be absent" {
    const t = std.testing;
    for (table.schemas) |s| {
        for (s.fields[0..s.nfields]) |f| {
            if (f.tag == @intFromEnum(table.Tag.rows)) {
                try t.expect(f.nested >= 1 and f.nested <= table.schemas.len);
            } else if (f.tag == @intFromEnum(table.Tag.@"enum")) {
                try t.expect(f.nested != 0);
            } else {
                try t.expectEqual(@as(u32, 0), f.nested);
            }
        }
        // The presence mask is one u64; a schema past 64 fields would silently
        // lose its tail.
        try t.expect(s.nfields <= 64);
    }
}

test "a built row round-trips its values, and absence is not zero" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = try Builder.begin(arena, .similar);
    b.set(Value.text("pkg/kernels/irregex/src/root.zig"));
    b.set(Value.float(0.0)); // identical — the value a sentinel would swallow
    b.set(Value.ordinal(table.Grade.identical));
    b.set(Value.ordinal(table.Channel.copies));
    const row = b.end();

    try t.expectEqual(@intFromEnum(table.Id.similar), row.schema_id);
    try t.expectEqual(@as(u32, 4), row.nvalues);
    try t.expectEqualStrings("pkg/kernels/irregex/src/root.zig", row.values[0].ptr.text.?[0..row.values[0].len]);
    try t.expectEqual(@as(f64, 0.0), row.values[1].real);
    try t.expectEqual(@intFromEnum(table.Grade.identical), row.values[2].integer);
    for (0..4) |i| try t.expect(row.has(@intCast(i)));

    // `region.headline` is optional: skipped, the field reads as absent while
    // its neighbors stay present — the distinction a zero cannot make.
    var r = try Builder.begin(arena, .region);
    r.set(Value.text("a.zig"));
    r.set(Value.int(10));
    r.set(Value.int(20));
    r.skip();
    const region = r.end();
    try t.expect(region.has(0) and region.has(1) and region.has(2));
    try t.expect(!region.has(3));
}

test "nested rows and text lists carry through one arena" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = try Builder.begin(arena, .region);
    m.set(Value.text("x.zig"));
    m.set(Value.int(1));
    m.set(Value.int(9));
    m.set(Value.text("fn parse()"));
    const members = try arena.dupe(Row, &.{m.end()});

    var f = try Builder.begin(arena, .family);
    f.set(Value.int(1));
    f.set(Value.ordinal(table.Unit.function));
    f.set(Value.ordinal(table.Channel.shapes));
    f.set(Value.float(0.12));
    f.set(Value.int(9));
    f.set(Value.float(3.5));
    f.set(Value.nested(members));
    const family = f.end();

    const nested_ptr = family.values[6].ptr.rows.?;
    try t.expectEqual(@as(usize, 1), family.values[6].len);
    try t.expectEqual(@intFromEnum(table.Id.region), nested_ptr[0].schema_id);

    const list = try textList(arena, &.{ "a", "bb" });
    const v = Value.texts(list);
    try t.expectEqual(@as(usize, 2), v.len);
    try t.expectEqualStrings("bb", list[1].slice());
}

test "params narrowing fails closed on size and on an unassigned flag bit" {
    const t = std.testing;
    var p = KinshipParams{
        .struct_size = @sizeOf(KinshipParams),
        .flags = an_max_distance,
        .target = null,
        .target_len = 0,
        .channel = 0,
        .unit = 0,
        .max_distance = 0.25,
        .min_echo = 0,
        .min_grade = 0,
        .min_size = 0,
        .min_lines = 0,
        .top = 10,
    };
    try t.expect(params(KinshipParams, &p) != null);

    p.struct_size = @sizeOf(KinshipParams) - 4; // an older/newer caller's shape
    try t.expect(params(KinshipParams, &p) == null);

    p.struct_size = @sizeOf(KinshipParams);
    p.flags = 1 << 31; // a bit this build has never assigned
    try t.expect(params(KinshipParams, &p) == null);
}
