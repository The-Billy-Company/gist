//! gist — the CLI executable entrypoint (the `gist` binary).
//!
//! Two lifecycle verbs — what gist DOES, not which competitor's argv it apes:
//!
//!   gist index                        build + persist the trigram index
//!   gist status [--json]              read-only: is an index ready, how fresh, how big
//!
//! Everything else is the search itself — no verb at all, the shape an agent's
//! `rg <pattern>` reflex already takes:
//!
//!   gist <pattern> [PATH...] [flags]  find it, right now, zero setup
//!
//! `gist jesus` needs no `gist index` first: it live-scans the current tree with
//! ripgrep's own default behavior (gitignore precedence, piped stdin, exit
//! codes) — a true `rg` drop-in. When a fresh index covers the searched subtree
//! it is used *automatically* as an acceleration structure (reads of provable
//! non-candidate files are elided), byte-identically to the live walk;
//! `--no-index` forces the pure walk, `--index` forces the accelerated path.
//! `--rank[=N]` selects gist's one native shape ripgrep can't express — the
//! definition-first ranked view. `gist rg [flags] <pattern> [PATH...]` and its
//! habit-safe twin `gist search <pattern> [PATH...]` are the same engine
//! addressed explicitly with a verb (the `alias rg=gist` drop-in's shape, and
//! the `search` reflex — so `gist search foo` finds `foo` instead of dying on a
//! nonexistent path).
//!
//! Plus three top-level introspection flags (convention, like `--help`):
//! `--help`, `--version`, `--schema` (a JSON capability manifest for
//! agents/codegen).
//!
//! This is the thin dispatch shell only: every verb's real work lives in the
//! engine + command modules, reached through the `gist` module (`commands.ripgrep`
//! for the unified search engine, `commands.indexer` for `gist index`,
//! `commands.status` for introspection, `commands.schema` for the manifest). The
//! bench/verify/certify harness is a separate executable (`bench/harness/bench.zig`).

const std = @import("std");
const gist = @import("irregex");

const indexer = gist.commands.indexer; // `gist index` — build + persist the trigram index
const status = gist.commands.status; // read-only index introspection
const schema = gist.commands.schema; // `--schema` JSON manifest
const ripgrep = gist.commands.ripgrep; // the unified search engine (bare shorthand + `gist rg`)
const serve = gist.commands.serve; // `gist serve` — the resident warm daemon
const client = gist.commands.client; // the warm CLI fast path (daemon dial + cold fallback)
const default_roots = gist.corpus.default_roots;

/// Try the resident daemon for an eligible query; on a served answer this exits
/// the process with rg's code and never returns. Any miss (ineligible argv, no
/// daemon, decline, wire error) returns so the caller runs the cold engine —
/// the daemon is a pure accelerator, never a new failure mode.
fn tryWarm(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8) void {
    const sock = serve.socketPath(gpa, env) catch return;
    defer gpa.free(sock);
    const debug = env.get("GIST_DEBUG_WARM") != null; // observe the routing decision
    switch (client.attempt(gpa, io, argv, sock)) {
        .served => |code| {
            if (debug) std.debug.print("gist: [warm]\n", .{});
            gist.corpus.finishOutput(); // announce a budget cut on the warm flush (idempotent, stderr-only)
            std.process.exit(code);
        },
        // Cold miss on an eligible shape with no daemon up: fork one detached so
        // the next such query lands warm. This query still runs cold below.
        .cold => {
            if (debug) std.debug.print("gist: [cold]\n", .{});
            client.spawn.maybeSpawn(gpa, io, env, argv, sock);
        },
    }
}

fn usage() void {
    std.debug.print(
        \\gist — fast, agent-friendly code locator
        \\
        \\usage:
        \\  gist <pattern> [PATH...] [flags]   find matches — no verb, no setup; live-scans
        \\                                     the tree (rg's default behavior), auto-using a
        \\                                     fresh index to skip non-candidate reads
        \\  index                              build + persist the trigram index
        \\  status [--json]                    is an index ready, how fresh, how big
        \\
        \\  rg / search <pattern> [PATH...]    the same engine, addressed with a verb (habit-safe aliases)
        \\  --no-index / --index               force the live walk / the index-accelerated path
        \\  --rank [=N]                         definition-first ranked view (top N, default 20)
        \\  gist --help                        the broad tested flag subset (`gist rg --help`)
        \\  gist --schema                      a JSON capability manifest for agents
        \\  gist --version
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // argv[0]
    const mode = it.next() orelse {
        usage();
        return;
    };

    // Top-level introspection flags (convention, not verbs).
    if (std.mem.eql(u8, mode, "--help") or std.mem.eql(u8, mode, "-h")) {
        usage();
        return;
    }
    if (std.mem.eql(u8, mode, "--version") or std.mem.eql(u8, mode, "-V")) {
        std.debug.print("gist {s}\n", .{gist.version_string});
        return;
    }
    if (std.mem.eql(u8, mode, "--schema")) {
        schema.emit();
        return;
    }

    // Resolve the output budget from the environment once, before any search
    // dispatch, so the warm client path (which emits without re-parsing flags)
    // honors `GIST_UNCAP`/`GIST_MAX_OUTPUT_*`. The cold engine re-resolves it
    // with the parsed `--uncap` flag (`ripgrep.run`); `--uncap` always routes
    // cold (the resident classifier declines it), so the flag still takes effect.
    gist.corpus.initOutputBudget(false);

    if (std.mem.eql(u8, mode, "index")) {
        try indexer.run(gpa, io, &default_roots);
        return;
    }
    if (std.mem.eql(u8, mode, "status")) {
        const arg = it.next();
        const json = if (arg) |value| std.mem.eql(u8, value, "--json") else false;
        if (arg != null and !json or it.next() != null) {
            std.debug.print("gist: status accepts only --json\n", .{});
            std.process.exit(2);
        }
        try status.run(gpa, io, json);
        return;
    }
    // `gist serve [ROOT...]` — run the resident daemon: keep the corpus + index
    // warm behind a Unix socket so subsequent eligible queries answer without
    // cold startup. With NO path args it serves the rootless CWD walk — the EXACT
    // tree a bare `gist <pattern>` walks (`walkDir(".", "")`, CWD-relative paths,
    // no `./` prefix), which is the whole basis of warm==cold parity; this is
    // what auto-spawn (`client/spawn.zig`) starts. Trailing path args scope a
    // subtree instead (a real use, and what the hermetic client/session tests
    // drive over a throwaway corpus).
    if (std.mem.eql(u8, mode, "serve")) {
        const sock = try serve.socketPath(gpa, init.environ_map);
        defer gpa.free(sock);
        var roots: std.ArrayList([]const u8) = .empty;
        defer roots.deinit(gpa);
        while (it.next()) |arg| try roots.append(gpa, arg);
        // Empty roots ⇒ rootless CWD walk (byte-identical to rootless cold).
        try serve.run(gpa, io, roots.items, sock);
        return;
    }
    // ── shed verbs: similar/dups/patterns live in the `hydra` binary now ──
    // These verbs used to shadow a bare-literal search for their own names, so
    // a redirect stub regresses nothing a literal searcher could reach; it just
    // routes muscle memory (and agents replaying old argv) to the new face.
    if (std.mem.eql(u8, mode, "similar") or std.mem.eql(u8, mode, "dups") or std.mem.eql(u8, mode, "patterns")) {
        std.debug.print("gist: '{s}' moved to the hydra binary — run `hydra {s} ...` (same flags; `make install-gist` installs both)\n", .{ mode, mode });
        std.process.exit(2);
    }

    // `rg [flags] <pattern> [PATH...]` — the same whole-tree engine the bare
    // shorthand below uses, addressed explicitly (the shape an `alias
    // rg=gist` drop-in takes). It also backs the rgsuite differential-parity
    // certificate (441 mined `rg`-argv replays via `bench/rgsuite/run.py`).
    // Omitted from `usage()`'s three-verb list (it isn't index-backed — see
    // the bare shorthand, which IS documented there) and from `--schema`
    // (its flag surface is rg's own, not gist's native vocabulary), but it is
    // a fully supported, intentional entry point, not a hidden fallback.
    if (std.mem.eql(u8, mode, "rg")) {
        var rest: std.ArrayList([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (it.next()) |arg| try rest.append(gpa, arg);
        tryWarm(gpa, io, init.environ_map, rest.items);
        try ripgrep.run(gpa, io, rest.items, init.environ_map);
        return;
    }
    // `search <pattern> [PATH...]` — the same engine addressed with the verb the
    // reflex reaches for. gist's canonical shape is verbless (`gist <pattern>`),
    // but `gist search foo` is a near-universal habit; without this it parses as
    // pattern=`search`, path=`foo`, and dies on `foo: No such file (os error 2)`
    // — a faithful-to-rg but repeatedly baffling failure. A bare `gist search`
    // (no pattern after it) still searches for the literal word "search", so no
    // existing invocation regresses.
    if (std.mem.eql(u8, mode, "search")) {
        var rest: std.ArrayList([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (it.next()) |arg| try rest.append(gpa, arg);
        if (rest.items.len > 0) {
            tryWarm(gpa, io, init.environ_map, rest.items);
            try ripgrep.run(gpa, io, rest.items, init.environ_map);
        } else {
            tryWarm(gpa, io, init.environ_map, &.{mode});
            try ripgrep.run(gpa, io, &.{mode}, init.environ_map);
        }
        return;
    }

    // Implicit invocation: `gist <pattern> [PATH...] [flags]` with no explicit
    // verb — documented in `usage()` as the everyday shorthand: the shape an
    // agent's `rg <pattern>` reflex already takes, with zero setup (no `gist
    // index` needed first). Routes through the SAME rg-compatible engine
    // `gist rg` uses (its `readableStdin()` piped-input path, default
    // presentation, exit codes) rather than falling through to "unknown
    // command" (which printed to stderr while a piped `make | gist "pattern"`
    // produced no stdout at all) or silently re-interpreting the pattern as an
    // indexed full-corpus `search`, which has no stdin path, requires an
    // index to exist, and diverges wildly from `rg`'s piped-stream behavior.
    var implicit: std.ArrayList([]const u8) = .empty;
    defer implicit.deinit(gpa);
    try implicit.append(gpa, mode);
    while (it.next()) |arg| try implicit.append(gpa, arg);
    tryWarm(gpa, io, init.environ_map, implicit.items);
    try ripgrep.run(gpa, io, implicit.items, init.environ_map);
}
