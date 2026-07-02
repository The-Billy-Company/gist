//! gist bench — cross-OS hardware performance-counter reader (Layer A of the
//! optimality certificate). The macroscopic race proves gist is *fastest in its
//! class*; this proves *why*, microscopically: retired **cycles** and
//! **instructions** per byte for the single-threaded hot kernel, the number that
//! later meets the roofline (Layer C) and the static port-pressure bound
//! (Layer B). Wall-clock measures the noisy box; the PMU measures the work.
//!
//! Two backends behind one `Meter`:
//!   * **macOS / Apple Silicon** — Apple's private `kperf`/`kperfdata`
//!     frameworks, `dlopen`'d at runtime (the same path Instruments uses; see
//!     ibireme's `kpc_demo`). FIXED_CYCLES + FIXED_INSTRUCTIONS via the
//!     thread-counter API. **Requires root/`sudo`** (xnu gates `kpc`); without
//!     it the userspace cycle register `PMCCNTR_EL0` is trapped, so there is no
//!     non-root cycle count on Apple Silicon.
//!   * **everything else** — `has_pmu = false`; `counters()` returns zero and the
//!     caller falls back to its monotonic `std.time.Timer` (ns/byte). The Linux
//!     `perf_event_open` backend lands in pass 2 (see `linuxInit`).
//!
//! Design rule: **never fail the run.** If the PMU can't be opened (not root,
//! not macOS, framework missing) `init` degrades to wall-clock and reports it.
//! kperf is driven purely through opaque pointers + dlsym'd C functions — no
//! reverse-engineered struct layouts — so it can't silently read garbage.

const std = @import("std");
const builtin = @import("builtin");

/// One read of the per-thread counter file. `valid=false` ⇒ wall-clock only.
pub const Counters = struct {
    cycles: u64 = 0,
    instructions: u64 = 0,
    valid: bool = false,
};

pub const Meter = struct {
    has_pmu: bool = false,
    note: []const u8 = "wall-clock only (no PMU)",
    backend: Backend = .{ .none = {} },

    const Backend = union(enum) {
        none: void,
        kperf: KPerf,
    };

    /// Try the platform PMU; on any failure degrade to wall-clock. Never errors.
    pub fn init() Meter {
        if (builtin.target.os.tag == .macos) {
            if (KPerf.open()) |k| {
                return .{ .has_pmu = true, .note = k.note, .backend = .{ .kperf = k } };
            } else |_| {
                return .{ .note = "wall-clock only (kperf needs sudo; run under root for cycles)" };
            }
        }
        // Linux perf_event_open backend: pass 2.
        return .{};
    }

    pub fn deinit(self: *Meter) void {
        switch (self.backend) {
            .kperf => |*k| k.close(),
            .none => {},
        }
    }

    /// Snapshot the calling thread's accumulated counters. Take one before and
    /// one after the measured region; the delta is the region's cost. Reads the
    /// **current thread only**, so the measured kernel must be single-threaded
    /// (a parallel fan-out would leak cycles onto unmeasured workers).
    pub fn counters(self: *Meter) Counters {
        return switch (self.backend) {
            .kperf => |*k| k.read(),
            .none => .{},
        };
    }
};

// ── macOS kperf/kperfdata backend ────────────────────────────────────────────

const KPC_MAX_COUNTERS = 32;
const KPC_CLASS_CONFIGURABLE_MASK: u32 = 1 << 1;

const KPerf = struct {
    kperf: std.DynLib,
    kperfdata: std.DynLib,
    classes: u32,
    counter_map: [KPC_MAX_COUNTERS]usize, // event index → thread-counter slot
    note: []const u8,

    // kperf (the counting engine; root-gated)
    force_get: *const fn (*c_int) callconv(.c) c_int,
    force_set: *const fn (c_int) callconv(.c) c_int,
    set_config: *const fn (u32, [*]u64) callconv(.c) c_int,
    set_counting: *const fn (u32) callconv(.c) c_int,
    set_thread_counting: *const fn (u32) callconv(.c) c_int,
    get_thread_counters: *const fn (u32, u32, [*]u64) callconv(.c) c_int,

    const kperf_path = "/System/Library/PrivateFrameworks/kperf.framework/kperf";
    const kperfdata_path = "/System/Library/PrivateFrameworks/kperfdata.framework/kperfdata";

    // cycles + instructions, each with Apple-Silicon fixed-counter names first
    // then Intel-Mac / alias fallbacks, so the same binary works across chips.
    const cycle_names = [_][:0]const u8{ "FIXED_CYCLES", "CPU_CLK_UNHALTED.THREAD", "Cycles", "cycles" };
    const inst_names = [_][:0]const u8{ "FIXED_INSTRUCTIONS", "INST_RETIRED.ANY", "Instructions", "instructions" };

    fn open() !KPerf {
        var kperf = try std.DynLib.open(kperf_path);
        errdefer kperf.close();
        var kperfdata = try std.DynLib.open(kperfdata_path);
        errdefer kperfdata.close();

        var self: KPerf = undefined;
        self.kperf = kperf;
        self.kperfdata = kperfdata;
        self.counter_map = std.mem.zeroes([KPC_MAX_COUNTERS]usize);

        self.force_get = kperf.lookup(@TypeOf(self.force_get), "kpc_force_all_ctrs_get") orelse return error.SymbolMissing;
        self.force_set = kperf.lookup(@TypeOf(self.force_set), "kpc_force_all_ctrs_set") orelse return error.SymbolMissing;
        self.set_config = kperf.lookup(@TypeOf(self.set_config), "kpc_set_config") orelse return error.SymbolMissing;
        self.set_counting = kperf.lookup(@TypeOf(self.set_counting), "kpc_set_counting") orelse return error.SymbolMissing;
        self.set_thread_counting = kperf.lookup(@TypeOf(self.set_thread_counting), "kpc_set_thread_counting") orelse return error.SymbolMissing;
        self.get_thread_counters = kperf.lookup(@TypeOf(self.get_thread_counters), "kpc_get_thread_counters") orelse return error.SymbolMissing;

        // Permission gate: force_all_ctrs_get fails (non-zero) without root.
        var force: c_int = 0;
        if (self.force_get(&force) != 0) return error.PermissionDenied;

        try self.configure();
        self.note = "kperf · FIXED_CYCLES + FIXED_INSTRUCTIONS (root)";
        return self;
    }

    // kpep dance: build a config from the cycle+instruction events, derive the
    // kpc class mask + register set + event→counter map, push it to the kernel,
    // and start per-thread counting. All pointers stay opaque.
    fn configure(self: *KPerf) !void {
        const data = &self.kperfdata;
        const Opaque = ?*anyopaque;
        const db_create = data.lookup(*const fn (?[*:0]const u8, *Opaque) callconv(.c) c_int, "kpep_db_create") orelse return error.SymbolMissing;
        const cfg_create = data.lookup(*const fn (Opaque, *Opaque) callconv(.c) c_int, "kpep_config_create") orelse return error.SymbolMissing;
        const cfg_force = data.lookup(*const fn (Opaque) callconv(.c) c_int, "kpep_config_force_counters") orelse return error.SymbolMissing;
        const db_event = data.lookup(*const fn (Opaque, [*:0]const u8, *Opaque) callconv(.c) c_int, "kpep_db_event") orelse return error.SymbolMissing;
        const cfg_add = data.lookup(*const fn (Opaque, *Opaque, u32, ?*u32) callconv(.c) c_int, "kpep_config_add_event") orelse return error.SymbolMissing;
        const cfg_classes = data.lookup(*const fn (Opaque, *u32) callconv(.c) c_int, "kpep_config_kpc_classes") orelse return error.SymbolMissing;
        const cfg_count = data.lookup(*const fn (Opaque, *usize) callconv(.c) c_int, "kpep_config_kpc_count") orelse return error.SymbolMissing;
        const cfg_map = data.lookup(*const fn (Opaque, [*]usize, usize) callconv(.c) c_int, "kpep_config_kpc_map") orelse return error.SymbolMissing;
        const cfg_regs = data.lookup(*const fn (Opaque, [*]u64, usize) callconv(.c) c_int, "kpep_config_kpc") orelse return error.SymbolMissing;

        var db: Opaque = null;
        if (db_create(null, &db) != 0) return error.DbCreate;
        var cfg: Opaque = null;
        if (cfg_create(db, &cfg) != 0) return error.CfgCreate;
        if (cfg_force(cfg) != 0) return error.ForceCounters;

        try addEvent(db, cfg, db_event, cfg_add, &cycle_names);
        try addEvent(db, cfg, db_event, cfg_add, &inst_names);

        if (cfg_classes(cfg, &self.classes) != 0) return error.KpcClasses;
        var reg_count: usize = 0;
        if (cfg_count(cfg, &reg_count) != 0) return error.KpcCount;
        if (cfg_map(cfg, &self.counter_map, @sizeOf(@TypeOf(self.counter_map))) != 0) return error.KpcMap;

        var regs: [KPC_MAX_COUNTERS]u64 = std.mem.zeroes([KPC_MAX_COUNTERS]u64);
        if (cfg_regs(cfg, &regs, @sizeOf(@TypeOf(regs))) != 0) return error.KpcRegs;

        if (self.force_set(1) != 0) return error.ForceSet;
        if ((self.classes & KPC_CLASS_CONFIGURABLE_MASK) != 0 and reg_count != 0) {
            if (self.set_config(self.classes, &regs) != 0) return error.SetConfig;
        }
        if (self.set_counting(self.classes) != 0) return error.SetCounting;
        if (self.set_thread_counting(self.classes) != 0) return error.SetThreadCounting;
    }

    fn addEvent(
        db: ?*anyopaque,
        cfg: ?*anyopaque,
        db_event: *const fn (?*anyopaque, [*:0]const u8, *?*anyopaque) callconv(.c) c_int,
        cfg_add: *const fn (?*anyopaque, *?*anyopaque, u32, ?*u32) callconv(.c) c_int,
        names: []const [:0]const u8,
    ) !void {
        for (names) |name| {
            var ev: ?*anyopaque = null;
            if (db_event(db, name.ptr, &ev) == 0 and ev != null) {
                if (cfg_add(cfg, &ev, 0, null) == 0) return;
            }
        }
        return error.EventNotFound;
    }

    fn read(self: *KPerf) Counters {
        var buf: [KPC_MAX_COUNTERS]u64 = std.mem.zeroes([KPC_MAX_COUNTERS]u64);
        if (self.get_thread_counters(0, KPC_MAX_COUNTERS, &buf) != 0) return .{};
        return .{
            .cycles = buf[self.counter_map[0]],
            .instructions = buf[self.counter_map[1]],
            .valid = true,
        };
    }

    fn close(self: *KPerf) void {
        _ = self.set_counting(0);
        _ = self.set_thread_counting(0);
        _ = self.force_set(0);
        self.kperfdata.close();
        self.kperf.close();
    }
};
