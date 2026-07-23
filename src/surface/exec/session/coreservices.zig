//! gist resident session — the macOS watch frameworks, bound at runtime (ADR-352 rung 2.5).
//!
//! The CoreServices (FSEvents) + CoreFoundation (CFRunLoop) surface the macOS
//! watcher drives, resolved at RUNTIME through `std.DynLib` instead of linked
//! into the binary. Link-time framework loading runs the CoreFoundation + ObjC
//! image initializers on EVERY process launch (~0.9 ms measured, ~1.8× a bare
//! exe's startup) — a tax the cold one-shot search (`gist <pat>`, the product's
//! whole reason to out-run ripgrep) would pay for an accelerator only the
//! resident daemon ever arms. Loading on demand keeps the frameworks out of the
//! cold binary's load commands entirely, so a search pays zero for the watcher.
//! Fail-closed by construction: a `dlopen`/`dlsym` miss (or any non-macOS
//! target) leaves `syms` null → the session is never armed → every query
//! reconciles (correct, just not fast), the exact contract a missing backend
//! already carried. `watch.zig` owns the event loop + drop/flood policy that
//! *use* these symbols; this module only resolves them.

const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

pub const Ref = ?*anyopaque;
pub const CFIndex = isize;
pub const kCFStringEncodingUTF8: u32 = 0x0800_0100;
pub const kFSEventStreamEventIdSinceNow: u64 = 0xFFFF_FFFF_FFFF_FFFF;
// NoDefer: deliver the first event immediately, then coalesce at `fsevents_latency`.
pub const kFSEventStreamCreateFlagNoDefer: u32 = 0x0000_0002;
// FileEvents: report the changed ITEM's own path (file or dir) instead of its
// parent directory — the exact dirty set the scoped reconcile needs.
pub const kFSEventStreamCreateFlagFileEvents: u32 = 0x0000_0010;

// FSEvents delivers `info` as an opaque pointer (the session, type-erased so the
// symbol table stays generic-free); `fseventsCallback` casts it back to its
// concrete `*Session`. The retaining `kCFTypeArrayCallBacks` lets the paths
// array own the CFString roots, so the loop drops its own references at once and
// the stream copies the list on create.
pub const FsCallback = *const fn (Ref, ?*anyopaque, usize, ?[*]const [*:0]const u8, [*]const u32, [*]const u64) callconv(.c) void;

pub const CFContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
};

/// The dlopen'd CoreFoundation + CoreServices entry points, bound once when a
/// macOS session arms its watcher. Session-independent (the callback's `info` is
/// `?*anyopaque`), so it lives at module scope and off-macOS is simply never
/// populated — the field type stays valid on every target.
pub const Syms = struct {
    cf: std.DynLib,
    cs: std.DynLib,
    CFStringCreateWithBytes: *const fn (Ref, [*]const u8, CFIndex, u32, u8) callconv(.c) Ref,
    CFArrayCreate: *const fn (Ref, [*]const Ref, CFIndex, ?*const anyopaque) callconv(.c) Ref,
    CFRelease: *const fn (Ref) callconv(.c) void,
    CFRunLoopGetCurrent: *const fn () callconv(.c) Ref,
    CFRunLoopRunInMode: *const fn (Ref, f64, u8) callconv(.c) i32,
    CFRunLoopStop: *const fn (Ref) callconv(.c) void,
    FSEventStreamCreate: *const fn (Ref, FsCallback, ?*const CFContext, Ref, u64, f64, u32) callconv(.c) Ref,
    FSEventStreamScheduleWithRunLoop: *const fn (Ref, Ref, Ref) callconv(.c) void,
    FSEventStreamStart: *const fn (Ref) callconv(.c) u8,
    FSEventStreamStop: *const fn (Ref) callconv(.c) void,
    FSEventStreamInvalidate: *const fn (Ref) callconv(.c) void,
    FSEventStreamRelease: *const fn (Ref) callconv(.c) void,
    run_loop_default_mode: Ref,
    array_callbacks: ?*const anyopaque,

    const cf_path = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    const cs_path = "/System/Library/Frameworks/CoreServices.framework/CoreServices";

    /// Open both frameworks and bind every symbol, or null on the first miss
    /// (closing whatever opened). CoreFoundation carries the CF functions + the
    /// two data symbols; CoreServices carries FSEvents.
    pub fn load() ?Syms {
        if (comptime !is_macos) return null;
        var cf = std.DynLib.open(cf_path) catch return null;
        var cs = std.DynLib.open(cs_path) catch {
            cf.close();
            return null;
        };
        var s: Syms = undefined;
        s.cf = cf;
        s.cs = cs;
        s.CFStringCreateWithBytes = cf.lookup(@TypeOf(s.CFStringCreateWithBytes), "CFStringCreateWithBytes") orelse return s.fail();
        s.CFArrayCreate = cf.lookup(@TypeOf(s.CFArrayCreate), "CFArrayCreate") orelse return s.fail();
        s.CFRelease = cf.lookup(@TypeOf(s.CFRelease), "CFRelease") orelse return s.fail();
        s.CFRunLoopGetCurrent = cf.lookup(@TypeOf(s.CFRunLoopGetCurrent), "CFRunLoopGetCurrent") orelse return s.fail();
        s.CFRunLoopRunInMode = cf.lookup(@TypeOf(s.CFRunLoopRunInMode), "CFRunLoopRunInMode") orelse return s.fail();
        s.CFRunLoopStop = cf.lookup(@TypeOf(s.CFRunLoopStop), "CFRunLoopStop") orelse return s.fail();
        // Data symbols: `lookup` returns the symbol's address. `kCFRunLoopDefaultMode`
        // is a CFStringRef *variable* → deref to the value; `kCFTypeArrayCallBacks`
        // is the callbacks struct → its address is what CFArrayCreate wants.
        s.run_loop_default_mode = (cf.lookup(*Ref, "kCFRunLoopDefaultMode") orelse return s.fail()).*;
        s.array_callbacks = cf.lookup(*const anyopaque, "kCFTypeArrayCallBacks") orelse return s.fail();
        s.FSEventStreamCreate = cs.lookup(@TypeOf(s.FSEventStreamCreate), "FSEventStreamCreate") orelse return s.fail();
        s.FSEventStreamScheduleWithRunLoop = cs.lookup(@TypeOf(s.FSEventStreamScheduleWithRunLoop), "FSEventStreamScheduleWithRunLoop") orelse return s.fail();
        s.FSEventStreamStart = cs.lookup(@TypeOf(s.FSEventStreamStart), "FSEventStreamStart") orelse return s.fail();
        s.FSEventStreamStop = cs.lookup(@TypeOf(s.FSEventStreamStop), "FSEventStreamStop") orelse return s.fail();
        s.FSEventStreamInvalidate = cs.lookup(@TypeOf(s.FSEventStreamInvalidate), "FSEventStreamInvalidate") orelse return s.fail();
        s.FSEventStreamRelease = cs.lookup(@TypeOf(s.FSEventStreamRelease), "FSEventStreamRelease") orelse return s.fail();
        return s;
    }

    /// A partial resolve must never half-arm the watcher: close both handles and
    /// report the miss as null so the session stays in the reconcile-always base.
    fn fail(s: *Syms) ?Syms {
        s.close();
        return null;
    }

    pub fn close(s: *Syms) void {
        s.cf.close();
        s.cs.close();
    }
};

/// Wall-clock nanoseconds off the raw libc clock — the FSEvents callback thread
/// has no `std.Io` handle, and the annals compare against `base.ns` instants
/// minted from the SAME realtime clock. Null on failure (callers degrade to
/// doubt/uncovered, never to a guessed instant).
pub fn wallNowNs() ?i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
