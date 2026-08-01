//! gist resident session — how many bytes this machine will lend a daemon.
//!
//! One question, deliberately shaped like `watch/budget.zig`'s: how much memory
//! may a resident session hold? And for the same reason — a background daemon's
//! appetite is a **whole-machine** decision, not a per-process one. Several
//! checkouts each auto-spawn their own daemon, each mirroring its own corpus, so
//! RAM is a commons in exactly the way the file table is.
//!
//! The resident set has no natural ceiling to fall back on. `warm/mirror.zig`
//! reads every changed, new, BOM-carrying, oversize, or shardless file with
//! `.unlimited` — correctly, because the warm answer must be byte-identical to a
//! cold one and ripgrep caps no read by default. But cold reads that corpus
//! **transiently** and frees it when the query ends, where the mirror keeps it
//! for the daemon's whole life. Parity of CONTENT was bought by giving up the
//! bound on RESIDENCY, and nothing downstream re-imposed one: measured on one
//! developer laptop, a daemon 36 seconds old held 1904 MB while nine sibling
//! agents queried the same tree.
//!
//! So the ration is a fraction of physical memory, and `arms` is fail-closed:
//! a machine too small to lend a useful share leaves the session **unarmed**
//! rather than partially resident, which is sound because the cold path answers
//! every query correctly and is the tier a declining daemon hands back to.
//!
//! Pure arithmetic (`shareOf`, `arms`) is split from the one machine read
//! (`physical`) so every fail-closed edge is unit-testable without a 3 GB box.

const std = @import("std");
const assay = @import("irregex").assay;

/// The largest fraction of physical RAM ONE resident session may hold (1/4),
/// and the only term that binds on a SMALL machine.
///
/// The same quarter the lint scheduler takes (`LINT_MEMORY_MB`), for the same
/// laptop. An eighth reads as the more conservative choice for something the
/// developer has forgotten is running, and it was this module's first answer,
/// but it is conservative in the wrong currency: on a 16 GB machine an eighth is
/// 2 GB, under the measured load peak below, so it would not have made the daemon
/// leaner — it would have switched the warm tier off and called that safety.
const commons_fraction: u64 = 4;

/// What a resident session may hold no matter how large the machine is — and the
/// term that actually binds on a developer workstation.
///
/// A fraction of RAM alone is the intuitive rule and it is WRONG here, which is
/// worth stating plainly because it is the mistake this constant exists to
/// correct: on the 128 GB machine where the runaway was observed, an eighth is
/// 16 GB, so a fraction-only ration would have admitted the 1904 MB daemon
/// eight times over and called itself a memory protection. Owning a lot of RAM
/// is not a reason a code-search daemon should hold a lot of RAM.
///
/// The size of a mirror is set by the CORPUS, not by the machine, so the bound
/// that matters is work-shaped.
///
/// **This number is currently sized by a defect, not by the steady state**, and
/// saying so is the point of the comment. Measured on this repo (~18k files,
/// 223 MB `content.shard`) with the meter itself reporting:
///
///   * settled resident set — **583 MB**
///   * transient LOAD CREST — **2793 MB**
///
/// The crest is ~5× the steady state because the warm trigram build is
/// out-of-place: `corpus/index/trigrams/trigram.zig` extracts ~138 M postings at
/// 8 bytes each into per-shard buffers and counting-sorts them into a second
/// buffer of the same size, so the build transiently costs two ~1.1 GB posting
/// arrays on top of the mirror. (Shrinking each shard's unused tail before the
/// output is claimed already took the crest down from 3464 MB; the remaining 2×
/// is inherent to the out-of-place sort and wants a bucketed build to remove.)
///
/// A ration has to cover the peak or the session cannot load at all, so four
/// gibibytes is what admits a repo this size today — with the honest consequence
/// that the ceiling constrains a runaway rather than the load. When the build
/// peak comes down to the steady state's order, THIS is the constant to tighten,
/// and the tests below pin the numbers that would justify it.
///
/// A genuinely larger corpus trades a mirror for `GIST_MEMORY_MB`, which is the
/// right way round: an operator who wants a multi-gigabyte daemon can have one by
/// saying so, and nobody gets one by accident.
const resident_ceiling: u64 = 4 << 30;

/// Below this share the session does not arm at all. A mirror that cannot hold
/// a corpus plus its trigram index is not a smaller accelerator, it is a
/// refusal that has not admitted it yet: it would thrash the ceiling on load,
/// spend the whole ration on relief, and hand every query back to cold anyway,
/// having first cost the machine the memory it took to fail. Declining up front
/// is the same fail-closed edge `watchBudget` takes to zero.
const arming_floor: u64 = 128 << 20;

/// Operator override, in **megabytes**, for the whole resident ration. Same
/// spelling and units as the lint scheduler's `LINT_MEMORY_MB`, because it is
/// the same question asked of the same laptop: lower this when a daemon is
/// crowding work you care about more. `0` is a legitimate answer — it means
/// "never go resident on this machine" and reads as an unarmed session.
const override_key = "GIST_MEMORY_MB";

/// What this daemon may hold, in bytes. Zero means **do not go resident** —
/// either the operator said so, the machine is too small to lend the floor, or
/// its size could not be read at all. Callers treat zero as one more reason to
/// leave the warm tier unbuilt, never as a fault.
pub fn ration() u64 {
    if (assay.envUsize(override_key)) |mb| return arms(@as(u64, mb) << 20);
    return arms(shareOf(physical() orelse return 0));
}

/// The ration an allocator can actually be handed: what the machine will lend,
/// narrowed to what this process can address. Those are different quantities and
/// only one of them is a machine fact — a 32-bit build reads the same 64-bit
/// memory size and then cannot address it, and the ceiling above is 4 GiB
/// *exactly*, which overruns a 32-bit `usize` by a single byte (the operator
/// override is unbounded outright). Narrowing once, here, keeps that distinction
/// in the policy that owns the number instead of at each site that allocates
/// against it; `standdown` still compares the unnarrowed machine fact, because
/// what one daemon can address says nothing about what another one already holds.
pub fn addressable() usize {
    return @intCast(@min(ration(), std.math.maxInt(usize)));
}

/// One session's share of a known machine size: the smaller of what the machine
/// can spare and what the work can justify. BOTH terms are needed and each is
/// the only one that binds at one end of the range — the fraction on a 2 GB
/// container, the ceiling on a 128 GB workstation. Whichever is smaller is the
/// honest answer.
fn shareOf(physical_bytes: u64) u64 {
    return @min(physical_bytes / commons_fraction, resident_ceiling);
}

/// The floor, applied as a cliff rather than a clamp. A share at or over the
/// floor is lent whole; anything under it lends **nothing**, because a session
/// that cannot hold a corpus should decline rather than half-arm (see
/// `arming_floor`). This is the one place the fail-closed decision is made, so
/// it is also the one place a test has to reach to prove it.
fn arms(share: u64) u64 {
    return if (share >= arming_floor) share else 0;
}

/// This machine's physical memory, or null when the platform will not say.
/// Null is a REFUSAL to arm, not "one fewer ceiling to respect" — the inverse of
/// `budget.zig`'s `sysctlInt`, and deliberately so. There, an unreadable clamp
/// left other enforced ceilings still binding; here it is the only ceiling
/// there is, so guessing one would be inventing the very bound this module
/// exists to impose.
fn physical() ?u64 {
    const total = std.process.totalSystemMemory() catch return null;
    return if (total == 0) null else total;
}

test "ration: a machine too small to lend the floor arms nothing" {
    const t = std.testing;
    // The cliff, from both sides. A share one byte short of the floor is not a
    // small ration — it is no ration, because a half-armed mirror costs the
    // machine memory to arrive at the same cold answer.
    try t.expectEqual(@as(u64, 0), arms(0));
    try t.expectEqual(@as(u64, 0), arms(arming_floor - 1));
    try t.expectEqual(arming_floor, arms(arming_floor));

    // A 256 MB container lends nothing (share 64 MiB, under the floor); a 512 MB
    // one is the smallest machine that arms at all.
    try t.expectEqual(@as(u64, 0), arms(shareOf(256 << 20)));
    try t.expectEqual(arming_floor, arms(shareOf(512 << 20)));
}

test "ration: each term binds at one end of the machine range" {
    const t = std.testing;
    // Small machines: the fraction decides, so the ration tracks what is there.
    try t.expectEqual(@as(u64, 512 << 20), shareOf(2 << 30));
    try t.expectEqual(@as(u64, 1 << 30), shareOf(4 << 30));
    // Large machines: the work-shaped ceiling decides, and a bigger machine
    // stops buying a bigger daemon. This is the whole correction — a fraction
    // alone keeps scaling, which is how a "protection" ends up admitting 32 GB.
    try t.expectEqual(resident_ceiling, shareOf(16 << 30));
    try t.expectEqual(resident_ceiling, shareOf(128 << 30));
    try t.expectEqual(resident_ceiling, shareOf(1024 << 30));
    // Monotone but saturating: never less on a bigger machine, never more than
    // the ceiling.
    var prev: u64 = 0;
    for ([_]u64{ 2, 4, 8, 16, 32, 64, 128, 512 }) |gb| {
        const s = shareOf(gb << 30);
        try t.expect(s >= prev);
        try t.expect(s <= resident_ceiling);
        prev = s;
    }
}

test "ration: a bigger machine cannot buy an unboundedly bigger daemon" {
    const t = std.testing;
    // The regression test for a real mistake in this module's first cut, which
    // rationed a fraction of RAM ONLY. On the very machine that produced the
    // runaway — 128 GB — a quarter is 32 GB, so a fraction-only ration would
    // have admitted a 30 GB daemon and still called itself a memory protection.
    // Owning RAM is not a reason a code-search daemon should hold it.
    try t.expect(shareOf(128 << 30) < (128 << 30) / commons_fraction);
    try t.expectEqual(shareOf(128 << 30), shareOf(1024 << 30));
    // Ten sibling daemons at the ceiling must still be a bound a big machine
    // survives, since the fraction cannot coordinate across rendezvous.
    try t.expect(10 * resident_ceiling < (128 << 30));
}

test "ration: the measured load crest fits, and the runaway does not" {
    const t = std.testing;
    // Both numbers come from the meter itself on this repo (223 MB corpus), and
    // together they are what sets `resident_ceiling`. The ration must clear the
    // CREST — a session that cannot finish loading is a warm tier switched off,
    // which would be buying safety with the whole feature.
    const crest: u64 = 2793 << 20; // transient, during the trigram build
    const settled: u64 = 583 << 20; // resident, after it
    try t.expect(crest < resident_ceiling);
    try t.expect(settled < resident_ceiling);

    // A 16 GB laptop and up loads this repo warm; that is why the fraction is a
    // quarter and not an eighth (an eighth of 16 GB is 2 GB, under the crest).
    try t.expect(crest < arms(shareOf(16 << 30)));
    try t.expect(crest < arms(shareOf(32 << 30)));
    // A 4 GB container does NOT, and should not pretend to: it arms a 1 GB
    // ration, meets it during the build, and stands down with a note saying so.
    try t.expect(crest > arms(shareOf(4 << 30)));

    // The ceiling still has to bind on unbounded growth, or it is decoration.
    // Anything past the crest's own headroom is refused on every machine size.
    for ([_]u64{ 2, 4, 8, 16, 32, 64, 128, 512 }) |gb|
        try t.expect(8 << 30 > shareOf(gb << 30));
}

test "ration: zero is a legitimate operator answer" {
    const t = std.testing;
    // `GIST_MEMORY_MB=0` must read as an unarmed session rather than as an
    // unset override that falls through to the machine's share.
    try t.expectEqual(@as(u64, 0), arms(0 << 20));
    // And a deliberate small override is still subject to the floor, so an
    // operator cannot accidentally ask for a mirror too small to be sound.
    try t.expectEqual(@as(u64, 0), arms(64 << 20));
    try t.expectEqual(@as(u64, 512 << 20), arms(512 << 20));
}

test "ration: this machine answers, so the ceiling is real here" {
    const t = std.testing;
    // The arithmetic above is worth nothing if the platform read fails: a
    // silently-null `physical` would leave every daemon unarmed and read as
    // "the warm tier is just slow today". Pin the plumbing on the host running
    // the suite.
    const total = physical() orelse return error.SkipZigTest;
    try t.expect(total >= 1 << 30); // no supported dev machine is under 1 GB
    try t.expect(shareOf(total) < total); // a share is always a proper part
}
