//! Layer-B port-optimality probe — the `simd.contains` vector filter loop.
//!
//! A **byte-faithful copy** of `src/kernel/scan/simd.zig`'s `contains`
//! hot loop: splat first+last needle byte, vector-compare both
//! lanes across a V-wide window, AND the masks, `@ctz`-verify survivors. The
//! copy is drift-guarded by `probes_test.zig`, which feeds identical inputs to
//! this function AND the real `gist.simd.contains` and asserts bit-identical
//! results — so if the production loop changes, this probe must too, or CI fails.
//!
//! One loop iteration is bracketed, unconditionally, by `# LLVM-MCA-BEGIN/END`
//! region comments (placed INSIDE the loop body — a marker straddling the loop
//! header gets stranded by LLVM's loop rotation/versioning; inside the body it
//! rides into every cloned copy identically). `llvm-mca` reads those comments in
//! the `-femit-asm` output and reports the region's `Block RThroughput` — the
//! port-pressure ceiling (cycles per iteration). One iteration advances the
//! cursor by `vlen` bytes, so cycles/byte = RThroughput ÷ `vlen`.
//!
//! This loop is **throughput-bound**: successive iterations are independent
//! (only the loop counter carries), so `Block RThroughput` IS the real floor.
//! `vlen` is `std.simd.suggestVectorLength(u8)` exactly as in the real code, so
//! each cross-compiled target uses the width it would truly emit (verified from
//! this probe's asm: znver4 → AVX-512 zmm / 64 B, neoverse-v2 → NEON q / 16 B).

const std = @import("std");

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vlen, u8);
const Mask = std.meta.Int(.unsigned, vlen);

/// Byte-for-byte `simd.contains`, hot filter body bracketed for llvm-mca.
/// `hay`/`needle` are raw pointer+len so the object links with zero Billy deps.
pub export fn portcert_simd_contains(hay_ptr: [*]const u8, hay_len: usize, needle_ptr: [*]const u8, needle_len: usize) bool {
    const hay = hay_ptr[0..hay_len];
    const needle = needle_ptr[0..needle_len];
    const n = needle.len;
    if (n == 0) return true;
    if (n > hay.len) return false;
    if (n == 1) return std.mem.indexOfScalar(u8, hay, needle[0]) != null;

    const first: Vec = @splat(needle[0]);
    const last: Vec = @splat(needle[n - 1]);
    const last_off = n - 1;

    var i: usize = 0;
    while (i + last_off + vlen <= hay.len) : (i += vlen) {
        asm volatile ("# LLVM-MCA-BEGIN simd_contains" ::: .{ .memory = true });
        const bf: Vec = hay[i..][0..vlen].*;
        const bl: Vec = hay[i + last_off ..][0..vlen].*;
        var bits: Mask = @bitCast((bf == first) & (bl == last));
        // Read `bits` at the END marker so the mask-AND + movemask are forced to
        // materialize inside the region (else LLVM sinks them past the marker). No
        // `.memory` clobber here: it spuriously spills the loop-invariant splats to
        // stack and reloads them each iteration, inflating the port bound — the
        // register operand alone anchors the mask without that artifact.
        asm volatile ("# LLVM-MCA-END simd_contains"
            :
            : [bits] "r" (bits),
            : .{});
        while (bits != 0) {
            const j = @ctz(bits);
            const pos = i + j;
            if (std.mem.eql(u8, hay[pos .. pos + n], needle)) return true;
            bits &= bits - 1;
        }
    }
    return std.mem.indexOfPos(u8, hay, i, needle) != null;
}

/// Bytes the vector loop consumes per iteration on THIS compile target — the
/// divisor that turns `Block RThroughput` (cycles/iter) into cycles/byte.
pub export fn portcert_simd_bytes_per_iter() usize {
    return vlen;
}
