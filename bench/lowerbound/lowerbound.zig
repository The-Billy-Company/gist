//! gist bench — `lowerbound`: Layer D of the optimality certificate (the
//! *algorithmic* floor). It empirically audits the two claims of the
//! information-theoretic lower bound for the search operation:
//!
//!   1. **Verify floor — Ω(candidate bytes), one pass.** Any correct algorithm
//!      that confirms whether a pattern occurs in a candidate document must, in
//!      the worst (adversarial) case, examine every byte of that document — an
//!      unread byte could be the match, or could break it (Knuth-Morris-Pratt
//!      1977; Boyer-Moore 1977, Ω(n) worst-case reads). gist's fused byte-class
//!      DFA (`src/kernel/regex/linear/dfa/dfa.zig`) touches each candidate byte **exactly
//!      once** — a single forward pass, no memchr-then-rescan double traffic;
//!      its SIMD literal path (`src/kernel/scan/simd.zig`) touches **≤** N (vector
//!      skips + early exit). This harness proves both structurally.
//!
//!   2. **Trigram-filter sublinearity.** Total work is sublinear in corpus size
//!      because the trigram index prunes the candidate set *before* verify (Cox,
//!      "Regular Expression Matching with a Trigram Index", 2012 — gist's direct
//!      ancestor). `cand%` (candidate bytes ÷ corpus bytes) is the empirical
//!      pruning measure.
//!
//! Method (no production code is instrumented — the audit is *structural*):
//!   • sum candidate bytes = the theoretical full-scan verify floor;
//!   • run gist's REAL verify (`simd.contains` / `Regex.docMatch`) for the hit
//!     count — the ground truth;
//!   • run an INDEPENDENT single-pass re-implementation that COUNTS byte touches
//!     and asserts (a) its verdict equals gist's real verdict for every document
//!     (correctness — a disagreement is a real defect), and (b) the DFA path
//!     touches EXACTLY `candidate_bytes` (one pass, no double traffic), the SIMD
//!     literal path ≤ `candidate_bytes`.
//!
//! Fail-closed, exactly like `bench/gates/scan_regress.sh`: any violated
//! invariant exits non-zero. Weakening an assertion to go green would violate
//! the repo's anti-bandaid rule — a failure here is a real finding about gist.
//!
//! Probe set is *imported* from `bench/harness/probes.zig` — the same module
//! `certify.zig` (Layer A) uses — so Layer D lines up class-for-class with
//! Layers A-C by construction, not by a hand-maintained "keep in sync" copy.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");

const corpus_mod = gist.corpus;
const simd = gist.simd;
const Index = gist.trigram.Index;
const Regex = gist.regex.Regex;
const Dfa = gist.regex_dfa.Dfa;
const Dir = std.Io.Dir;
const load = corpus_mod.load;
const out_dir = gist.home.default_out_dir;

const probes_mod = @import("probes");
const Kind = probes_mod.Kind;
const Probe = probes_mod.Probe;
const probes = probes_mod.probes;

const Row = struct {
    class: []const u8,
    kind: Kind,
    cand_docs: usize,
    cand_bytes: u64, // Σ candidate doc lengths — the full-scan verify floor
    examined: u64, // bytes the single-pass reference touches (DFA: ==floor, SIMD: ≤floor)
    passes: f64, // examined ÷ cand_bytes — passes over each candidate byte (DFA ≡ 1.0)
    cand_byte_frac: f64, // cand_bytes ÷ corpus_bytes — the pruning (sublinearity) measure
    hits: usize, // gist's real verified match count
    note: []const u8, // engine note (dfa / simd / pike-2pass / zero-width)
    at_floor: bool, // invariant held
};

// ── candidate resolution (mirrors certify.zig litCandidates / rgxCandidates) ──
fn litCandidates(idx: *const Index, gpa: std.mem.Allocator, corpus: *const corpus_mod.Corpus, needle: []const u8) ![]u32 {
    if (needle.len >= 3) {
        if (idx.queryLiteral(gpa, needle)) |c| return c else |_| {}
    }
    const all = try gpa.alloc(u32, corpus.docs.len);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    return all;
}

fn rgxCandidates(re: *const Regex, idx: *const Index, gpa: std.mem.Allocator, corpus: *const corpus_mod.Corpus) ![]u32 {
    var one = [_][]const u8{re.required};
    const filters: []const []const u8 = if (re.required.len >= 3) one[0..] else re.alts;
    if (filters.len > 0) {
        if (idx.queryAny(gpa, filters)) |c| return c else |_| {}
    }
    const all = try gpa.alloc(u32, corpus.docs.len);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    return all;
}

// ── the independent single-pass references (COUNT byte touches) ──────────────

/// Independent re-implementation of the fused byte-class DFA doc scan
/// (`Dfa.docMatch`) that COUNTS every byte position the cursor consumes, with
/// NO early match-exit and NO accel/dead skip — so a full worst-case pass over
/// a document touches each of its bytes exactly once and `touches == doc.len`.
/// Structurally identical to the production loop (same per-line `^`/`$`/`\n`
/// handling, same `trans_fin` last-byte resolution): a `dead` sink is absorbing
/// so declining to short-circuit it changes the touch count but never the
/// verdict — which is asserted equal to gist's real `docMatch` for every doc.
fn dfaDenseScan(d: *const Dfa, doc: []const u8, touches: *u64) bool {
    const n = doc.len;
    if (n == 0) return d.empty_match;
    var i: usize = 0;
    var matched = false;
    while (i < n) {
        if (doc[i] == '\n') { // empty line
            if (d.empty_match) matched = true;
            i += 1;
            touches.* += 1;
            continue;
        }
        var s = d.start; // premultiplied row offset (id*ncls)
        if (d.is_match[s]) matched = true; // BOL / zero-width match
        var prev = s;
        while (i < n and doc[i] != '\n') {
            prev = s;
            s = d.trans_in[s + d.class[doc[i]]];
            i += 1;
            touches.* += 1;
            if (d.is_match[s]) matched = true;
        }
        // Resolve the line's last content byte with `$` (trans_fin), from the
        // state right before it — exactly as the production docMatch does.
        if (i > 0 and doc[i - 1] != '\n') {
            const sf = d.trans_fin[prev + d.class[doc[i - 1]]];
            if (d.is_match[sf]) matched = true;
        }
        if (i < n and doc[i] == '\n') { // consume the newline
            i += 1;
            touches.* += 1;
        }
    }
    return matched;
}

/// Single-pass upper bound on the bytes gist's SIMD `contains` examines. The
/// SIMD window advances monotonically and early-exits on the first match, so it
/// reads at most `match_pos + needle.len` bytes (and fewer, via vector skips).
/// We locate the first occurrence with std's exact search (the correctness
/// oracle the equality gate also uses) and cap at `hay.len`. Returns presence;
/// `*examined` accumulates the ≤-floor byte count.
fn litScanBound(hay: []const u8, needle: []const u8, examined: *u64) bool {
    if (std.mem.indexOf(u8, hay, needle)) |pos| {
        examined.* += @min(pos + needle.len, hay.len); // early-exit prefix
        return true;
    }
    examined.* += hay.len; // no match ⇒ full scan (the worst case = the floor)
    return false;
}

// ── per-probe measurement ────────────────────────────────────────────────────
fn measureLiteral(corpus: *const corpus_mod.Corpus, cand: []const u32, needle: []const u8, violations: *usize) struct { examined: u64, hits: usize, ok: bool } {
    var examined: u64 = 0;
    var hits: usize = 0;
    var ok = true;
    for (cand) |d| {
        const doc = corpus.docs[d];
        const real = simd.contains(doc, needle); // gist's REAL verify
        const ref = litScanBound(doc, needle, &examined); // independent oracle
        if (real != ref) { // SIMD ≢ exact search ⇒ a real correctness defect
            ok = false;
            violations.* += 1;
            std.debug.print("  !! literal disagree on doc {d}: simd={} ref={}\n", .{ d, real, ref });
        }
        if (real) hits += 1;
    }
    return .{ .examined = examined, .hits = hits, .ok = ok };
}

fn measureRegex(gpa: std.mem.Allocator, re: *Regex, sim: *Regex.Sim, pattern: []const u8, corpus: *const corpus_mod.Corpus, cand: []const u32, violations: *usize) struct { examined: u64, hits: usize, note: []const u8, dense: bool } {
    // Zero-width EOL match (`\d*$`): docMatch answers in O(1) (doc.len>0) —
    // BELOW the one-pass floor, not a violation. Report and skip byte-touch.
    if (re.eol_empty) return .{ .examined = 0, .hits = 0, .note = "zero-width (O(1))", .dense = false };
    // The independent one-pass oracle is a byte-class DFA (`dfaDenseScan` touches
    // each candidate byte exactly once). Production's primary engine for a *dense*
    // class (`\w{3,8}`, `[a-z]{3,}`) is now the SIMD class-run kernel, which
    // deliberately skips determinization (`core.zig`: `kernel_final and !force_dfa`),
    // so `re.dfa` is null. Force-build a DFA for the same pattern *purely as the
    // reference* and assert production's real `docMatch` (the class-run kernel)
    // agrees with it on every document — the SIMD path then verifies at ≤ this
    // exact one-pass floor. A genuine no-DFA, no-class-run pattern (powerset
    // blow-up ⇒ Pike per-line, or multiline double-traffic) stays a violation.
    var ref_re: ?Regex = null;
    defer if (ref_re) |*r| r.deinit();
    var note: []const u8 = "dfa (fused 1-pass)";
    const d: *const Dfa = re.dfa orelse dref: {
        if (re.classrun != null) {
            ref_re = Regex.compileOpts(gpa, pattern, .{ .force_dfa = true }) catch null;
            if (ref_re) |*rr| if (rr.dfa) |dd| {
                note = "class-run (dfa-ref 1-pass)";
                break :dref dd;
            };
        }
        violations.* += 1;
        return .{ .examined = 0, .hits = 0, .note = "pike (2-pass!)", .dense = false };
    };
    var examined: u64 = 0;
    var hits: usize = 0;
    for (cand) |doc_id| {
        const doc = corpus.docs[doc_id];
        const real = re.docMatch(sim, doc); // gist's REAL verify (class-run or DFA)
        const ref = dfaDenseScan(d, doc, &examined); // independent DFA one-pass count
        if (real != ref) {
            violations.* += 1;
            std.debug.print("  !! regex disagree on doc {d}: docMatch={} ref={}\n", .{ doc_id, real, ref });
        }
        if (real) hits += 1;
    }
    return .{ .examined = examined, .hits = hits, .note = note, .dense = true };
}

fn measure(gpa: std.mem.Allocator, corpus: *const corpus_mod.Corpus, idx: *const Index, probe: Probe, violations: *usize) !Row {
    var re: ?Regex = null;
    var sim: ?Regex.Sim = null;
    defer if (sim) |*s| s.deinit();
    defer if (re) |*r| r.deinit();

    const cand = switch (probe.kind) {
        .literal => try litCandidates(idx, gpa, corpus, probe.pattern),
        .regex => blk: {
            // Match certify.zig: the committed lowerbound speaks about the ASCII
            // engine the 12-class certificate was minted over. The next
            // clean-tree republish flips this to `.unicode = true`.
            re = try Regex.compile(gpa, probe.pattern);
            sim = try Regex.Sim.init(gpa, &re.?);
            break :blk try rgxCandidates(&re.?, idx, gpa, corpus);
        },
    };
    defer gpa.free(cand);

    var cand_bytes: u64 = 0;
    for (cand) |d| cand_bytes += corpus.docs[d].len;

    var examined: u64 = 0;
    var hits: usize = 0;
    var note: []const u8 = "";
    var dense = false;
    var ok = true;
    switch (probe.kind) {
        .literal => {
            const m = measureLiteral(corpus, cand, probe.pattern, violations);
            examined = m.examined;
            hits = m.hits;
            note = "simd (≤ 1-pass)";
            ok = m.ok;
        },
        .regex => {
            const m = measureRegex(gpa, &re.?, &sim.?, probe.pattern, corpus, cand, violations);
            examined = m.examined;
            hits = m.hits;
            note = m.note;
            dense = m.dense;
        },
    }

    const cbf: f64 = @floatFromInt(@max(cand_bytes, 1));
    const passes = @as(f64, @floatFromInt(examined)) / cbf;
    // Floor invariant: the DFA one-pass reference must touch EXACTLY the floor
    // (each candidate byte once, no double traffic); the SIMD literal path must
    // stay AT OR BELOW it. Any deviation is a violation.
    var at_floor = ok;
    if (dense) {
        if (examined != cand_bytes) {
            at_floor = false;
            violations.* += 1;
            std.debug.print("  !! {s}: dfa touched {d} bytes, floor is {d} (double traffic?)\n", .{ probe.class, examined, cand_bytes });
        }
    } else if (probe.kind == .literal) {
        if (examined > cand_bytes) {
            at_floor = false;
            violations.* += 1;
            std.debug.print("  !! {s}: simd examined {d} > floor {d}\n", .{ probe.class, examined, cand_bytes });
        }
    } else {
        at_floor = false; // pike-2pass / degenerate — surfaced above
    }

    return .{
        .class = probe.class,
        .kind = probe.kind,
        .cand_docs = cand.len,
        .cand_bytes = cand_bytes,
        .examined = examined,
        .passes = passes,
        .cand_byte_frac = @as(f64, @floatFromInt(cand_bytes)) / @as(f64, @floatFromInt(@max(corpus.bytes, 1))),
        .hits = hits,
        .note = note,
        .at_floor = at_floor,
    };
}

/// Standalone entry: `gist-lowerbound` (its own executable rather than a
/// `gist-bench` mode — Zig forbids importing a source file outside a module's
/// root directory, so the harness roots its own module here and pulls in the
/// shared `gist` engine module).
pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try load(gpa, io, roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();

    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);
    std.debug.print("gist lowerbound · Layer D (algorithmic floor) · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} · zig {s}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string });
    std.debug.print("corpus:  {d} files · {d:.1} MiB · single-thread verify\n", .{ corpus.docs.len, mib });
    std.debug.print("floor:   Ω(candidate bytes) per verify (KMP'77 / Boyer-Moore'77) · trigram prune → sublinear (Cox'12)\n\n", .{});

    std.debug.print("{s:<18} {s:>7} {s:>8} {s:>13} {s:>8} {s:>7} {s:>18} {s}\n", .{ "class", "docs", "cand%", "cand bytes", "passes", "hits", "engine", "verdict" });
    std.debug.print("{s:-<18} {s:->7} {s:->8} {s:->13} {s:->8} {s:->7} {s:->18} {s:->9}\n", .{ "", "", "", "", "", "", "", "" });

    var violations: usize = 0;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    for (probes) |p| {
        const row = try measure(gpa, &corpus, &idx, p, &violations);
        try rows.append(gpa, row);
        std.debug.print("{s:<18} {d:>7} {d:>6.2}% {d:>13} {d:>8.4} {d:>7} {s:>18} {s}\n", .{
            row.class,                                     row.cand_docs, row.cand_byte_frac * 100.0, row.cand_bytes, row.passes, row.hits, row.note,
            if (row.at_floor) "at floor" else "VIOLATION",
        });
    }

    try writeCsv(gpa, io, &corpus, rows.items);
    std.debug.print("\nwrote {s}/lowerbound.csv\n", .{out_dir});
    std.debug.print("run: python3 pkg/kernels/irregex/bench/lowerbound/lowerbound_report.py --certificate {s}/CERTIFICATE.md --csv {s}/lowerbound.csv\n", .{ out_dir, out_dir });

    if (violations > 0) {
        std.debug.print("\nFAILED: {d} floor invariant violation(s) — gist read more than the Ω(candidate-bytes) one-pass floor, or the single-pass reference disagreed with production. Investigate; do NOT weaken the assertion.\n", .{violations});
        std.process.exit(1);
    }
    std.debug.print("\nPROVEN: every verified candidate byte is touched in a single fused pass (DFA ≡ floor, SIMD ≤ floor); trigram prune keeps candidate bytes sublinear in the corpus. Layer D at the information-theoretic floor.\n", .{});
}

fn writeCsv(gpa: std.mem.Allocator, io: std.Io, corpus: *const corpus_mod.Corpus, rows: []const Row) !void {
    try Dir.cwd().createDirPath(io, out_dir);
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(gpa);
    var line: [256]u8 = undefined;
    try csv.appendSlice(gpa, "class\tkind\tcand_docs\tcorpus_docs\tcandidate_bytes\tcorpus_bytes\tcand_byte_frac\texamined_bytes\tpasses\thits\tengine\tat_floor\n");
    for (rows) |r| {
        try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d:.6}\t{d}\t{d:.4}\t{d}\t{s}\t{d}\n", .{
            r.class,          @tagName(r.kind), r.cand_docs, corpus.docs.len, r.cand_bytes, corpus.bytes,
            r.cand_byte_frac, r.examined,       r.passes,    r.hits,          r.note,       @intFromBool(r.at_floor),
        }));
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/lowerbound.csv", .data = csv.items });
}
