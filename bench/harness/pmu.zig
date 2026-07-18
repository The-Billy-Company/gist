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
//!     `perf_event_open` backend lands in pass 2 (see `Meter.init`).
//!
//! Design rule: **never fail the run.** If the PMU can't be opened (not root,
//! not macOS, framework missing) `init` degrades to wall-clock and reports it.
//! kperf is driven purely through opaque pointers + dlsym'd C functions — no
//! reverse-engineered struct layouts — so it can't silently read garbage.
//!
//! The file also carries the two host-provenance primitives every certificate
//! layer stamps next to a measured number: `cpuBrand` (which silicon produced
//! it) and `requestPerformanceQos` (P-core-biased scheduling on Apple Silicon).
//! Both run strictly outside any timed window.

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

// ── host provenance (certificate stamps; never inside a timed window) ─────────

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;
extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;

/// QOS_CLASS_USER_INTERACTIVE (sys/qos.h) — the highest scheduling tier.
const qos_user_interactive: c_uint = 0x21;

/// The marketing CPU name (`machdep.cpu.brand_string`) — a measured number must
/// name the silicon that produced it. Falls back to the compile-time arch tag
/// when the sysctl is unavailable (non-macOS, or a denied read).
pub fn cpuBrand(buf: []u8) []const u8 {
    if (builtin.target.os.tag == .macos) {
        var len: usize = buf.len;
        if (sysctlbyname("machdep.cpu.brand_string", buf.ptr, &len, null, 0) == 0 and len > 0) {
            return std.mem.sliceTo(buf[0..len], 0);
        }
    }
    const tag = @tagName(builtin.target.cpu.arch);
    const n = @min(tag.len, buf.len);
    @memcpy(buf[0..n], tag[0..n]);
    return buf[0..n];
}

/// Ask the scheduler to run the calling thread at USER_INTERACTIVE QoS — on
/// Apple Silicon that biases placement onto a **P-core** (macOS exposes no
/// public hard core pin; QoS is the honest lever). Call once before measuring.
/// Returns whether the hint was accepted, so the caller can stamp it as
/// provenance rather than silently assuming a P-core.
pub fn requestPerformanceQos() bool {
    if (builtin.target.os.tag != .macos) return false;
    return pthread_set_qos_class_self_np(qos_user_interactive, 0) == 0;
}

// ── macOS kperf/kperfdata backend ────────────────────────────────────────────

const KPC_MAX_COUNTERS = 32;
const KPC_CLASS_CONFIGURABLE_MASK: u32 = 1 << 1;

/// Resolve every field of `T` from `lib` as `<prefix><field name>` — one loop
/// instead of a lookup line per symbol. Fails loud on the first missing symbol
/// (a partial resolve must never half-configure the kernel's counters).
fn resolve(comptime T: type, lib: *std.DynLib, comptime prefix: []const u8) !T {
    var t: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        @field(t, f.name) = lib.lookup(f.type, prefix ++ f.name) orelse return error.SymbolMissing;
    }
    return t;
}

const KPerf = struct {
    kperf: std.DynLib,
    kperfdata: std.DynLib,
    classes: u32,
    counter_map: [KPC_MAX_COUNTERS]usize, // event index → thread-counter slot
    note: []const u8,
    kpc: Kpc,

    const Opaque = ?*anyopaque;

    /// kperf — the counting engine (root-gated). Field names are the `kpc_`
    /// symbol suffixes; `resolve` binds them all in one loop.
    const Kpc = struct {
        force_all_ctrs_get: *const fn (*c_int) callconv(.c) c_int,
        force_all_ctrs_set: *const fn (c_int) callconv(.c) c_int,
        set_config: *const fn (u32, [*]u64) callconv(.c) c_int,
        set_counting: *const fn (u32) callconv(.c) c_int,
        set_thread_counting: *const fn (u32) callconv(.c) c_int,
        get_thread_counters: *const fn (u32, u32, [*]u64) callconv(.c) c_int,
    };

    /// kperfdata — the kpep event-database/config builder. Field names are the
    /// `kpep_` symbol suffixes. All pointers stay opaque (no struct layouts).
    const Kpep = struct {
        db_create: *const fn (?[*:0]const u8, *Opaque) callconv(.c) c_int,
        config_create: *const fn (Opaque, *Opaque) callconv(.c) c_int,
        config_force_counters: *const fn (Opaque) callconv(.c) c_int,
        db_event: *const fn (Opaque, [*:0]const u8, *Opaque) callconv(.c) c_int,
        config_add_event: *const fn (Opaque, *Opaque, u32, ?*u32) callconv(.c) c_int,
        config_kpc_classes: *const fn (Opaque, *u32) callconv(.c) c_int,
        config_kpc_count: *const fn (Opaque, *usize) callconv(.c) c_int,
        config_kpc_map: *const fn (Opaque, [*]usize, usize) callconv(.c) c_int,
        config_kpc: *const fn (Opaque, [*]u64, usize) callconv(.c) c_int,
    };

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

        var self: KPerf = .{
            .kperf = kperf,
            .kperfdata = kperfdata,
            .classes = 0,
            .counter_map = std.mem.zeroes([KPC_MAX_COUNTERS]usize),
            .note = "",
            .kpc = try resolve(Kpc, &kperf, "kpc_"),
        };

        // Permission gate: force_all_ctrs_get fails (non-zero) without root.
        var force: c_int = 0;
        if (self.kpc.force_all_ctrs_get(&force) != 0) return error.PermissionDenied;

        try self.configure();
        self.note = "kperf · FIXED_CYCLES + FIXED_INSTRUCTIONS (root)";
        return self;
    }

    // kpep dance: build a config from the cycle+instruction events, derive the
    // kpc class mask + register set + event→counter map, push it to the kernel,
    // and start per-thread counting. All pointers stay opaque.
    fn configure(self: *KPerf) !void {
        const kpep = try resolve(Kpep, &self.kperfdata, "kpep_");

        var db: Opaque = null;
        if (kpep.db_create(null, &db) != 0) return error.DbCreate;
        var cfg: Opaque = null;
        if (kpep.config_create(db, &cfg) != 0) return error.CfgCreate;
        if (kpep.config_force_counters(cfg) != 0) return error.ForceCounters;

        try addEvent(&kpep, db, cfg, &cycle_names);
        try addEvent(&kpep, db, cfg, &inst_names);

        if (kpep.config_kpc_classes(cfg, &self.classes) != 0) return error.KpcClasses;
        var reg_count: usize = 0;
        if (kpep.config_kpc_count(cfg, &reg_count) != 0) return error.KpcCount;
        if (kpep.config_kpc_map(cfg, &self.counter_map, @sizeOf(@TypeOf(self.counter_map))) != 0) return error.KpcMap;

        var regs: [KPC_MAX_COUNTERS]u64 = std.mem.zeroes([KPC_MAX_COUNTERS]u64);
        if (kpep.config_kpc(cfg, &regs, @sizeOf(@TypeOf(regs))) != 0) return error.KpcRegs;

        if (self.kpc.force_all_ctrs_set(1) != 0) return error.ForceSet;
        if ((self.classes & KPC_CLASS_CONFIGURABLE_MASK) != 0 and reg_count != 0) {
            if (self.kpc.set_config(self.classes, &regs) != 0) return error.SetConfig;
        }
        if (self.kpc.set_counting(self.classes) != 0) return error.SetCounting;
        if (self.kpc.set_thread_counting(self.classes) != 0) return error.SetThreadCounting;
    }

    /// Register the first event name the kpep database recognizes (Apple-Silicon
    /// fixed-counter name first, then Intel/alias fallbacks).
    fn addEvent(kpep: *const Kpep, db: Opaque, cfg: Opaque, names: []const [:0]const u8) !void {
        for (names) |name| {
            var ev: Opaque = null;
            if (kpep.db_event(db, name.ptr, &ev) == 0 and ev != null) {
                if (kpep.config_add_event(cfg, &ev, 0, null) == 0) return;
            }
        }
        return error.EventNotFound;
    }

    fn read(self: *KPerf) Counters {
        var buf: [KPC_MAX_COUNTERS]u64 = std.mem.zeroes([KPC_MAX_COUNTERS]u64);
        if (self.kpc.get_thread_counters(0, KPC_MAX_COUNTERS, &buf) != 0) return .{};
        return .{
            .cycles = buf[self.counter_map[0]],
            .instructions = buf[self.counter_map[1]],
            .valid = true,
        };
    }

    fn close(self: *KPerf) void {
        _ = self.kpc.set_counting(0);
        _ = self.kpc.set_thread_counting(0);
        _ = self.kpc.force_all_ctrs_set(0);
        self.kperfdata.close();
        self.kperf.close();
    }
};
