//! gist build graph — the product chassis of the irregex ecosystem.
//!
//! Ships the `gist` search binary, the session-shaped C-ABI dual artifact
//! (`libgist.a` + `libgist.{dylib,so}` + `include/gist.h`), and the `gist`
//! **module** (`@import("gist")`) that `relate` and `blast` ride for the
//! resident daemon and answer keep. The exact engine is a sibling-path dep
//! (`irregex`, carrying the PCRE2 floor and `libirregex`). `libgist`
//! dynamically links `libirregex` for the substrate symbols it no longer
//! exports. The `relate` binary lives in the `relate` package.
//!
//! Product executables default to ReleaseFast via `-Doptimize=`; the test
//! chassis mirrors the engine's: ReleaseSafe
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

    // The engine beneath, at matching optimize. Its module carries the PCRE2
    // floor, so linking this links the whole exact-search stack.
    const irregex_dep = b.dependency("irregex", .{ .target = target, .optimize = optimize });
    const deps = [_]std.Build.Module.Import{
        .{ .name = "irregex", .module = irregex_dep.module("irregex") },
    };

    // ── the chassis module (`@import("gist")` — what `relate` and `blast` ride) ──
    const chassis = b.addModule("gist", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &deps,
    });

    // ── the product binary ──
    // The CLI is the product surface — the on-PATH binary whose entire reason
    // to exist is out-running ripgrep. A Debug build is 4–8× slower and reads
    // to a caller like a hang, so the face (and the chassis + engine it links,
    // where the hot loops live) defaults to ReleaseFast regardless of the
    // build-wide `-Doptimize` — a bare `zig build` must never install a slow
    // debug `gist`. `-Dcli-optimize=Debug` still yields a debug CLI for engine
    // debugging; tests / coverage / the C-ABI libs keep the standard
    // (safety-checked, DWARF-carrying) default optimize untouched.
    const cli_optimize = b.option(
        std.builtin.OptimizeMode,
        "cli-optimize",
        "optimize mode for the installed CLIs (default ReleaseFast — the product surface's whole point is speed)",
    ) orelse .ReleaseFast;
    const cli_deps = if (cli_optimize == optimize) deps else engines(b, target, cli_optimize);
    const cli_chassis = if (cli_optimize == optimize) chassis else b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = cli_optimize,
        .pic = true,
        .imports = &cli_deps,
    });
    // A face main is a thin exe root: real driver code is analyzed inside
    // the chassis module (whose root is src/root.zig, so relative imports
    // resolve) and reached as `@import("gist").faces.*`.
    const face_imports = cli_deps ++ [_]std.Build.Module.Import{.{ .name = "gist", .module = cli_chassis }};
    const exe = b.addExecutable(.{
        .name = "gist",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/surface/face/gist/main.zig"),
            .target = target,
            .optimize = cli_optimize,
            .imports = &face_imports,
        }),
    });
    b.installArtifact(exe);

    // Run the CLI straight out of the build graph, from the package root:
    // `zig build cli -- index`, `-- status`, `-- <pattern> [flags]`. The
    // monorepo also carried a `gist` step that installed the CLI *without* the
    // lab; here a bare `zig build` already does exactly that, so it is gone.
    const run_cli = b.addRunArtifact(exe);
    run_cli.setCwd(b.path("."));
    if (b.args) |args| run_cli.addArgs(args);
    b.step("cli", "gist CLI: `-- index`, `-- status`, `-- <pattern> [flags]`")
        .dependOn(&run_cli.step);

    // ── the C-ABI dual artifact ──
    // Dynamic lib (Python cffi dlopen); owns the header install. Named `gist`
    // — its symbols and header are this product's. Substrate symbols resolve
    // through a link against libirregex (dynamic), so libgist does not redefine
    // them and a host that also links librelate still sees one vocabulary.
    // Own module (not `chassis`) so the CLI/test binaries do not pick up the
    // dylib link — they never call the C symbols.
    const irregex_lib = irregex_dep.artifact("irregex");
    const abi = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &deps,
    });
    abi.linkLibrary(irregex_lib);
    // A shipped dylib has to find its substrate beside itself. `linkLibrary`
    // records only this build tree's own output dir — a RELATIVE
    // `.zig-cache/o/<hash>` path, meaningless on a consumer's machine — so
    // `dlopen("libgist.dylib")` from anywhere else cannot resolve
    // `@rpath/libirregex.dylib` and fails at load. A loader-relative rpath makes
    // the shape we actually ship ("both libraries in one lib dir") the loadable
    // one, without naming an absolute path we do not own.
    abi.addRPathSpecial(if (target.result.os.tag == .macos) "@loader_path" else "$ORIGIN");
    const dynamic_lib = b.addLibrary(.{ .name = "gist", .linkage = .dynamic, .root_module = abi });
    dynamic_lib.installHeader(b.path("include/gist.h"), "gist.h");
    // A host that #includes <gist.h> also needs <irregex.h>; install the
    // engine's header beside ours so one -I covers both.
    dynamic_lib.installHeader(irregex_dep.path("include/irregex.h"), "irregex.h");
    b.installArtifact(dynamic_lib);
    // Static lib (Go cgo / Rust build.rs / C smoke). Zig's archiver leaves
    // Mach-O members non-8-byte-aligned, which Apple's ld64 rejects in a cgo
    // link; re-archive with `libtool -static` on macOS. Linux/LLD tolerates it.
    // Static consumers link libgist.a AND libirregex.a themselves.
    if (target.result.os.tag == .macos) {
        // Its own module, deliberately WITHOUT `linkLibrary(irregex_lib)`. On a
        // dylib that link is what makes libgist import the substrate instead of
        // redefining it; on a relocatable object there is no import to make, so
        // Zig folds the whole engine archive in — 9 MB of duplicated substrate
        // that a host linking libirregex.a would then see twice, and whose
        // folded relocations Apple's ld rejects outright (`invalid
        // r_symbolnum=0`). Static consumers link both archives themselves,
        // exactly as the comment above says.
        const obj_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .imports = &deps,
        });
        const obj = b.addObject(.{ .name = "gist", .root_module = obj_mod });
        const repack = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
        const aligned_a = repack.addOutputFileArg("libgist.a");
        repack.addArtifactArg(obj);
        b.getInstallStep().dependOn(&b.addInstallLibFile(aligned_a, "libgist.a").step);
    } else {
        const static_lib = b.addLibrary(.{ .name = "gist", .linkage = .static, .root_module = abi });
        b.installArtifact(static_lib);
    }
    // Install libirregex.dylib into this prefix so a binding that only built
    // gist still finds both libraries under zig-out/lib.
    b.installArtifact(irregex_lib);
    // The engine's macOS-aligned `.a` is an installLibFile product of the
    // irregex package, not its named artifact. Copy it from the sibling
    // zig-out after that package has been built (`cd ../irregex && zig build`)
    // so Go cgo / C smoke can link both archives under this prefix.
    const eng_static_src = b.pathFromRoot("../irregex/zig-out/lib/libirregex.a");
    const copy_eng_static = b.addSystemCommand(&.{ "cp", "-f", eng_static_src });
    const eng_static_out = copy_eng_static.addOutputFileArg("libirregex.a");
    copy_eng_static.step.dependOn(&irregex_lib.step);
    b.getInstallStep().dependOn(&b.addInstallLibFile(eng_static_out, "libirregex.a").step);

    // ── the measurement lab ──
    // Deliberately OFF the default install step: a bare `zig build` (and every
    // parity gate that rebuilds the CLI) pays only for the product surface.
    // Each lab exe installs on its own named step, so the documented
    // `sudo zig-out/bin/<exe>` re-runs keep working after e.g. `zig build
    // certify`; `zig build lab` installs both at once.
    //
    // What lives here is what measures THIS binary. The engine's own rungs and
    // certificate bounds stay with the kernel in the `irregex` package; the
    // three shared instruments come back from there as modules, so a class name
    // means the same thing in both repos' numbers.
    const lab_step = b.step("lab", "Build + install the measurement-lab executables (gist-bench, warden) → zig-out/bin");

    // `gist-bench` — one binary, six modes. It links the engine like any
    // consumer AND the product chassis, because its session lane spawns a real
    // `gist serve` daemon on a thread and speaks the real UDS frame grammar to
    // it. That second import is why this harness lives here: the engine package
    // is upstream of the product and cannot reach down to the daemon.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/apparatus/harness/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &(deps ++ [_]std.Build.Module.Import{
            .{ .name = "gist", .module = chassis },
            .{ .name = "pmu", .module = irregex_dep.module("pmu") },
            .{ .name = "probes", .module = irregex_dep.module("probes") },
            .{ .name = "stats", .module = irregex_dep.module("stats") },
        }),
    });
    // Layer-A certify mode reads hardware perf counters through Apple's private
    // kperf framework via `dlopen` (std.DynLib) — needs libc.
    bench_mod.link_libc = true;
    const bench_exe = b.addExecutable(.{ .name = "gist-bench", .root_module = bench_mod });
    const bench_install = &b.addInstallArtifact(bench_exe, .{}).step;
    lab_step.dependOn(bench_install);

    // Every mode runs from the package root. In the monorepo this was three
    // levels up, because the corpus and the package were different trees; here
    // the corpus lives in this package under `bench/apparatus/corpora/`, and a
    // corpus elsewhere is named the way the harness already expects —
    // positionally, or through GIST_CORPUS_ROOT.
    for ([_]struct { step: []const u8, mode: ?[]const u8, blurb: []const u8 }{
        .{ .step = "bench", .mode = null, .blurb = "Build the index over given dirs and time the query slate" },
        .{ .step = "verify", .mode = "verify", .blurb = "Emit gist match sets + corpus list for the rg equality diff" },
        .{ .step = "session", .mode = "session", .blurb = "Warm-tier product path: persistent client → resident daemon over a Unix socket" },
        .{ .step = "certify", .mode = "certify", .blurb = "Layer-A optimality cert: per-class cycles/byte + bootstrap CI" },
        .{ .step = "flagbench", .mode = "flagbench", .blurb = "Per-function micro-profiles for -i / -n / -v (byte-identity self-checked)" },
        .{ .step = "sessionprof", .mode = "sessionprof", .blurb = "Per-function micro-profiles for the warm session seams (answer-digest self-checked)" },
    }) |lane| {
        const run = b.addRunArtifact(bench_exe);
        run.setCwd(b.path("."));
        if (lane.mode) |m| run.addArg(m);
        if (b.args) |args| run.addArgs(args);
        const step = b.step(lane.step, lane.blurb);
        step.dependOn(&run.step);
        step.dependOn(bench_install);
    }
    // `warden` — what the resident memory ceiling costs on the alloc path. A
    // safety feature that shows up in a throughput benchmark is not worth
    // having, so this decomposes the wrapper's cost (bare / passthru / warden)
    // against the allocator the daemon really gets, and FAILS on regression
    // rather than merely reporting. Correctness of the bound itself rides
    // `zig build test` via root.zig.
    const warden_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/warden/bench.zig"),
        .target = target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    // Imports the metered allocator ALONE rather than the whole chassis: it
    // depends on nothing but `std`, so the thing being timed is the thing being
    // measured, with no unrelated compile in the way.
    warden_mod.addImport("warden", b.createModule(.{
        .root_source_file = b.path("src/exec/session/warden/warden.zig"),
        .target = target,
        .optimize = cli_optimize,
    }));
    const warden_exe = b.addExecutable(.{ .name = "warden", .root_module = warden_mod });
    const warden_install = &b.addInstallArtifact(warden_exe, .{}).step;
    lab_step.dependOn(warden_install);
    const run_warden = b.addRunArtifact(warden_exe);
    run_warden.setCwd(b.path("."));
    if (b.args) |args| run_warden.addArgs(args);
    const warden_step = b.step("warden", "Resident memory ceiling: what the bound costs per allocation, decomposed vs a no-op wrapper");
    warden_step.dependOn(&run_warden.step);
    warden_step.dependOn(warden_install);

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
    const brigade = irregex_dep.path("brigade.zig");
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
    // The lab harness compiles against both the engine and the daemon, so a
    // product refactor can break it in a way `zig build` alone would not catch.
    // (`stats.zig`'s verdict math is tested in the package that owns it.)
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_mod })).step);

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

/// The engine module import at a given optimize.
fn engines(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) [1]std.Build.Module.Import {
    return .{
        .{ .name = "irregex", .module = b.dependency("irregex", .{ .target = target, .optimize = optimize }).module("irregex") },
    };
}

/// The shard fan-out, restated here rather than shared: `brigade.zig` comes
/// from the `irregex` dependency, but the steps that hang off it are this
/// build's own.
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
