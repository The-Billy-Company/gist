//! gist build graph — the product chassis of the irregex ecosystem.
//!
//! Ships the two search binaries (`gist` · `relate`), the session-shaped
//! C-ABI dual artifact (`libirregex.a` + `libirregex.{dylib,so}` +
//! `include/irregex.h` — the ABI the Python/Go/Rust bindings dlopen/link),
//! and the `gist` **module** (`@import("gist")`) the `blast` package rides
//! for its CLI chassis. The engines are sibling-path deps: `irregex` (the
//! exact library, carrying the PCRE2 floor) and `relate` (compression
//! kinship, carrying libsais).
//!
//! Product executables default to ReleaseFast via `-Doptimize=`; the test
//! chassis mirrors the library's (kernelkit's shape): ReleaseSafe
//! brigade-sharded `test`, compile-only `check`, kcov `coverage`.

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (builtin.target.os.tag == .macos)
        .{ .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    // The engines beneath, at matching optimize. Each module carries its own
    // C floor (PCRE2 under irregex, libsais under relate), so linking these
    // links the whole stack.
    const deps = engines(b, target, optimize);

    // ── the chassis module (`@import("gist")` — what `blast` rides) ──
    const chassis = b.addModule("gist", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &deps,
    });

    // ── the product binaries ──
    // The CLIs are the product surface — the on-PATH binaries whose entire
    // reason to exist is out-running ripgrep. A Debug build is 4–8× slower and
    // reads to a caller like a hang, so the faces (and the chassis + engines
    // they link, where the hot loops live) default to ReleaseFast regardless
    // of the build-wide `-Doptimize` — a bare `zig build` must never install
    // a slow debug `gist`. `-Dcli-optimize=Debug` still yields a debug CLI for
    // engine debugging; tests / coverage / the C-ABI libs keep the standard
    // (safety-checked, DWARF-carrying) default optimize untouched.
    const cli_optimize = b.option(
        std.builtin.OptimizeMode,
        "cli-optimize",
        "optimize mode for the installed CLIs (default ReleaseFast — the product surface's whole point is speed)",
    ) orelse .ReleaseFast;
    const cli_chassis = if (cli_optimize == optimize) chassis else b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = cli_optimize,
        .pic = true,
        .imports = &engines(b, target, cli_optimize),
    });
    const faces = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "gist", .source = "src/surface/face/gist/main.zig" },
        .{ .name = "relate", .source = "src/surface/face/relate/main.zig" },
    };
    for (faces) |face| {
        // A face main is a thin exe root: real driver code is analyzed inside
        // the chassis module (whose root is src/root.zig, so relative imports
        // resolve) and reached as `@import("gist").faces.*`.
        const exe = b.addExecutable(.{
            .name = face.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(face.source),
                .target = target,
                .optimize = cli_optimize,
                .imports = &(engines(b, target, cli_optimize) ++
                    [_]std.Build.Module.Import{.{ .name = "gist", .module = cli_chassis }}),
            }),
        });
        b.installArtifact(exe);
    }

    // ── the C-ABI dual artifact (kernelkit's shape, stated here because the
    // chassis module needs its engine imports) ──
    // Dynamic lib (Python cffi dlopen); owns the header install. Named
    // `irregex` — the ABI's symbols and header carry the ecosystem's name,
    // and the bindings dlopen `libirregex` regardless of which package hosts
    // the export shims.
    const dynamic_lib = b.addLibrary(.{ .name = "irregex", .linkage = .dynamic, .root_module = chassis });
    dynamic_lib.installHeader(b.path("include/irregex.h"), "irregex.h");
    b.installArtifact(dynamic_lib);
    // Static lib (Go cgo / Rust build.rs). Zig's archiver leaves Mach-O
    // members non-8-byte-aligned, which Apple's ld64 rejects in a cgo link;
    // re-archive with `libtool -static` on macOS. Linux/LLD tolerates it.
    if (target.result.os.tag == .macos) {
        const obj = b.addObject(.{ .name = "irregex", .root_module = chassis });
        const repack = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
        const aligned_a = repack.addOutputFileArg("libirregex.a");
        repack.addArtifactArg(obj);
        b.getInstallStep().dependOn(&b.addInstallLibFile(aligned_a, "libirregex.a").step);
    } else {
        const static_lib = b.addLibrary(.{ .name = "irregex", .linkage = .static, .root_module = chassis });
        b.installArtifact(static_lib);
    }

    // ── the test chassis ──
    const test_optimize = b.option(
        std.builtin.OptimizeMode,
        "test-optimize",
        "optimize mode for the unit-test binary (default ReleaseSafe)",
    ) orelse .ReleaseSafe;
    const test_module = if (test_optimize == optimize) chassis else b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = test_optimize,
        .pic = true,
        .imports = &engines(b, target, test_optimize),
    });

    const shards = b.option(
        usize,
        "test-shards",
        "how many parallel processes `zig build test` splits the unit-test binary across (default: 2x CPU count; 1 restores a single-process run)",
    ) orelse @min(@max(std.Thread.getCpuCount() catch 1, 1) * 2, 64);
    const brigade = b.dependency("kernelkit", .{}).path("brigade.zig");
    const tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = .{ .path = brigade, .mode = .simple },
    });
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "run only unit tests whose name contains one of these comma-separated substrings",
    );
    const test_skip = b.option(
        []const u8,
        "test-skip",
        "skip unit tests whose name contains one of these comma-separated substrings",
    );

    const test_step = b.step("test", "Run unit tests");
    addShards(b, tests, test_step, shards, test_filter, test_skip);

    const debug_tests = if (test_module == chassis) tests else b.addTest(.{
        .root_module = chassis,
        .test_runner = .{ .path = brigade, .mode = .simple },
    });
    b.step("check", "Compile tests without running (fast --watch -fincremental loop / ZLS)")
        .dependOn(&debug_tests.step);

    const run_cov = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=src/" });
    run_cov.addArg(b.pathFromRoot(".local/coverage"));
    run_cov.addArtifactArg(debug_tests);
    run_cov.setEnvironmentVariable("BRIGADE_SHARD", "0/1");
    b.step("coverage", "Run unit tests under kcov → .local/coverage/ (Cobertura XML)")
        .dependOn(&run_cov.step);
}

/// The two engine module imports at a given optimize, in the order every
/// module here declares them.
fn engines(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) [2]std.Build.Module.Import {
    return .{
        .{ .name = "irregex", .module = b.dependency("irregex", .{ .target = target, .optimize = optimize }).module("irregex") },
        .{ .name = "relate", .module = b.dependency("relate", .{ .target = target, .optimize = optimize }).module("relate") },
    };
}

/// kernelkit's shard fan-out, restated because this build declares no C-ABI
/// kernel through `addKernel` (see _buildkit/build.zig `addShards`).
fn addShards(
    b: *std.Build,
    tests: *std.Build.Step.Compile,
    step: *std.Build.Step,
    shards: usize,
    filter: ?[]const u8,
    skip: ?[]const u8,
) void {
    for (0..shards) |i| {
        const run_shard = b.addRunArtifact(tests);
        run_shard.setEnvironmentVariable("BRIGADE_SHARD", b.fmt("{d}/{d}", .{ i, shards }));
        if (filter) |f| run_shard.setEnvironmentVariable("BRIGADE_FILTER", f);
        if (skip) |s| run_shard.setEnvironmentVariable("BRIGADE_SKIP", s);
        run_shard.expectExitCode(0);
        run_shard.setName(b.fmt("{s} shard {d}/{d}", .{ step.name, i, shards }));
        step.dependOn(&run_shard.step);
    }
}
