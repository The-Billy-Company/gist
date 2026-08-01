<!--
doc_radar:
  paths_exist:
    - src/exec/session/warden/warden.zig
    - src/exec/session/warden/ration.zig
    - src/exec/session/warden/standdown.zig
  sentinels:
    - file: src/exec/session/warden/warden.zig
      description: the ration is charged wholesale into per-thread lanes, swept back before any refusal, with relief tried before a refusal
      contains: ["pub fn attend", "fn charge", "fn beg", "fn sweep", "fn refill", "const Lane", "align(std.atomic.cache_line)"]
    - file: src/exec/session/warden/ration.zig
      description: a machine share AND a work-shaped ceiling, both fail-closed to zero
      contains: ["commons_fraction", "resident_ceiling", "arming_floor", "GIST_MEMORY_MB"]
    - file: src/exec/session/warden/standdown.zig
      description: the brake records the budget it refused so it cannot latch
      contains: ["ration_bytes=", "pub fn standing", "pub fn lift"]
    - file: src/exec/session/daemon/serve/serve.zig
      description: the daemon allocates through the meter, not through its raw gpa
      contains: ["Warden.init", "warden.attend", "standdown.mark"]
    - file: src/exec/session/answer/keep.zig
      description: the keep can be surrendered under pressure without deadlocking
      contains: ["pub fn surrender", "tryLock"]
    - file: bench/rungs/warden/bench.zig
      description: the cost of the bound is gated, decomposed against a no-op wrapper, not merely reported
      contains: ["budget_parallel_ns", "budget_serial_ns", "const Passthru", "WardenOverheadRegressed"]
-->

# `warden/` — what a resident daemon may hold, and what happens when it wants more

A `gist serve` daemon is a background process nobody remembers starting. This
folder is the answer to one question about it: **how much memory may it hold?**
— and, more importantly, the machinery that makes the answer binding rather than
aspirational.

| Module                             | Role                                                                                                                                                                                                                                                             |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`ration.zig`](ration.zig)         | How many bytes this machine will lend: the smaller of a share of physical RAM and a work-shaped ceiling, floored so a machine too small to lend a useful share arms nothing. `GIST_MEMORY_MB` overrides. Zero is a legitimate answer and means "stay cold".        |
| [`warden.zig`](warden.zig)         | The meter that makes the ration binding — an `std.mem.Allocator` wrapper with a hard ceiling, a high-water crest, and a `Relief` hand it asks for reclaimable memory before refusing an allocation.                                                                |
| [`standdown.zig`](standdown.zig)   | The durable note a daemon leaves when it will not fit, so the next query answers cold instead of re-staging a daemon that dies the same way. Records the budget it refused, and expires.                                                                           |

## Why a wrapper instead of an RSS check

The intuitive design — sample RSS on a timer, log or exit when it looks bad — is
the one that fails. It is advisory (the process is already over budget by the
time anyone looks), racy (the interesting growth happens between two samples),
and opt-in at every call site that has to remember to ask. The daemon that
prompted this folder was not missing a warning. It was missing a **refusal**.

So the bound sits where allocation happens. `serve.run` receives one allocator
and threads it into everything it builds, so wrapping that one value at that one
seam covers the whole resident set — mirror docs, the trigram index, overlay
entries, the answer keep, per-query arenas. There is no second allocator to
reach for, which is what makes the ceiling a property of the daemon rather than a
habit of its authors.

What it deliberately does not cover: `content.shard` bytes reached through an
mmap are page-cache pages the kernel evicts under pressure, and
`irregex/src/exec/session/conduit/shm.zig`'s per-answer handoff buffers are
unmapped when the answer ends. Neither is heap this process must account for.

## Refusal is routing, not failure

Crossing the ceiling surfaces as `error.OutOfMemory`, which in a general program
is a fatal surprise and here is the ordinary warm→cold declinature this whole
tier is built on. The resident path is an accelerator; the cold walk answers
every query correctly; no resident allocation sits on a path that panics on OOM.
A session that cannot fit hands its work back to the tier that never needed to —
the same fail-closed edge `irregex/src/exec/session/watch/budget.zig` takes when
it arms zero watches.

Relief comes first, because some of what a session holds is pure cache. The
answer keep is rendered output that is by construction recomputable, so the
warden asks for it back before declining a query. `Keep.surrender` **tries** its
lock rather than taking it: the hand runs inside a failing allocation, possibly
on a thread already inside `retain` — which allocates while holding that lock —
so taking it would deadlock the daemon against itself.

## A ceiling alone would have made things worse

Bound the daemon and nothing else, and a tree that does not fit gets a spawn
storm: the daemon meets the ceiling while loading, exits, the next query finds no
rendezvous and spawns a replacement, and the tree now pays a fork, an exec, and a
partial mirror load *per query*. That is worse than the unbounded daemon it
replaced. `standdown.zig` is why the ceiling is safe to impose.

That brake has one failure mode worth naming, because the first cut had it: the
note stops the spawn, and only a successful spawn lifts the note. A refusal that
covered every later attempt would strand the warm tier for the whole expiry, with
a raised `GIST_MEMORY_MB` sitting dead and nothing to say it had been read. So
the note records **which ration was refused**, and a client that may spend more
than the refused daemon could is making a different attempt and gets to try.

## The numbers, and why they are what they are

Measured by the meter itself on this repo (~21k indexed files, 223 MB
`content.shard`):

| Quantity                    | Bytes   |
| --------------------------- | ------- |
| Settled resident set        | 583 MB  |
| Transient load crest        | 2793 MB |

The crest is ~5× the steady state because the warm trigram build is out-of-place:
`irregex/src/corpus/index/trigrams/trigram.zig`
extracts ~138 M postings at 8 bytes each into per-shard buffers and
counting-sorts them into a second buffer the same size, so the build transiently
costs two ~1.1 GB posting arrays on top of the mirror.

A ration has to clear the peak or the session cannot load at all, so
`resident_ceiling` is currently sized by that peak rather than by the steady
state — which is an honest weakness, not a design goal. **When the build peak
comes down, that constant is the one to tighten**, and `ration.zig`'s tests pin
the measurements that would justify it.

## What the ceiling costs — lanes, and why there had to be lanes

A safety bound that slows the daemon down is not worth having, so the overhead is
measured rather than assumed, by [`bench/rungs/warden/`](../../../../bench/rungs/warden/bench.zig)
(`zig build warden`), which **fails** rather than merely reporting.

The bench prices three arms against the allocator the daemon actually receives in
ReleaseFast (`std.heap.smp_allocator`, per-CPU sharded), in an alloc/free loop
doing no work between allocations — the most adversarial shape there is:

- **bare** — the backing allocator, called directly.
- **passthru** — a wrapper that forwards and accounts nothing, isolating what
  interposing an `Allocator` costs at all.
- **warden** — passthru plus the bound.

Decomposing this way is what found the real problem. `passthru − bare` is
**0.1–0.6 ns/op**: wrapping an allocator is nearly free, so every cost belonged
to the accounting, and the first design's accounting was one shared counter
charged per allocation:

| Shape               | bare      | one shared counter | lane-sharded |
| ------------------- | --------- | ------------------ | ------------ |
| serial, 16-64 B     | 4.3 ns/op | 7.3 ns/op          | 8.4 ns/op    |
| 8 threads, 16-64 B  | 2.5 ns/op | 217 ns/op          | 2.6 ns/op    |
| 8 threads, 0.5-2 KB | 0.5 ns/op | 230 ns/op          | 1.1 ns/op    |

(`bare` as measured alongside the lane-sharded arm; the middle column is the
earlier design on the same machine. Run it yourself — the numbers move with the
machine's load, which is why the bench compares arms within a single run rather
than trusting a recorded figure.)

The middle column is a bound costing **350× the work it guards**.
`smp_allocator` scales precisely by giving each CPU its own shard and touching no
shared line; a global counter in front of it reintroduces exactly the contention
it was built to avoid. The counter *is* the ceiling, so this looked inherent.

It is not. The repair is to stop treating a wholesale fact as a retail one:
`charge` claims **256 KiB at a time** into a per-thread [`Lane`](warden.zig) —
one counter per cache line, carrying its own copy of the backing allocator so the
whole fast path lives on a single line — and allocations spend from that lane. A
thread touches shared state roughly once per 256 KiB instead of once per
allocation, which is why the right-hand column is indistinguishable from no
metering (**0.4–0.9 ns/op** over passthru, inside machine noise).

**The bound stays absolute**, because the shared counter tracks *reserved* bytes,
not live ones. Lane credit has already been charged, so live usage is always
`held` minus what lanes hold unspent — never more than `held`, and so never more
than the ration. Parked credit can only make the warden *stricter* than
necessary, and `sweep` pulls every lane back before anything is refused, so
strictness never becomes a false refusal. Two tests pin exactly that: a lane may
not hoard what the ceiling needs (it fails if `sweep` is removed), and eight
workers with a ration big enough for many batches still never cross it.

Lanes are process-lifetime slots, borrowed by index and never returned. That is
deliberate: a dead thread's parked credit stays in the warden's array, reachable
by `sweep` and re-spendable by whoever borrows the lane next, so nothing is
stranded and no thread-exit hook is needed — Zig does not offer one.

What remains is a floor, not a wart. A hard ceiling must claim on alloc and
release on free, and two uncontended atomic read-modify-writes cost what they
cost (~2.2–3.6 ns on this machine). The serial column is therefore slightly
*worse* than the shared-counter version, which paid the same two atomics on a
line it shared with fields it was already reading. That trade is obviously right:
it buys a 230× improvement in the shape the daemon actually runs in. The bench
budgets the two shapes separately for this reason — the parallel budget catches a
return to shared state, the serial budget says "two atomics, and no more".

End-to-end, none of it is visible. Measured against the same binary with the
wrapper removed, alternating arms across rounds:

| Path                      | bare    | metered | ratio |
| ------------------------- | ------- | ------- | ----- |
| mirror load + index build | 1675 ms | 1650 ms | 0.99  |
| warm query                | 3.7 ms  | 3.6 ms  | 0.95  |

Both land inside run-to-run spread, and which arm wins flips between rounds —
measured *before* lanes, so the current allocator is strictly faster than what
produced those figures. The metered path was never hot end-to-end because the two
big consumers do not allocate in the adversarial shape: a query allocates through
a per-query [`ArenaAllocator`](../daemon/serve/answer.zig), which takes a few
large chunks and serves everything small from inside them, and the mirror's
per-document allocations are whole file bodies whose read cost dwarfs an atomic.
Lanes mean the adversarial shape is no longer expensive either, so code on the
warm path no longer has to avoid it — though an arena is still good practice
against `smp_allocator` regardless.

Two smaller layout facts came out of the same measurements, and both are the
opposite of the intuitive choice:

- `held` and `crest` deliberately **share** one cache line. They are the two
  words a successful charge touches, so once a core owns the line for the write
  the read is free; giving them separate lines cost 1.3 ns/op. What must not
  share with them is the diagnostics, whose rare writes would invalidate the
  counter every worker contends for.
- `crest` is a diagnostic, so `charge` reads it and performs the `fetchMax` only
  when the bar is actually cleared. An unconditional second read-modify-write on
  the hot line cost 293 ns/op against 117 for the conditional, and skipping is
  sound because the crest only ever rises.

## Reading the daemon's own report

A daemon that loads says what the load cost, because the crest is the number a
ration has to accommodate and it is invisible otherwise:

```
gist serve: warm on .gist/gistd.sock (0 roots, 8 workers,
            held 583 MB of a 4096 MB ration, load crest 2793 MB)
```

A daemon that does not fit says so instead, and leaves the note:

```
gist serve: mirror does not fit the 1024 MB ration (held 927 MB)
            — standing down, queries answer cold
```
