---
doc_radar:
  sentinels:
    - description: "package surface stays search/files/count over SearchRequest"
      file: pkg/kernels/irregex/bindings/python/irregex/__init__.py
      contains: ["def search", "def files", "def count", "SearchRequest"]
    - description: "constants mirror the unified contract"
      file: pkg/kernels/irregex/bindings/python/irregex/contract/__init__.py
      contains: ["ABI_VERSION", "ENGINE_VERSION"]
---

# `irregex/` — the Python package modules

Implementation of `import irregex` (distribution name `billy-irregex`). Parent
[`../README.md`](../README.md) is the user-facing guide; this README maps the
modules for people changing the binding.

| Module / package | Job                                                                                     |
| ---------------- | --------------------------------------------------------------------------------------- |
| `__init__.py`    | Public surface: `search` / `files` / `count` / `run` / `rank` / `summary` / `status`    |
| `exact/`         | `SearchRequest`, cursor, ranked/aggregate helpers — the exact-match shape               |
| `runtime/`       | Cold subprocess, UDS daemon client, in-process FFI (`native.py`), decode/errors         |
| `contract/`      | Mirrored constants + grades from `contract/search_api.toml`                             |
| `relate/`        | Kinship (`similar` / `pairs` / `families` / `distinct`), retrieval, multi-pattern sweep |
| `compose/`       | Composed verbs (`provenance` / `blast`) over exact + compression                        |
| `index/`         | Atlas / shelf lifecycle                                                                 |
| `agent.py`       | `request_from_tool` — loose agent dict → `SearchRequest`                                |

## Transport rule

Subprocess is authoritative. UDS and FFI return `None` / decline on any doubt
so the caller answers cold — accelerators never add a failure mode
(`GIST_NO_FFI` / warm eligibility opt-outs).

## When to edit

New request options land in `../../../contract/search_api.toml` first, then
here + the Rust crate + parity tests. Do not reimplement matching in Python.
