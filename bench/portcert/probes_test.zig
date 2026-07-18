//! Layer-B drift guard — the probes under `probes/` are byte-faithful copies of
//! two production hot loops (`simd.contains`, `Dfa.docMatch`). A copy that
//! silently drifts from its original would make the port-optimality certificate
//! a lie. So this test feeds identical inputs to BOTH the probe and the real
//! `gist` function and asserts bit-identical results over adversarial random
//! inputs — if the production loop changes and the probe isn't updated in
//! lockstep, `zig build test` fails loudly and the certificate can't ship stale.
//!
//! This is deliberately NOT an oracle test: the reference is the real production
//! code path, not a re-derivation of the probe, so a shared bug can't hide.

const std = @import("std");
const gist = @import("irregex");

const simd_probe = @import("probes/simd_contains.zig");
const dfa_probe = @import("probes/dfa_step.zig");

const Regex = gist.regex.Regex;

// The SIMD `contains` probe must agree with the real `gist.simd.contains` on
// every needle length + every hay, including the boundary regimes the vector
// loop versions on (needle at the very end, hay shorter than a vector, matches
// straddling the scalar tail). Random bytes are drawn from a small alphabet so
// real matches (not just misses) are exercised.
test "simd_contains probe ≡ gist.simd.contains" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    var hay: [512]u8 = undefined;
    var needle: [16]u8 = undefined;

    for (0..20_000) |_| {
        const hlen = rng.intRangeAtMost(usize, 0, hay.len);
        const nlen = rng.intRangeAtMost(usize, 0, 8);
        // Small alphabet ⇒ frequent real hits, so we test the match path too.
        for (hay[0..hlen]) |*b| b.* = rng.intRangeAtMost(u8, 'a', 'd');
        for (needle[0..nlen]) |*b| b.* = rng.intRangeAtMost(u8, 'a', 'd');
        // Occasionally splice the needle into the hay so a match is guaranteed.
        if (nlen > 0 and hlen >= nlen and rng.boolean()) {
            const at = rng.intRangeAtMost(usize, 0, hlen - nlen);
            @memcpy(hay[at .. at + nlen], needle[0..nlen]);
        }
        const h = hay[0..hlen];
        const nd = needle[0..nlen];
        const got = simd_probe.portcert_simd_contains(h.ptr, h.len, nd.ptr, nd.len);
        const want = gist.simd.contains(h, nd);
        try std.testing.expectEqual(want, got);
    }
}

// The DFA transition probe must agree with the real `Dfa.docMatch` for every
// compiled pattern that yields a DFA. `docMatch` may take the accelerated path
// internally; the probe replicates the plain path — but the two are proven
// equivalent (same boolean), so any divergence means the transition recurrence
// itself drifted. Docs carry `\n`, blank lines, and no-trailing-newline tails
// to exercise the line-reset + `trans_fin` last-byte resolution the probe copies.
test "dfa_step probe ≡ Dfa.docMatch" {
    const gpa = std.testing.allocator;
    const patterns = [_][]const u8{
        "func\\s+\\w+\\(",
        "pgxpool\\.\\w+",
        "^func\\s",
        "[0-9a-f]{8}-[0-9a-f]{4}",
        "return|continue|break",
        "\\w{3,8}",
        ";$",
        "context\\.Context",
        "abc",
        "a[bc]d",
    };

    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rng = prng.random();
    var doc: [1024]u8 = undefined;

    for (patterns) |pat| {
        var re = Regex.compile(gpa, pat) catch continue;
        defer re.deinit();
        const d = re.dfa orelse continue; // powerset blow-up ⇒ Pike VM, no DFA to probe

        for (0..2_000) |_| {
            const dlen = rng.intRangeAtMost(usize, 0, doc.len);
            for (doc[0..dlen]) |*b| {
                const roll = rng.intRangeAtMost(u8, 0, 20);
                b.* = switch (roll) {
                    0, 1 => '\n', // blank lines + line resets
                    else => rng.intRangeAtMost(u8, 0x20, 0x7e), // printable ASCII
                };
            }
            const doc_slice = doc[0..dlen];
            const got = dfa_probe.portcert_dfa_step(
                doc_slice.ptr,
                doc_slice.len,
                d.trans_in.ptr,
                d.trans_fin.ptr,
                &d.class,
                d.is_match.ptr,
                d.start,
                d.dead,
                d.anchored,
                d.empty_match,
            );
            const want = d.docMatch(doc_slice);
            try std.testing.expectEqual(want, got);
        }
    }
}
