---
doc_radar:
  sentinels:
    - description: "machine status contract stays versioned and CLI-addressable"
      file: pkg/kernels/irregex/src/surface/face/gist/status/status.zig
      contains: ["pub const schema_version = 1;", "pub const Snapshot = struct"]
    - description: "status JSON remains discoverable through the CLI"
      file: pkg/kernels/irregex/src/surface/face/gist/main.zig
      contains: 'std.mem.eql(u8, value, "--json")'
    - description: "the warm tier's silent failure is reported, not merely detected"
      file: pkg/kernels/irregex/src/surface/face/gist/status/status.zig
      contains: ["resident: Residency = .none", "fn renderResident"]
---

# surface/face/gist/status — `gist status`

Read-only introspection of the persisted index. Answers the question agents ask
before a search loop: _am I ready to search fast, and how fresh?_

`status.zig` derives a `Snapshot` from the same mmap'd artifacts the query path
loads (`corpus/index/trigrams/persist.zig`) plus the freshness anchor
(`corpus/index/trigrams/fresh.zig`): index presence, files indexed, distinct trigrams,
postings, on-disk size, build age, corpus roots. No build, no scan, no
mutation — a missing index is an actionable `unavailable` state ("run
`gist index`"), never an error, so `status` is safe to call blind.

## Machine contract

`gist status --json` emits one compact, newline-terminated JSON object. It is
derived from the same snapshot as the human report and writes no human prose to
stdout or stderr. The v1 shape is:

```json
{
  "schema_version": 1,
  "state": "ready",
  "index": {
    "path": ".local/gist-verify/index.gist",
    "paths_file": ".local/gist-verify/paths.list",
    "files_indexed": 28194,
    "distinct_trigrams": 518707,
    "postings": 35129882,
    "index_bytes": 44564480,
    "paths_bytes": 1677722
  },
  "freshness": {
    "anchor_unix_ns": 1784160000000000000,
    "age_seconds": 12.5
  },
  "roots": ["services", "libs", "clients", "contracts", "scripts", "quality"],
  "bound_here": true,
  "built_over": "/Users/you/billy",
  "resident": "ours"
}
```

Fields are stable within `schema_version: 1`; additions are allowed, while a
rename, removal, type change, or semantic change requires a version bump.
`state` is `ready` only when the persisted index/path pair loads and validates;
otherwise it is `unavailable`, `index` is `null`, and both freshness values are
`null`. Counts and sizes are integer units; `anchor_unix_ns` is Unix epoch
nanoseconds; `age_seconds` is non-negative at snapshot time; `roots` preserves
configured corpus-root order.

## Whose tree is this?

`bound_here` is the field the numbers can't tell you. Every persisted
accelerator names files relative to its build directory and dates them against
that build's anchor, so a `$GIST_DIR` aimed at another checkout reports real
counts and a real anchor that describe **none** of the files here. The whole
accelerator surface declines in that state
(`corpus/index/frame/frame.zig`) — answers stay right and come live — and
`built_over` names the tree the artifacts do describe, so a caller isn't left
reading a healthy report and wondering why nothing is ever warm. The human
report closes with `built over <tree> — not this tree`; `gist index` re-binds
the directory here. `built_over` is `null` when the artifacts predate the
binding and name no tree at all, which also reads as unbound.

Note that `freshness` is what the directory RECORDS, not what a query may
trust: it stays populated for a foreign directory precisely so the anchor reads
as what it is (built then, over there) rather than as an index that never had
one.

## Which build is answering?

`resident` is the same question one layer up, about the other accelerator. A
daemon from a superseded build frames identically to this one and would answer
from an engine this binary no longer shares, so the client declines it and
every eligible query quietly runs cold — with nothing in the numbers above, or
in the answers themselves, to say why. Three states: `none` (nothing listening;
the next eligible query forks one), `ours` (this build, on this wire version,
over this tree — warm is live), and `foreign` (something is listening that this
binary will not use). Probing is read-only: `status` never spawns a daemon and
never retires one, so running it twice cannot change what it reports. Retiring
a superseded daemon is the *query* path's job, one cold answer later
(`../daemon/client/`).

The matching mutating verb is [`../lifecycle/`](../lifecycle).
