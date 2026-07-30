<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/exec/session/watch/watch.zig
    - pkg/kernels/irregex/src/exec/session/watch/inotify.zig
    - pkg/kernels/irregex/src/exec/session/watch/kqueue.zig
    - pkg/kernels/irregex/src/exec/session/watch/coverage.zig
    - pkg/kernels/irregex/src/exec/session/watch/budget.zig
    - pkg/kernels/irregex/src/exec/session/watch/notify.zig
    - pkg/kernels/irregex/src/exec/session/watch/rig.zig
  sentinels:
    - file: pkg/kernels/irregex/src/exec/session/watch/notify.zig
      description: the Windows backend subscribes recursively and drains onto a completion port, so a flushSync barrier can collect packets no background thread touched
      contains:
        ["pub fn startNotify", "pub fn drainNotifyLocked", "NtNotifyChangeDirectoryFileEx", "NtRemoveIoCompletion", "NotifyExtended"]
    - file: pkg/kernels/irregex/src/exec/session/watch/rig.zig
      description: the barrier suite both exact backends are judged by lives in one harness rather than once per platform
      contains: ["pub const live", "pub fn withSeededRig"]
    - file: pkg/kernels/irregex/src/exec/session/watch/inotify.zig
      contains: ["pub fn startInotify", "pub fn drainInotifyLocked", "FS_CASEFOLD_FL"]
    - file: pkg/kernels/irregex/src/exec/session/watch/kqueue.zig
      contains: ["pub fn startKqueue", "pub fn drainKqueueLocked", "vnode_notes"]
      absent: ["FSEventStreamCreate"]
    - file: pkg/kernels/irregex/src/exec/session/watch/coverage.zig
      description: the admission walk both selects the watch set and registers each admitted vnode, so the kevent filter is minted here
      contains: ["pub fn coverRoots", "isIgnoreSource", "EVTONLY", "EVFILT.VNODE", "fn vanished"]
    - file: pkg/kernels/irregex/src/exec/session/watch/budget.zig
      contains: ["pub fn watchBudget", "kern.maxfilesperproc", "kern.maxfiles"]
-->

# `watch/` — the freshness watcher backends

The freshness watcher is a pure **accelerator** for the reconcile barrier
(ADR-372, ADR-352 rung 2.5): it keeps a resident session honest about when it
may skip the reconcile walk, and never a correctness dependency — a session
that cannot arm simply reconciles every query (fail-closed). Correctness itself
lives in [`../reconcile/`](../freshness) — this folder only decides _whether, and
how narrowly,_ that barrier has to walk.

[`watch.zig`](watch.zig) is the facade: the public `Watcher(Session)` type, the
shared per-session state, the comptime backend selection, and the cross-backend
invariants. The rest of the folder holds the backend implementations it
dispatches to, each a set of free functions over that generic `Watcher`.

| Module                         | Plane           | Owns                                                                                                                                                                                                                                                                          |
| ------------------------------ | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`watch.zig`](watch.zig)       | facade          | The generic `Watcher(Session)`, the shared state, comptime backend selection, and the lifecycle — including `shed`, which hands every descriptor back and returns the session to the reconcile-always baseline so an idle daemon stops taxing the commons its siblings share. |
| [`inotify.zig`](inotify.zig)   | Linux           | Recursive directory watches, the event loop, coverage extension into directories created after arming, queue-overflow doubt, and casefold detection (a `+F` root stays coarse).                                                                                               |
| [`kqueue.zig`](kqueue.zig)     | macOS events    | The kqueue descriptor itself and the arming (`startKqueue`), draining a batch under the shared consumption lock, per-directory rescan on a membership move, and retiring a descriptor whose vnode left. Owns the `EVFILT_VNODE` note vocabulary (`vnode_notes`) every watch requests. |
| [`coverage.zig`](coverage.zig) | macOS admission | Selects the macOS watch set from the walk's own `Ignore` policy so the descriptor cost stays proportional to the corpus, registers each admitted vnode (`EVFILT_VNODE` + `EV_CLEAR`, `vnode_notes`), owns the policy arena and the key-space arithmetic, classifies the hidden ignore SOURCES that decide admission, and judges which `open(2)` failure may be skipped — only a path that vanished, never one the walk still searches (`vanished`). |
| [`budget.zig`](budget.zig)     | macOS ceiling   | How many vnode watches may be held — clamped against the three ceilings the kernel enforces (`kern.maxfilesperproc`, a bounded share of `kern.maxfiles`, and the raised `RLIMIT_NOFILE`), returning zero (unarmed) rather than a set it cannot register.                      |
| [`notify.zig`](notify.zig)     | Windows         | One recursive `ReadDirectoryChangesW` subscription per root (`NtNotifyChangeDirectoryFileEx` with `WatchTree`), draining onto a single I/O completion port. Owns the change filter, the record walk over both record classes, and the overflow posture.                        |
| [`rig.zig`](rig.zig)           | test harness    | The tree fixture and session rig the barrier suite runs on, so both exact backends are judged by the same cases instead of each proving whatever its own file happened to test.                                                                                                |

`kqueue.zig` and `coverage.zig` are two halves of one macOS backend — the event
engine and the admission walk — split so each reads as a single concern; they
reference each other directly (`coverage` announces and unwinds each watch it
registers via `kqueue.note` / `kqueue.retire`, `kqueue` rescans via
`coverage.coverTree`). The three backends never intersect: every
platform-specific function is gated behind `if (comptime !is_<platform>) return …`,
so the whole folder compiles on every target and the unused backends lower to
nothing.

## What each platform can witness

The three backends are not three spellings of one mechanism; they can witness
different things, and the facade's job is to know which. Linux and Windows both
subscribe **recursively per root**, so a directory created after arming is covered
by the subscription that was already there. macOS registers **one descriptor per
admitted vnode**, which is why it alone needs an admission walk (`coverage.zig`)
and a descriptor ceiling (`budget.zig`) — and why it alone extends coverage by
walking a new subtree.

Windows is the one that can witness *more* than POSIX rather than less, in two
places worth naming because both remove a refusal rather than adding a feature.
A notify record carries the changed entry's **own spelling**, so an `exact`
freshness key arms on a case-insensitive volume — where inotify has to go coarse,
because a `+F` casefold directory reports a name that may not be the name on disk.
And the extended record class carries the changed file's **timestamps in-band**,
so a delivery stamps the annals ledger with that file's own `max(mtime, ctime)`
instead of the drain clock's approximation of it; the wall clock is used only for a
removal, where there is no surviving file to ask.

Losing coverage is where they agree exactly: an `IN_Q_OVERFLOW` on Linux, an
overflowed completion buffer on Windows, and a vnode that could not be re-watched
on macOS all mark doubt **permanently** rather than retrying, because a watcher
that has already missed an unknown set of events cannot bound what it missed.
