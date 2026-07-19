---
doc_radar:
  sentinels:
    - description: "schema still renders ripgrep buckets from the flag catalog"
      file: pkg/kernels/irregex/src/gist/faces/cli/schema/schema.zig
      contains:
        - "source_of_truth"
        - "flag_catalog"
        - '"tool": "gist"'
---

# gist/faces/cli/schema — `gist --schema`

Agents and codegen must not scrape `--help`. This package emits one deterministic
JSON capability manifest: verbs, search args, the ripgrep-compatible flag
surface (types, defaults, legacy aliases), exit codes, and where hydra verbs
moved.

**Source of truth, not a copy.** The four ripgrep compatibility buckets are
rendered straight from [`../search/argv/args.zig`](../search/argv/args.zig)'s
`flag_catalog` — the same rows that build the short- and long-flag dispatch
tables. If a flag is parseable, it appears here; if it appears here, the parser
honors it. Drift between `--help` prose and the machine surface is impossible
by construction.

Hydra's `similar` / `dups` / `patterns` are listed as `moved` pointers to
`hydra --schema` so a consumer that still asks gist about them gets a
redirect, not a silent hole.
