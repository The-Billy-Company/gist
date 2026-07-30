A resident daemon now has a memory ration it cannot exceed, instead of an
appetite bounded only by the corpus it happened to be pointed at. Measured on one
laptop before this: a `gist serve` 36 seconds old holding 1904 MB, several of them
resident at once across worktrees, and the machine out of memory.

The new `exec/session/warden/` is three small pieces. `ration.zig` decides how
many bytes this machine will lend — the smaller of a quarter of physical RAM and a
work-shaped ceiling, floored so a machine too small to lend a useful share arms
nothing at all rather than half a mirror (`GIST_MEMORY_MB` overrides). `warden.zig`
makes that binding by being the allocator the daemon builds everything through, so
the ceiling is a property of the process rather than a habit of its callers: one
atomic test-and-add per allocation, which is what keeps eight concurrent workers
from crossing it together and then each discovering it. Meeting it is the ordinary
warm→cold declinature — the cold walk answers every query correctly — and the
answer keep is surrendered first, since rendered answers are recomputable by
construction (`Keep.surrender` tries its lock rather than taking it, because the
hand runs inside a failing allocation on a thread that may already hold it).

`standdown.zig` is why a ceiling was safe to impose at all. Bound the daemon and
nothing else and an unfittable tree gets a spawn storm — meet the ceiling mid-load,
exit, and let the next query fork a replacement that dies the same way, forever.
A daemon that stands down leaves a note beside its socket, and the note records
*which ration* it was refused under, so a raised `GIST_MEMORY_MB` takes effect on
the next query instead of waiting out the expiry: the note blocks the spawn and
only a spawn can lift it, so a refusal that covered every later attempt would have
stranded the warm tier with nothing to say it had already been fixed.

A bound that costs throughput is not worth having, so the overhead is measured by
a gated bench (`zig build warden`) that fails rather than reports, against the
allocator the daemon actually gets (`smp_allocator`) and decomposed against a
wrapper that forwards and accounts nothing. That decomposition is what mattered:
interposing an allocator costs 0.1-0.6 ns/op, so the whole cost was accounting —
and charging one shared counter per allocation cost **217 ns/op with 8 workers
against 0.5 ns bare**, a guard 350x the work it guarded, because `smp_allocator`
scales by giving each CPU its own shard and a global counter reintroduces exactly
the contention it exists to avoid.

Fixed by charging wholesale and spending retail: `charge` claims 256 KiB at a
time into a per-thread lane (one counter per cache line, carrying its own copy of
the backing allocator so the fast path touches a single line), and allocations
spend from the lane. Shared state is touched about once per 256 KiB instead of
once per allocation, which puts the 8-thread cost at 0.4-0.9 ns/op over the
no-op wrapper - inside machine noise, a 230x improvement. The ceiling stays
absolute because the shared counter tracks *reserved* bytes: live usage is always
`held` minus unspent lane credit, so it can never exceed the ration, and `sweep`
reclaims every lane before anything is refused so the strictness never becomes a
false refusal. Lanes are process-lifetime slots borrowed by index, so a dead
thread strands nothing - its credit stays reclaimable, and Zig has no
thread-exit hook to rely on. Two tests pin it: a lane may not hoard what the
ceiling needs (it fails if `sweep` is deleted), and eight workers with room for
many batches still never cross the ration.

What remains is a floor - a hard ceiling must claim on alloc and release on
free, and two uncontended atomics cost ~2.2-3.6 ns - so the serial column is
marginally worse than the shared-counter version in exchange for the 230x
parallel win. End-to-end nothing was ever detectable anyway: mirror load plus
index build 1650 ms metered against 1675 ms bare, warm queries 3.6 ms against
3.7 ms, both inside run-to-run spread with the winner flipping between rounds.
Two layout facts came out of the same measurements, both against intuition:
`held` and `crest` deliberately *share* a cache line (splitting them cost 1.3
ns/op, since a charge writes one and reads the other), while the diagnostics are
pushed off it; and `charge` reads the crest before updating it, because an
unconditional second read-modify-write on the hot line cost 293 ns/op where the
conditional costs 117, and a high-water mark that only rises is safe to skip.

The meter earned its keep immediately by pricing a spike nobody could see. On this
repo the daemon settles at 583 MB but *crests at 2793 MB* while building its warm
trigram index, because that build is out-of-place — ~138 M postings at 8 bytes
each in per-shard buffers, counting-sorted into a second buffer the same size.
Shrinking each shard's unused tail before the output is claimed took the crest
from 3464 MB to 2793 MB with the settled set unchanged and postings byte-identical
(capacity only). The remaining 2× is inherent to the out-of-place sort, and it —
not the steady state — is what currently sizes the ceiling.
