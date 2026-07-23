---
doc_radar:
  sentinels:
    - description: "machine status contract stays versioned and CLI-addressable"
      file: pkg/kernels/irregex/src/surface/face/gist/status/status.zig
      contains: ["pub const schema_version = 1;", "pub const Snapshot = struct"]
    - description: "status JSON remains discoverable through the CLI"
      file: pkg/kernels/irregex/src/surface/face/gist/main.zig
      contains: 'std.mem.eql(u8, value, "--json")'
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
  "roots": ["services", "libs", "clients", "contracts", "scripts", "quality"]
}
```

Fields are stable within `schema_version: 1`; additions are allowed, while a
rename, removal, type change, or semantic change requires a version bump.
`state` is `ready` only when the persisted index/path pair loads and validates;
otherwise it is `unavailable`, `index` is `null`, and both freshness values are
`null`. Counts and sizes are integer units; `anchor_unix_ns` is Unix epoch
nanoseconds; `age_seconds` is non-negative at snapshot time; `roots` preserves
configured corpus-root order.

The matching mutating verb is [`../lifecycle/`](../lifecycle).
