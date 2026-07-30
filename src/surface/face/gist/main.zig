//! gist — the CLI executable entrypoint (the `gist` binary).
//!
//! The lifecycle verbs — what gist DOES, not which competitor's argv it apes:
//!
//!   gist index                        build + persist the trigram index
//!   gist status [--json]              read-only: is an index ready, how fresh, how big
//!   gist config [check|init]          read-only: what is steering this run, from which file
//!   gist codex <build|count|tally|status>  the exact existence/count tier over the
//!                                     compressed self-index shelf (src/corpus/index/codex/)
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
//! Plus four top-level introspection flags (convention, like `--help`):
//! `--help`, `--version`, `--schema` (a JSON capability manifest for
//! agents/codegen), and `--generate <target>` (the man page and the four shell
//! completions, rendered from that same flag table for a human at a prompt).
//!
//! This is the thin dispatch shell only: every verb's real work lives in the
//! engine + command modules, reached through the `gist` module (`commands.search`
//! for the unified search engine, `commands.indexer` for `gist index`,
//! `commands.status` for introspection, `commands.schema` for the manifest). The
//! bench/verify/certify harness is a separate executable (`bench/harness/bench.zig`).

const std = @import("std");
const gist = @import("irregex");

const portal = gist.portal;

const indexer = gist.commands.indexer; // `gist index` — build + persist the trigram index
const codex_face = gist.commands.codex; // `gist codex` — the exact existence/count tier
const status = gist.commands.status; // read-only index introspection
const config = gist.commands.config; // `gist config` — the persisted-configuration stack
const schema = gist.commands.schema; // `--schema` JSON manifest
const primer = gist.commands.primer; // `--generate` man page + shell completions
const search = gist.commands.search; // the unified search engine (bare shorthand + `gist rg`)
const serve = gist.commands.serve; // `gist serve` — the resident warm daemon
const client = gist.commands.client; // the warm CLI fast path (daemon dial + cold fallback)

/// Canonicalize a `gist index ROOT` argument to the walk's path shape: strip
/// any leading `./` and trailing `/` (so `./libs/` indexes as `libs` — the
/// byte shape every query walker and root-scope compare emits); a root that
/// reduces to nothing is the whole tree (`.`).
fn normalizeRootArg(raw: []const u8) []const u8 {
    var root = raw;
    while (std.mem.startsWith(u8, root, "./")) root = root[2..];
    root = std.mem.trimEnd(u8, root, "/");
    return if (root.len == 0) "." else root;
}

/// Collect a verb's trailing `[ROOT...]`, holding it to the argv contract every
/// other entry point already has: `--help` answers, an unrecognized flag exits 2
/// naming itself. Both root-taking verbs used to append every token verbatim, so
/// a mistyped flag became a root that resolves to nothing — and each verb then
/// took its worst branch while reporting success: `serve` daemonized over the CWD,
/// and `index` overwrote a working index with an empty one, silently demoting
/// every later query to a live scan. A bare `-` stays a root (the stdin spelling).
/// Returns false when help was printed and the caller should simply return.
fn collectRoots(
    gpa: std.mem.Allocator,
    it: *Argv,
    verb: []const u8,
    roots: *std.ArrayList([]const u8),
    comptime normalize: bool,
) !bool {
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return false;
        }
        if (arg.len > 1 and arg[0] == '-') {
            gist.assay.diag(
                "gist {s}: unknown flag '{s}' — {s} takes only [ROOT...]\n",
                .{ verb, arg, verb },
            );
            std.process.exit(2);
        }
        try roots.append(gpa, if (normalize) normalizeRootArg(arg) else arg);
    }
    return true;
}

/// Try the resident daemon for an eligible query; on a served answer this exits
/// the process with rg's code and never returns. Any miss (ineligible argv, no
/// daemon, decline, wire error) returns so the caller runs the cold engine —
/// the daemon is a pure accelerator, never a new failure mode.
fn tryWarm(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8) void {
    const sock = serve.socketPath(gpa, env) catch return;
    defer gpa.free(sock);
    // Enumeration modes (`-l`/`-c`) list one compact line per file: lift the soft
    // context cap BEFORE the warm stream so a warm-served answer is the COMPLETE
    // set, matching the cold engine's exemption (the two engines must never
    // disagree on which files `-l` returns). Classify is stack-only + pure; an
    // ineligible argv routes cold below, where `serial.run` applies the same rule.
    var mode_sa: gist.session.request.ScopeArgs = .{};
    const eligible = if (gist.session.request.classify(argv, &mode_sa)) |req| blk: {
        if (req.mode == .files or req.mode == .count) gist.corpus.exemptSoftCap();
        break :blk true;
    } else |_| false;
    const debug = gist.assay.lit(.warm); // observe the routing decision
    // Surface the CLASSIFY verdict independently of daemon availability, so a
    // cold outcome from "ineligible argv" is distinguishable from "eligible but
    // no daemon up" — the oracle the cross-binding parity test reads to prove
    // Python `warm_eligible` tracks this classifier exactly.
    if (debug) gist.assay.diag("gist: [{s}]\n", .{if (eligible) "eligible" else "ineligible"});
    switch (client.attempt(gpa, io, argv, sock)) {
        .served => |code| {
            if (debug) gist.assay.diag("gist: [warm]\n", .{});
            gist.corpus.finishOutput(); // announce a budget cut on the warm flush (idempotent, stderr-only)
            // A warm-served no-match (exit 1) gets the same stderr guidance the
            // cold engines emit. The classifier already parsed this argv to
            // route it warm, so re-classifying recovers pattern + -F and the
            // RESOLVED case state (smart-case folds through the session's one
            // resolution site) without a second full flag parse; eligible
            // requests are always rootless.
            var hint_sa: gist.session.request.ScopeArgs = .{};
            // An unclassifiable argv simply earns no hint — `classify` declining
            // is the routine answer here, not a failure to report.
            if (code == 1) if (gist.session.request.classify(argv, &hint_sa) catch null) |req| {
                // `-q` and `-m0` are SILENT on a miss (cold exits 1 with no
                // stderr guidance — `serial.zig`), so suppress the hint for them.
                if (!req.quiet and !req.matchNothing())
                    search.hints.noMatches(search.hints.shapeBare(req.pattern, req.fixed, req.effectiveIgnoreCase()), null);
            };
            std.process.exit(code);
        },
        // Cold miss on an eligible shape with no daemon up: fork one detached so
        // the next such query lands warm. This query still runs cold below.
        .cold => {
            if (debug) gist.assay.diag("gist: [cold]\n", .{});
            client.spawn.maybeSpawn(gpa, io, env, argv, sock);
        },
    }
}

/// `--help` / bare `gist`: the ergonomic map of the CLI. Requested output goes
/// to stdout (rg convention); diagnostics/hints stay on stderr. This teaches
/// selection while flag-level truth remains generated from `flag_catalog` by
/// `--schema`.
fn usage() void {
    gist.corpus.emitStdout(
        \\gist — fast, agent-friendly code locator
        \\
        \\usage:
        \\  gist <pattern> [PATH...] [flags]   search — no verb, no setup; ripgrep's default
        \\                                     behavior and flags, auto-accelerated by a fresh
        \\                                     index (acceleration never changes output)
        \\
        \\ergonomics — keep the reflex, choose the native shape:
        \\  muscle memory           replace `rg` with `gist`; pattern, paths, familiar flags,
        \\                          stdout, and 0/1/2 exit codes keep their meaning
        \\  native Gist             add --rank, index controls, resident, or codex behavior
        \\                          only when the question is no longer ordinary grep
        \\
        \\default move:
        \\  exact text / regex      gist PATTERN [PATH...]
        \\  one strong code hit     gist PATTERN --rank[=N]     (default N = 20)
        \\  existence / file set    -q / -l
        \\  counts / machine data   -c / --json
        \\  literal / word / line   -F / -w / -x
        \\  case                    -i insensitive · -s sensitive · -S smart (last wins)
        \\  complex regex           --engine auto, or -P when PCRE2 semantics are required
        \\  multiline               -U; --multiline-dotall also lets `.` cross newlines
        \\  context                 -A N / -B N / -C N
        \\  scope                   PATH... · -t TYPE · -T TYPE · -g GLOB · --iglob GLOB
        \\  docs or code            --docs reads the paper trail · --no-docs the implementation
        \\  hidden / ignored        -u disables ignores · -uu adds hidden · -uuu adds binary
        \\
        \\native choices:
        \\  --docs / --code / --data prose · implementation · config — one KIND of file, an axis
        \\                          -t cannot express; --no-<genus> is the exact complement
        \\  --rank[=N]              definition-biased bounded view; linear engine only
        \\  --no-index / --index    pure live oracle / explicitly re-enable acceleration
        \\  resident session        automatic and fail-open for eligible searches; do nothing
        \\  gist codex count TEXT   exact literal count without source-file I/O on a clean shelf
        \\  --uncap                 lift the soft agent-output budget for this query
        \\
        \\niche choices:
        \\  --no-unicode / (?-u)    byte/ASCII classes, folding, words, and boundaries
        \\  --sort / --sortr KEY    stable order: path|modified|accessed|created
        \\  -z / --pre CMD / -E     compressed input / preprocessed input / source encoding
        \\  -a / --binary           treat as text / search binary files in full
        \\  -0 / --null-data        NUL-delimited paths / NUL-delimited input records
        \\  -m0 / -M0               match nothing (exit 1) / disable the long-line cap
        \\  --heading / -n          on by default on a terminal (rg's layout); --no-heading
        \\                          / -N decline, and a pipe never had them
        \\  -p / --plain            the human posture (color + heading + -n) / the piped
        \\                          posture, forced, so a terminal run is reproducible
        \\  --line-buffered         hand each line off the moment it is found (live tail)
        \\  --block-buffered        coalesce into few writes; ramped, so head -1 is instant
        \\  --buffer-size=SIZE      size that block (K/M suffixes); 0 writes straight through
        \\  -rn                     means --replace=n, not recursive + line numbers; use -n
        \\  no match                read stderr suggestions; stdout remains pipeline-clean
        \\
        \\index lifecycle:
        \\  gist index [ROOT...]    build + persist the trigram index (optional, ~3 s);
        \\                          no roots = this tree (GIST_ROOTS overrides)
        \\  gist status [--json]    is an index ready, how fresh, how big
        \\  gist serve [ROOT...]    resident warm daemon (auto-spawned; explicit run scopes it)
        \\  gist codex <build|count|tally|status>   exact corpus-wide counts off the
        \\                          compressed self-index — O(|pattern|), zero corpus I/O
        \\
        \\aliases:
        \\  gist rg / gist search <pattern> [PATH...]   the same engine, addressed with a verb
        \\
        \\persisted configuration (optional; neither file is required):
        \\  gist config             what is steering this run, and from which file
        \\  gist config check       validate both layers without running a search
        \\  gist config init        write .irregex.toml, prefilled from this machine's
        \\                          GIST_ROOTS / skips.list (--write to create it)
        \\  --no-config             ignore both layers for this run (env: GIST_NO_CONFIG=1)
        \\
        \\introspection:
        \\  gist --help / -h        this ergonomics guide
        \\  gist --schema           exhaustive JSON surface generated from the live flag catalog
        \\  gist --generate TARGET  man | complete-{bash,zsh,fish,powershell} — the same surface
        \\                          rendered for a human; every menu baked in, no fork per keystroke
        \\  gist --version / -V
        \\
        \\channels & env:
        \\  results -> stdout (rg-shaped bytes) · guidance -> stderr ('gist: try' / 'gist: note:')
        \\  GIST_HINTS=0            mute stderr hints (results are untouched either way)
        \\  GIST_UNCAP=1            lift the ~25k-token soft output cap (also: --uncap)
        \\  GIST_MAX_OUTPUT_TOKENS / GIST_MAX_OUTPUT_BYTES   resize the output budget
        \\  GIST_DIR                artifact home (default .local/gist-verify)
        \\  GIST_SKIP / <GIST_DIR>/skips.list   extra skip dirs for the corpus walks
        \\                          (index/freshness/relate only — search keeps rg parity)
        \\
    );
}

/// argv, minus the one token answered before dispatch. `--no-config` is legal
/// in front of every verb, so filtering it here is the difference between one
/// rule and a copy of that rule inside each verb's argument check — `gist
/// status --no-config` used to die on "status accepts only --json". Past a `--`
/// the token is data again and passes through untouched.
const Argv = struct {
    inner: std.process.Args.Iterator,
    literal: bool = false,

    fn init(args: std.process.Args, gpa: std.mem.Allocator) !Argv {
        return .{ .inner = try portal.argsIterator(args, gpa) };
    }
    fn skip(self: *Argv) bool {
        return self.inner.skip();
    }
    fn next(self: *Argv) ?[]const u8 {
        while (self.inner.next()) |a| {
            if (!self.literal and gist.commands.scope.charter.consumed(a)) continue;
            if (std.mem.eql(u8, a, "--")) self.literal = true;
            return a;
        }
        return null;
    }
};

/// Answer a lifecycle flag appearing INSIDE the `rg`/`search` verb's argv, where
/// the top-level scan can no longer see it. True when the run was an answer
/// about gist rather than a search, so the caller returns without dispatching.
///
/// Scanning stops at `--` for the same reason the parser does: past the
/// terminator a `--version` is a pattern, not a question.
fn lifecycleAnswer(args: []const []const u8) !bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return true;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            var line: [64]u8 = undefined;
            gist.corpus.emitStdout(try std.fmt.bufPrint(&line, "gist {s}\n", .{gist.version_string}));
            return true;
        }
        // rg's phrasing, gist's build: the vendored PCRE2 is always present and
        // always JIT-compiled, so there is no "not available" branch to report.
        if (std.mem.eql(u8, arg, "--pcre2-version")) {
            gist.corpus.emitStdout("PCRE2 " ++ gist.pcre2_version_string ++ " is available (JIT is available)\n");
            return true;
        }
        if (std.mem.eql(u8, arg, "--generate") or std.mem.startsWith(u8, arg, "--generate=")) {
            const inl = if (arg.len > "--generate".len) arg["--generate=".len..] else null;
            primer.emit(gist.version_string, inl orelse nextAfter(args, arg));
            return true;
        }
    }
    return false;
}

/// The argument following `needle` in `args`, or null when it is the last one.
/// Compared by identity of position rather than by value: the same spelling can
/// legitimately appear twice, and only the first one is the flag being answered.
fn nextAfter(args: []const []const u8, needle: []const u8) ?[]const u8 {
    for (args, 0..) |a, i| if (a.ptr == needle.ptr) return if (i + 1 < args.len) args[i + 1] else null;
    return null;
}

/// `main` takes no error union on purpose: Zig's default handler exits 1 with a
/// stack trace, and 1 is "no match" under the rg contract. `fatal` exits 2.
pub fn main(init: std.process.Init) void {
    run(init) catch |e| gist.fatal("gist", e);
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Diagnostic policy for this process: cold CLI writes straight to stderr,
    // and `GIST_TRACE`/`GIST_TRACE_FORMAT` are read once here into the lens mask
    // and render format every summary/trace call site consults.
    gist.assay.install(.{});

    gist.commands.scope.charter.honorNoConfig(gpa, init.minimal.args);

    var it = try Argv.init(init.minimal.args, gpa);
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
    // A version that was asked for is an answer, not a diagnostic — rg writes
    // it to stdout, and so does every wrapper that captures only stdout.
    if (std.mem.eql(u8, mode, "--version") or std.mem.eql(u8, mode, "-V")) {
        var line: [64]u8 = undefined;
        return gist.corpus.emitStdout(
            try std.fmt.bufPrint(&line, "gist {s}\n", .{gist.version_string}),
        );
    }
    if (std.mem.eql(u8, mode, "--schema")) {
        schema.emit(gist.version_string);
        return;
    }
    // `--generate <target>` — the same surface `--schema` describes to a
    // machine, rendered for a human: the manual, or a completion for one of
    // four shells. `--generate=man` is accepted too, since half the world
    // spells a long flag's value that way.
    if (std.mem.startsWith(u8, mode, "--generate")) {
        const inl = if (mode.len > "--generate".len and mode["--generate".len] == '=')
            mode["--generate=".len..]
        else if (mode.len == "--generate".len) null else {
            gist.assay.diag("gist: unknown flag {s}\n", .{mode});
            std.process.exit(2);
        };
        primer.emit(gist.version_string, inl orelse it.next());
        return;
    }

    // Resolve the output budget from the environment once, before any search
    // dispatch, so the warm client path (which emits without re-parsing flags)
    // honors `GIST_UNCAP`/`GIST_MAX_OUTPUT_*`. The cold engine re-resolves it
    // with the parsed `--uncap` flag (`search.run`); `--uncap` always routes
    // cold (the resident classifier declines it), so the flag still takes effect.
    gist.corpus.initOutputBudget(false);

    // `gist index [ROOT...]` — explicit roots scope the index to those
    // subtrees; with none, `corpus.resolveRoots` picks the corpus for THIS
    // working directory (GIST_ROOTS → `.`, the whole tree).
    if (std.mem.eql(u8, mode, "index")) {
        var roots: std.ArrayList([]const u8) = .empty;
        defer roots.deinit(gpa);
        if (!try collectRoots(gpa, &it, "index", &roots, true)) return;
        if (roots.items.len > 0) return indexer.run(gpa, io, roots.items);
        const resolved = try gist.corpus.resolveRoots(gpa);
        defer gist.corpus.freeRoots(gpa, resolved);
        return indexer.run(gpa, io, resolved);
    }
    // `gist codex <build|count|tally|status>` — the exact existence/count tier
    // over the compressed self-index (`src/corpus/index/codex/`): corpus-wide occurrence
    // counts in O(|pattern|) with zero corpus I/O and zero false positives,
    // freshness-reported against the shelf's own build anchor.
    if (std.mem.eql(u8, mode, "codex")) {
        var rest: std.ArrayList([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (it.next()) |arg| try rest.append(gpa, arg);
        try codex_face.run(gpa, io, rest.items);
        return;
    }
    // `gist config [check|init]` — what is steering this run and from which
    // file. Persisted configuration that cannot be interrogated is the thing
    // `--no-config` exists to bisect around; this is the direct answer instead.
    if (std.mem.eql(u8, mode, "config")) {
        var rest: std.ArrayList([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (it.next()) |arg| try rest.append(gpa, arg);
        return config.run(gpa, io, rest.items);
    }
    if (std.mem.eql(u8, mode, "status")) {
        const arg = it.next();
        const json = if (arg) |value| std.mem.eql(u8, value, "--json") else false;
        if (arg != null and !json or it.next() != null) {
            gist.assay.diag("gist: status accepts only --json\n", .{});
            std.process.exit(2);
        }
        // The rendezvous is resolved here, where the environment is, so status
        // can report which build is answering there without learning how a
        // socket path is spelled. Unresolvable ⇒ nothing to probe, not an error.
        const sock: ?[]u8 = serve.socketPath(gpa, init.environ_map) catch null;
        defer if (sock) |s| gpa.free(s);
        try status.run(gpa, io, json, sock);
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
        if (!try collectRoots(gpa, &it, "serve", &roots, false)) return;
        // Empty roots ⇒ rootless CWD walk (byte-identical to rootless cold).
        try serve.run(gpa, io, roots.items, sock);
        return;
    }
    // ── shed verbs: similar/dups/patterns live in the `relate` binary now ──
    // These verbs used to shadow a bare-literal search for their own names, so
    // a redirect stub regresses nothing a literal searcher could reach; it just
    // routes muscle memory (and agents replaying old argv) to the new face.
    if (std.mem.eql(u8, mode, "similar") or std.mem.eql(u8, mode, "dups") or std.mem.eql(u8, mode, "patterns")) {
        gist.assay.diag("gist: '{s}' moved to the relate binary — run `relate {s} ...` (same flags; `make install-gist` installs both)\n", .{ mode, mode });
        std.process.exit(2);
    }

    // `rg [flags] <pattern> [PATH...]` — the same whole-tree engine the bare
    // shorthand below uses, addressed explicitly (the shape an `alias
    // rg=gist` drop-in takes). It also backs the rgsuite differential-parity
    // certificate (446 mined `rg`-argv replays via `bench/rgsuite/run.py`).
    // Omitted from `usage()`'s three-verb list (it isn't index-backed — see
    // the bare shorthand, which IS documented there) and from `--schema`
    // (its flag surface is rg's own, not gist's native vocabulary), but it is
    // a fully supported, intentional entry point, not a hidden fallback.
    //
    // `search <pattern> [PATH...]` — the same engine addressed with the verb the
    // reflex reaches for. gist's canonical shape is verbless (`gist <pattern>`),
    // but `gist search foo` is a near-universal habit; without this it parses as
    // pattern=`search`, path=`foo`, and dies on `foo: No such file (os error 2)`
    // — a faithful-to-rg but repeatedly baffling failure. A bare `gist search`
    // (no pattern after it) still searches for the literal word "search", so no
    // existing invocation regresses.
    //
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
    const verbed = std.mem.eql(u8, mode, "rg") or std.mem.eql(u8, mode, "search");
    var query: std.ArrayList([]const u8) = .empty;
    defer query.deinit(gpa);
    // Personal preferences lead, so anything typed on the line overrides them —
    // last-wins is the grammar's existing rule, and prepending is what turns it
    // into "the file is a default". `forThisRun` returns nothing unless stdout
    // is a terminal, so a pipe, a script, and an agent all see bare argv.
    const persisted = gist.preference.forThisRun(io);
    try query.appendSlice(gpa, persisted);
    if (!verbed) try query.append(gpa, mode);
    while (it.next()) |arg| try query.append(gpa, arg);
    // A bare `gist search` keeps its literal-word meaning; a bare `gist rg`
    // stays the empty argv the engine rejects itself. Measured against the
    // preference prefix, not zero, so a preferences file cannot quietly turn
    // `gist search` into a flags-only invocation with no pattern at all.
    if (query.items.len == persisted.len and std.mem.eql(u8, mode, "search"))
        try query.append(gpa, mode);
    // A drop-in has to answer the four questions a caller asks the BINARY
    // rather than the corpus, in the position ripgrep accepts them: `rg
    // --version` puts the flag where gist's own top-level scan (above) has
    // already moved past. Without this, `gist rg --version` was an unknown
    // flag — measured as four of the 35 surface rejections by
    // `bench/rgsuite/surface.py`. Each answers with gist's own identity; the
    // point of parity here is the shape of the exchange (stdout, exit 0),
    // never a pretense of being ripgrep.
    if (verbed) if (try lifecycleAnswer(query.items)) return;
    tryWarm(gpa, io, init.environ_map, query.items);
    try search.run(gpa, io, query.items, init.environ_map);
}
