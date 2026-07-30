//! argv → `Parsed`: the walk, the precedence, and the resolution.
//!
//! Everything order-sensitive about ripgrep's CLI lives here, because that is
//! what makes it one grammar rather than a bag of flags: short-flag bundling
//! (`-uu`, `-j3`, and the `-rn` footgun), `--flag` vs `--flag=value`, the
//! last-wins case triad, `--passthru` and `-A`/`-B`/`-C` overriding each other,
//! and the two rules that can only be settled once argv has *ended* — `-A`/`-B`
//! outranking `-C` regardless of the order they appeared in, and smart-case
//! resolving against every pattern collected along the way.
//!
//! It is the only module in the package that both reads the flag catalog and
//! writes the request, and it is deliberately the only one: the dispatch table
//! (`catalog.zig`), the state it fills (`intent.zig`), and the value decoders it
//! calls (`verdict.zig`) each stay ignorant of argv order, so a precedence bug
//! has exactly one place to be.

const std = @import("std");
const builtin = @import("builtin");
const assay = @import("../../../assay/assay.zig");
const beacon = @import("../../../surface/cli/beacon.zig");
const color = @import("../emit/color.zig");
const catalog = @import("catalog.zig");
const charter = @import("../../../corpus/scope/charter.zig");
const intent = @import("intent.zig");
const verdict = @import("verdict.zig");

const Act = catalog.Act;
const Builder = intent.Builder;
const ColorChoice = intent.ColorChoice;
const Engine = intent.Engine;
const Parsed = intent.Parsed;
const SortKey = intent.SortKey;
const die = @import("../../../surface/cli/outcome.zig").die;
const enumOrDie = verdict.enumOrDie;
const flag_catalog = catalog.flag_catalog;
const oom = @import("../../../surface/cli/outcome.zig").oom;
const setVal = catalog.setVal;
const short_map = catalog.short_map;
const toU = verdict.toU;

/// The `-rn` footgun: grep muscle memory reads `-rn` as "recursive + line
/// numbers", but rg short-flag bundling (which gist matches byte-for-byte)
/// parses it as `--replace=n` — every match silently rewritten to `n`, output
/// that looks mangled rather than wrong. True iff a bundled `-r` value is a
/// short string made entirely of known short flags (`n`, `ni`, `l`, …), i.e.
/// almost certainly an intended flag bundle. Replacement templates (`$1`,
/// `${name}`) and longer text never qualify.
fn looksLikeFlagBundle(v: []const u8) bool {
    if (v.len == 0 or v.len > 3) return false;
    for (v) |c| if (short_map[c] == null) return false;
    return true;
}

/// Emit the `-rn` grep-ism note on stderr. Behavior stays rg-identical (parity
/// is sacred and the differential harness compares stdout only) — this only
/// tells the user what actually happened so an agent doesn't misread replaced
/// output as a display bug.
fn noteGrepStyleReplace(v: []const u8) void {
    if (!looksLikeFlagBundle(v)) return;
    // Silent under `zig build test`: the unit test parses "-rn" on purpose, and
    // stderr from a passing test binary makes the build runner print a spurious
    // "failed command:" banner. The note is user-guidance, not behavior.
    if (builtin.is_test) return;
    assay.diag(
        "gist: note: '-r{s}' parses as --replace={s} (ripgrep semantics: -r takes a value; recursion is already the default). Spell flags separately (e.g. -n), or use --replace to silence this note.\n",
        .{ v, v },
    );
}

/// The `--hyperlink vscode` footgun, the same shape as `-rn` above: rg spells
/// this flag `--hyperlink-format vscode`, so that spacing arrives as muscle
/// memory — but gist's `--hyperlink` reads its value inline (a bare one must
/// leave the next token to be the pattern), and the destination silently
/// becomes the search. Behavior is untouched; this only says what happened,
/// because a hyperlink layer that links somewhere unasked and stays quiet is
/// the exact failure it was built to remove.
fn noteMisspacedHyperlink(pat: []const u8) void {
    if (!beacon.misspaced(pat)) return;
    if (builtin.is_test) return;
    assay.diag(
        "gist: note: --hyperlink takes its value inline, so '{s}' was read as the PATTERN. Write --hyperlink={s} (or ripgrep's --hyperlink-format {s}).\n",
        .{ pat, pat, pat },
    );
}

/// Where a flag's value comes from: a short bundle's tail / next argv token,
/// or a long flag's inline `=value` / next argv token. `take` consumes it;
/// `consumed` tells the short-bundle loop the value ate the rest of the token.
const ValSrc = struct {
    mode: enum { short, long },
    i: *usize,
    all: []const []const u8,
    arg: []const u8 = "", // short mode: the whole `-abc` token
    j: usize = 0, // short mode: index of the current flag char
    name: []const u8 = "", // long mode: the flag name (for error text)
    inl: ?[]const u8 = null, // long mode: the inline `=value`, if any
    consumed: bool = false,

    fn take(self: *ValSrc) []const u8 {
        self.consumed = true;
        switch (self.mode) {
            .short => if (self.j + 1 < self.arg.len) return self.arg[self.j + 1 ..] else if (self.i.* + 1 >= self.all.len) die("flag -{c} needs a value\n", .{self.arg[self.j]}),
            .long => if (self.inl) |x| return x else if (self.i.* + 1 >= self.all.len) die("flag needs a value\n", .{}),
        }
        self.i.* += 1;
        return self.all[self.i.*];
    }
};

/// Apply one catalog action to the parse state — the single dispatch behind
/// both the short-bundle and long-flag paths.
fn apply(b: *Builder, action: Act, v: *ValSrc) void {
    const o = &b.o;
    switch (action) {
        .set => |f| setVal(o, f, true),
        .unset => |f| setVal(o, f, false),
        .set_many => |fs| for (fs) |f| setVal(o, f, true),
        .set_num => |f| setVal(o, f, toU(v.take())),
        .set_str => |f| setVal(o, f, v.take()),
        .sep => |f| setVal(o, f, verdict.unescape(b.a, v.take())),
        .filename => |f| o.filename = f,
        // Case mode is last-wins across -i/-s/-S (ripgrep resolves the three
        // to a single final state): each spelling clears the other two, so
        // `-S -s` ends case-sensitive (not smart) and `-i -s` ends sensitive.
        .case => |c| {
            o.caseless, o.smart_case = .{ c == .icase, c == .smart };
        },
        // Recorded, not applied: what `--vimgrep`/`--column` imply, and what a
        // terminal destination asks for, fold in only after every explicit
        // answer is in (`answer.Locus`).
        .locate => |l| switch (l) {
            .line_on => b.locus.line = true,
            .line_off => b.locus.line = false,
            .column_on => b.locus.column = true,
            .column_off => b.locus.column = false,
            .heading_on => b.locus.heading = true,
            .heading_off => b.locus.heading = false,
        },
        // One choice across -w/-x, last spelling wins, so `-x -w` is a word
        // match and `-w -x` a whole-line one.
        .boundary => |bd| {
            o.word, o.line_regexp = .{ bd == .word, bd == .line };
        },
        // The four output modes are one mutually exclusive choice, resolved
        // last-wins the way ripgrep resolves it — not four independent bools
        // ranked by whichever the emitter happens to test first. So `-l -c`
        // counts, `-c -l` lists, and `--files-without-match -l` lists.
        // Resolved in place rather than at seal: whether the next bare argument
        // is a pattern or a path is decided mid-parse from `noPattern()`, so a
        // `--files` that only took effect later would swallow its own path.
        .mode => |m| o.mode = o.mode.update(m),
        // The undo direction of that one choice. Guarded on the current mode so
        // `--json -l --no-json` still lists: an inverse countermands its own
        // flag, never whichever flag happened to win afterwards.
        .mode_off => |m| if (o.mode == m) {
            o.mode = .standard;
        },
        // The ladder lands HERE rather than at finalize, so a later negation can
        // countermand it: `-uu --no-hidden` searches ignored-but-not-hidden
        // files, exactly as it does in rg, where -u is an alias expanded in
        // place. Cumulative either way — the count is what picks the rungs.
        .unrestrict => {
            b.urestrict += 1;
            if (b.urestrict >= 1) o.no_ignore = true;
            if (b.urestrict >= 2) o.hidden = true;
            if (b.urestrict >= 3) o.binary = true;
        },
        // --passthru and -A/-B/-C are mutually overriding — the last one on the
        // argv wins (ripgrep writes the same context setting). Reset any pending
        // context here; the context actions reset passthru symmetrically.
        .passthru => {
            o.passthru, b.a_val, b.b_val, b.c_val = .{ true, null, null, null };
        },
        // --sort-files is rg's deprecated alias for --sort=path. --sort/--sortr
        // take a key; `none` clears the ordering (back to the fast discovery
        // order). `sorted` mirrors "any explicit order" for the deterministic walk.
        .sort_files => |on| {
            o.sort_key, o.sort_reverse, o.sorted = if (on) .{ .path, false, true } else .{ .none, false, false };
        },
        .sort => |desc| {
            o.sort_key = enumOrDie(SortKey, "bad --sort value: {s} (expected none, path, modified, accessed, or created)\n", v.take());
            o.sort_reverse, o.sorted = .{ desc and o.sort_key != .none, o.sort_key != .none };
        },
        .glob_ci => |on| b.glob_ci = on,
        // -A/-B/-C record into a_val/b_val/c_val so -A/-B outrank -C at
        // finalize regardless of argv order; each resets a pending --passthru.
        .ctx_at => |which| {
            const n = toU(v.take());
            (switch (which) {
                .after => &b.a_val,
                .before => &b.b_val,
                .ctx => &b.c_val,
            }).* = n;
            o.passthru = false;
        },
        .num_set => |pair| {
            setVal(o, pair[0], toU(v.take()));
            setVal(o, pair[1], true);
        },
        .regexp => b.addPat(v.take()),
        .typ => |negate| b.addType(v.take(), negate),
        .genus_pick => |g| b.addType(g.name, g.negate),
        .glob => |insensitive| b.addGlob(v.take(), insensitive),
        .maxfsize => o.max_filesize = verdict.toBytes(v.take()),
        .no_ctxsep => o.ctx_sep = null,
        // The `-rn` grep-ism note fires only when the value was bundled into the
        // same short token (taken from this token, not the next argv).
        .replace => {
            const bundled = v.mode == .short and v.j + 1 < v.arg.len;
            o.replace = v.take();
            if (bundled) noteGrepStyleReplace(o.replace.?);
        },
        .file => b.pat_files.append(b.a, v.take()) catch oom(),
        .ignore_file => b.ignore_files.append(b.a, v.take()) catch oom(),
        .type_add => b.addTypeDef(v.take()),
        // --color WHEN: resolved to an actual go/no-go (stdout tty + env) by
        // `color.zig` at emit time — this just records the requested mode.
        .color => o.color = enumOrDie(ColorChoice, "bad --color value: {s}\n", v.take()),
        // One value grammar behind three spellings. Like `--rank`, a bare
        // `--hyperlink` must NOT swallow the next token — that is the pattern
        // (`gist --hyperlink foo`) — so it reads the inline `=value` only.
        // rg's `--hyperlink-format` is value-required and keeps rg's spacing.
        //
        // Naming a destination on the command line TURNS LINKS ON, in either
        // spelling. Typing `--hyperlink=vscode` and getting silence because the
        // probe disagreed is precisely the mystery this whole layer exists to
        // remove — and it is rg's behavior besides. The standing-preference
        // case has its own spelling: `GIST_HYPERLINK=vscode` in a profile says
        // only WHERE, and leaves the probe to decide WHETHER, so piping to a
        // file still cannot smear escapes through it. A flag is an act; an
        // environment variable is a preference. `--hyperlink=auto` remains the
        // way to say both at once, last flag winning as everywhere else.
        .hyperlink => |how| switch (how) {
            .off => o.hyperlink = .never,
            .flag, .format => {
                o.hyperlink_bare = how == .flag and v.inl == null;
                const value = if (how == .format) v.take() else v.inl orelse "always";
                // An empty value WRITTEN OUT is the empty destination — the same
                // thing the `none` alias resolves to. Only a standing preference
                // (`GIST_HYPERLINK=`) may read empty as "no opinion"; a flag is
                // an act, and rg spells this very act `--hyperlink-format=''`.
                const w = if (value.len == 0) beacon.Wish{ .format = "" } else beacon.wish(b.a, value);
                if (w.bad) |msg| die("gist: error parsing flag --{s}: {s}\n", .{ v.name, msg });
                if (w.format) |f| o.hyperlink_format = f;
                // A destination named alone is a request to link; the pair form
                // (`auto,vscode`) is how you name one and still ask the probe.
                // Nowhere to point is the one destination that cannot be a link.
                const nowhere = if (w.format) |f| f.len == 0 else false;
                o.hyperlink = if (nowhere) .never else w.when orelse .always;
            },
        },
        .encoding => {
            const label = v.take();
            o.encoding = intent.encodingFromLabel(label) orelse switch (v.mode) {
                .short => die("bad -E/--encoding value\n", .{}),
                .long => die("bad --encoding value: {s}\n", .{label}),
            };
        },
        .encoding_is => |e| o.encoding = e,
        .pre_glob => b.addPreGlob(v.take()),
        // A preprocessor scope with no preprocessor is not a state a caller can
        // act on, so --no-pre drops both halves (rg's own reading of the flag).
        .pre_off => {
            o.pre = null;
            b.pre_globs.clearRetainingCapacity();
            b.pre_excludes.clearRetainingCapacity();
        },
        .type_clear => b.clearTypeDef(v.take()),
        // --rank takes an OPTIONAL inline count only (`--rank=N`); a bare `--rank`
        // must not swallow the following token — that's the pattern (`gist --rank foo`).
        .rank => {
            o.rank, o.rank_k = .{ true, if (v.inl) |x| toU(x) else o.rank_k };
        },
        // Delivery cadence. One choice, last spelling wins (rg documents each of
        // --line-buffered/--block-buffered as overriding the other). Sizing the
        // block is enough to ask for one: naming a ceiling and then not getting
        // block buffering would be a silently ignored flag.
        .buffered => |mode| o.buffering = mode,
        // A size composes with whichever cadence is in force — the line policy
        // holds an unterminated tail, and this is that tail's ceiling too. The
        // exception is zero: a buffer that can hold nothing is not a small
        // buffer, it is no buffer, so it names the cadence outright (and a
        // later --line-buffered still overrides it, like every other pair).
        .bufsize => {
            o.buffer_size = verdict.toBytes(v.take());
            if (o.buffer_size == 0) o.buffering = .off else if (o.buffering == .auto) o.buffering = .block;
        },
        // -p/--pretty is rg's alias for --color always --heading --line-number.
        // Both of the latter go through `b.locus`, not the resolved `Opts`
        // bools, so a later -N/--no-heading still wins — an alias sets a
        // default, it does not outrank a flag the user spelled out afterwards.
        .pretty => {
            o.color, b.locus.heading, b.locus.line = .{ .always, true, true };
        },
        // --plain is the inverse pole, and the only one of gist's three
        // destination-conditional behaviors that is not already spellable:
        // `--color never` and a cadence have flags, but the terminal long-line
        // guard is keyed on the real fd. `o.plain` is what stands that down.
        .plain => {
            o.color, o.plain = .{ .never, true };
            if (o.buffering == .auto) o.buffering = .block;
        },
        .engine_is => |e| o.engine = e,
        .engine => o.engine = enumOrDie(Engine, "bad --engine value: {s} (expected default, pcre2, or auto)\n", v.take()),
        .noop, .no_config => {},
        .noop_val => _ = v.take(),
        .colors => {
            const spec = v.take();
            if (color.validateColorSpec(spec)) |msg|
                die("gist: error parsing flag --colors: {s}\n", .{msg});
            b.color_specs.append(b.a, spec) catch oom();
        },
        .unsupported => switch (v.mode) {
            .short => die("-{c} unsupported by design — use ripgrep for this\n", .{v.arg[v.j]}),
            .long => die("--{s} unsupported by design — use ripgrep for this\n", .{v.name}),
        },
    }
}

fn parseShort(b: *Builder, arg: []const u8, i: *usize, all: []const []const u8) void {
    var j: usize = 1;
    while (j < arg.len) : (j += 1) {
        const spec = flag_catalog[short_map[arg[j]] orelse die("unknown flag -{c}\n", .{arg[j]})];
        var v = ValSrc{ .mode = .short, .i = i, .all = all, .arg = arg, .j = j };
        apply(b, spec.action, &v);
        if (v.consumed) return; // the value ate the rest of the bundle (or the next argv)
    }
}

fn parseLong(b: *Builder, arg: []const u8, i: *usize, all: []const []const u8) void {
    const body = arg[2..];
    const eq = std.mem.indexOfScalar(u8, body, '=');
    const name = body[0 .. eq orelse body.len];
    const spec = flag_catalog[catalog.long_map.get(name) orelse die("unknown flag --{s}\n", .{name})];
    var v = ValSrc{ .mode = .long, .i = i, .all = all, .name = name, .inl = if (eq) |e| body[e + 1 ..] else null };
    apply(b, spec.action, &v);
}

/// Parse a full `rg [flags] <pattern> [PATH...]` argv into a `Parsed`. Fails loud
/// (exit 2) on a missing pattern, a bad numeric value, or an unsupported flag.
pub fn parseArgv(a: std.mem.Allocator, args: []const []const u8) Parsed {
    var b = Builder{ .a = a };
    // The tree's own type names, before argv, so `-t billy` resolves and an
    // explicit `--type-add` on the line can still redefine what the charter
    // declared. Same grammar as the flag — the charter carries `--type-add`
    // specs, not a second dialect nobody would learn twice.
    if (charter.governing()) |c| for (c.types) |spec| b.addTypeDef(spec);
    var flags_done = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!flags_done and std.mem.eql(u8, arg, "--")) {
            flags_done = true;
        } else if (!flags_done and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            parseLong(&b, arg, &i, args);
        } else if (!flags_done and arg.len >= 2 and arg[0] == '-') {
            parseShort(&b, arg, &i, args);
        } else if (b.pat == null and b.pat_files.items.len == 0) {
            // First bare arg is the pattern — unless a pattern source already
            // exists (`-f FILE`), in which case every positional is a PATH.
            b.pat = arg;
        } else {
            b.roots.append(a, arg) catch oom();
        }
    }
    // --files / --type-list take no pattern; a stray "pattern" is actually a path.
    if (b.o.noPattern()) {
        if (b.pat) |p0| {
            b.roots.insert(a, 0, p0) catch oom();
            b.pat = null;
        }
    } else if (b.pat == null and b.pat_files.items.len == 0) {
        die("usage: rg [flags] <pattern> [PATH...]\n", .{});
    }
    if (b.o.hyperlink_bare) if (b.pat) |p0| noteMisspacedHyperlink(p0);
    // Assemble the in-argv patterns (bare / -e / --regexp); pattern FILES are read
    // later by the caller (needs IO) and appended there.
    var pats: std.ArrayList([]const u8) = .empty;
    if (b.pat) |p0| pats.append(a, p0) catch oom();
    pats.appendSlice(a, b.extra_pats.items) catch oom();
    // -A/-B take precedence over -C regardless of order (ripgrep's rule).
    b.o.after = b.a_val orelse b.c_val orelse 0;
    b.o.before = b.b_val orelse b.c_val orelse 0;
    // -u = --no-ignore, -uu = +hidden, -uuu = +--binary (rg's tiers). gist's
    // --binary searches binary files in full (see Opts.binary), so -uuu brings the
    // whole tree — ignored, hidden, and binary — online.
    if (b.o.smart_case and !b.o.caseless) b.o.caseless = for (pats.items) |pp| {
        if (verdict.hasUpper(pp)) break false;
    } else true;
    return b.seal(pats.toOwnedSlice(a) catch oom());
}

// Test-plane shorthand: `parseArgv` borrows from a caller-owned parse-time
// arena by contract, so the tests lean on the process-lifetime page allocator
// instead of re-declaring a per-test arena (nothing to free before exit).
const t = std.testing;
const ta = std.heap.page_allocator;

test "sort modes preserve ripgrep walker semantics" {
    const sorted = parseArgv(ta, &.{ "--sort", "path", "needle", "root-a", "root-b" });
    try t.expect(sorted.opts.sorted);
    try t.expectEqual(SortKey.path, sorted.opts.sort_key);
    try t.expect(!sorted.opts.sort_reverse);

    const unsorted = parseArgv(ta, &.{ "--sort=none", "needle", "root-a", "root-b" });
    try t.expect(!unsorted.opts.sorted);
    try t.expectEqual(SortKey.none, unsorted.opts.sort_key);
}

test "sort key + direction: every rg key, ascending and reversed" {

    // --sort <key> is ascending; --sortr <key> flips only the direction bit.
    inline for (.{ "modified", "accessed", "created", "path" }) |k| {
        const asc = parseArgv(ta, &.{ "--sort", k, "needle" });
        try t.expectEqual(std.meta.stringToEnum(SortKey, k).?, asc.opts.sort_key);
        try t.expect(!asc.opts.sort_reverse and asc.opts.sorted);
        const desc = parseArgv(ta, &.{ "--sortr", k, "needle" });
        try t.expectEqual(std.meta.stringToEnum(SortKey, k).?, desc.opts.sort_key);
        try t.expect(desc.opts.sort_reverse and desc.opts.sorted);
    }
    // --sort-files is rg's deprecated alias for --sort=path (ascending).
    const sf = parseArgv(ta, &.{ "--sort-files", "needle" });
    try t.expectEqual(SortKey.path, sf.opts.sort_key);
    try t.expect(sf.opts.sorted and !sf.opts.sort_reverse);
    // `--sortr none` collapses to no ordering (reverse of nothing is nothing).
    const rnone = parseArgv(ta, &.{ "--sortr=none", "needle" });
    try t.expect(!rnone.opts.sorted and !rnone.opts.sort_reverse);
    try t.expectEqual(SortKey.none, rnone.opts.sort_key);
}

test "-j/--threads caps the worker pool; both spellings, inline + spaced" {
    try t.expectEqual(@as(usize, 3), parseArgv(ta, &.{ "-j3", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 4), parseArgv(ta, &.{ "-j", "4", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 8), parseArgv(ta, &.{ "--threads=8", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 0), parseArgv(ta, &.{"needle"}).opts.threads); // unset = adaptive
}

test "negation flags are last-wins toggles, not default-state no-ops" {

    // Each --no-X genuinely undoes an earlier --X (ripgrep's left-to-right rule),
    // and a later --X wins again.
    try t.expect(!parseArgv(ta, &.{ "--heading", "--no-heading", "x" }).opts.heading);
    try t.expect(parseArgv(ta, &.{ "--no-heading", "--heading", "x" }).opts.heading);
    try t.expect(!parseArgv(ta, &.{ "--trim", "--no-trim", "x" }).opts.trim);
    try t.expect(!parseArgv(ta, &.{ "--stats", "--no-stats", "x" }).opts.stats);
    try t.expect(!parseArgv(ta, &.{ "-L", "--no-follow", "x" }).opts.follow);
    try t.expect(parseArgv(ta, &.{ "--no-follow", "-L", "x" }).opts.follow);
}

test "--one-file-system records the device-boundary intent" {
    try t.expect(parseArgv(ta, &.{ "--one-file-system", "x" }).opts.one_file_system);
    try t.expect(!parseArgv(ta, &.{"x"}).opts.one_file_system);
}

test "-rn keeps ripgrep replace semantics but is flagged as a grep-ism" {

    // Parity is sacred: `-rn` must still parse as --replace=n, exactly like rg.
    const p = parseArgv(ta, &.{ "-rn", "needle", "root" });
    try t.expectEqualStrings("n", p.opts.replace.?);
    try t.expect(!p.opts.line_num);

    // The stderr note fires only for bundle-shaped values, never for real
    // replacement templates or an unbundled `-r VALUE`.
    try t.expect(looksLikeFlagBundle("n"));
    try t.expect(looksLikeFlagBundle("ni"));
    try t.expect(!looksLikeFlagBundle("$1"));
    try t.expect(!looksLikeFlagBundle("REDACTED"));
    try t.expect(!looksLikeFlagBundle(""));
    const spaced = parseArgv(ta, &.{ "-r", "n", "needle", "root" });
    try t.expectEqualStrings("n", spaced.opts.replace.?);
}

test "content-transform flags parse into Opts" {
    const Encoding = intent.Encoding;
    const z = parseArgv(ta, &.{ "-z", "needle", "logs" });
    try t.expect(z.opts.search_zip);

    const e = parseArgv(ta, &.{ "-E", "utf-16le", "needle", "f" });
    try t.expectEqual(Encoding.utf16le, e.opts.encoding);
    // WHATWG folds latin1 into windows-1252 (encoding_rs parity), and the CJK
    // labels the pitch names explicitly now resolve rather than failing loud.
    const e2 = parseArgv(ta, &.{ "--encoding=latin1", "needle", "f" });
    try t.expectEqual(Encoding.windows_1252, e2.opts.encoding);
    try t.expectEqual(Encoding.shift_jis, parseArgv(ta, &.{ "-E", "sjis", "needle", "f" }).opts.encoding);
    try t.expectEqual(Encoding.gb18030, parseArgv(ta, &.{ "-E", "gbk", "needle", "f" }).opts.encoding);
    try t.expectEqual(Encoding.euc_jp, parseArgv(ta, &.{ "--encoding=euc-jp", "needle", "f" }).opts.encoding);

    const pre = parseArgv(ta, &.{ "--pre", "/bin/cat", "--pre-glob", "*.gz", "--pre-glob", "!*.tmp", "needle", "d" });
    try t.expectEqualStrings("/bin/cat", pre.opts.pre.?);
    try t.expectEqual(@as(usize, 1), pre.opts.pre_globs.len);
    try t.expectEqualStrings("*.gz", pre.opts.pre_globs[0]);
    try t.expectEqual(@as(usize, 1), pre.opts.pre_excludes.len);
    try t.expectEqualStrings("*.tmp", pre.opts.pre_excludes[0]);

    // -uuu now brings the whole tree online: --no-ignore + hidden + --binary.
    const uuu = parseArgv(ta, &.{ "-uuu", "needle", "d" });
    try t.expect(uuu.opts.no_ignore and uuu.opts.hidden and uuu.opts.binary);
}

test "buffering is one last-wins choice, and a named size asks for a block" {
    const Buffering = intent.Buffering;
    try t.expectEqual(Buffering.auto, parseArgv(ta, &.{"x"}).opts.buffering);
    try t.expectEqual(Buffering.line, parseArgv(ta, &.{ "--line-buffered", "x" }).opts.buffering);
    // rg documents each spelling as overriding the other, in argv order.
    try t.expectEqual(Buffering.block, parseArgv(ta, &.{ "--line-buffered", "--block-buffered", "x" }).opts.buffering);
    try t.expectEqual(Buffering.line, parseArgv(ta, &.{ "--block-buffered", "--line-buffered", "x" }).opts.buffering);

    // Naming a ceiling is enough to ask for the policy it sizes — otherwise
    // --buffer-size on a terminal would be a silently ignored flag.
    const sized = parseArgv(ta, &.{ "--buffer-size=128K", "x" });
    try t.expectEqual(@as(usize, 128 << 10), sized.opts.buffer_size);
    try t.expectEqual(Buffering.block, sized.opts.buffering);
    // …but it never overrides a cadence the user spelled out.
    try t.expectEqual(Buffering.line, parseArgv(ta, &.{ "--line-buffered", "--buffer-size", "8192", "x" }).opts.buffering);

    // Zero is the exception, because it is not a size: a buffer that can hold
    // nothing is no buffer, so it names the cadence — over a cadence already
    // spelled, and under one spelled after it (last-wins, like every pair).
    try t.expectEqual(Buffering.off, parseArgv(ta, &.{ "--buffer-size=0", "x" }).opts.buffering);
    try t.expectEqual(Buffering.off, parseArgv(ta, &.{ "--line-buffered", "--buffer-size=0", "x" }).opts.buffering);
    try t.expectEqual(Buffering.line, parseArgv(ta, &.{ "--buffer-size=0", "--line-buffered", "x" }).opts.buffering);
}

test "-p/--pretty sets three defaults that a later flag still outranks" {
    const p = parseArgv(ta, &.{ "-p", "x" });
    try t.expectEqual(ColorChoice.always, p.opts.color);
    try t.expect(p.opts.heading and p.opts.line_num);
    // The alias goes through `b.locus`, so -N after it wins (the same rule that
    // lets -N override --vimgrep's implied line numbers).
    try t.expect(!parseArgv(ta, &.{ "-p", "-N", "x" }).opts.line_num);
    try t.expect(!parseArgv(ta, &.{ "--pretty", "--no-heading", "x" }).opts.heading);
    try t.expectEqual(ColorChoice.never, parseArgv(ta, &.{ "-p", "--color", "never", "x" }).opts.color);
}

test "--plain is the pipe pole: no color, no tty guard, coalesced" {
    const p = parseArgv(ta, &.{ "--plain", "x" });
    try t.expect(p.opts.plain);
    try t.expectEqual(ColorChoice.never, p.opts.color);
    try t.expectEqual(intent.Buffering.block, p.opts.buffering);
    // It picks a cadence only when none was asked for.
    try t.expectEqual(intent.Buffering.line, parseArgv(ta, &.{ "--line-buffered", "--plain", "x" }).opts.buffering);
    try t.expect(!parseArgv(ta, &.{"x"}).opts.plain);
}

test "an empty hyperlink value is the none alias, not a request to link" {
    // rg's `--hyperlink-format=''` disables hyperlinks. gist read empty as "no
    // preference" — the right reading for GIST_HYPERLINK= in a profile, the
    // wrong one for a flag, which promoted it to `always` with the DEFAULT
    // destination and linked every path the caller had just asked to unlink.
    try t.expectEqual(intent.Hyperlink.never, parseArgv(ta, &.{ "--hyperlink-format=", "x" }).opts.hyperlink);
    try t.expectEqual(intent.Hyperlink.never, parseArgv(ta, &.{ "--hyperlink=", "x" }).opts.hyperlink);
    try t.expectEqual(intent.Hyperlink.never, parseArgv(ta, &.{ "--hyperlink=none", "x" }).opts.hyperlink);
    // A named destination still turns links on, and a bare flag still forces them.
    try t.expectEqual(intent.Hyperlink.always, parseArgv(ta, &.{ "--hyperlink=vscode", "x" }).opts.hyperlink);
    try t.expectEqual(intent.Hyperlink.always, parseArgv(ta, &.{ "--hyperlink", "x" }).opts.hyperlink);
}

test "recordTerm names the byte a finished output record ends with" {
    // Line buffering must split on the terminator the PRINTER used, not on a
    // hardcoded '\n' — a --null-data stream contains none.
    try t.expectEqual(@as(u8, '\n'), parseArgv(ta, &.{"x"}).opts.recordTerm());
    try t.expectEqual(@as(u8, 0), parseArgv(ta, &.{ "--null-data", "x" }).opts.recordTerm());
    try t.expectEqual(@as(u8, '\n'), parseArgv(ta, &.{ "--crlf", "x" }).opts.recordTerm()); // "\r\n"
    // --null NUL-terminates the paths the enumeration modes print…
    try t.expectEqual(@as(u8, 0), parseArgv(ta, &.{ "-l", "--null", "x" }).opts.recordTerm());
    // …and nothing else: a content search still ends each line with '\n'.
    try t.expectEqual(@as(u8, '\n'), parseArgv(ta, &.{ "--null", "x" }).opts.recordTerm());
}

test "enumeration() marks every compact per-file mode, and no content mode" {
    // The set exempted from the soft context cap (`corpus.exemptSoftCap`): each
    // must classify as enumeration so its result SET stays complete + reproducible
    // rather than a soft-cap-truncated, order-dependent subset.
    for ([_][]const []const u8{
        &.{ "-l", "needle", "d" }, // --files-with-matches
        &.{ "--files-without-match", "needle", "d" },
        &.{ "-c", "needle", "d" }, // --count
        &.{ "--count-matches", "needle", "d" },
        &.{"--files"}, // pattern-free listing
    }) |argv| try t.expect(parseArgv(ta, argv).opts.enumeration());

    // Content/structured modes carry real volume — the cap is theirs to keep,
    // and their truncation is already ordered/deterministic.
    for ([_][]const []const u8{
        &.{ "needle", "d" }, // default line search
        &.{ "-o", "needle", "d" }, // only-matching
        &.{ "-C", "2", "needle", "d" }, // context
        &.{ "--json", "needle", "d" },
    }) |argv| try t.expect(!parseArgv(ta, argv).opts.enumeration());
}
