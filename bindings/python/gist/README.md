---
doc_radar:
  sentinels:
    - description: "package surface stays search/files/count over SearchRequest"
      file: pkg/kernels/irregex/bindings/python/gist/__init__.py
      contains: ["def search", "def files", "def count", "SearchRequest"]
    - description: "constants mirror the unified contract"
      file: pkg/kernels/irregex/bindings/python/gist/contract.py
      contains: ["ABI_VERSION", "ENGINE_VERSION"]
---

# `gist/` — the Python package modules

Implementation of `import gist` (distribution name `billy-gist`). Parent
[`../README.md`](../README.md) is the user-facing guide; this README maps the
modules for people changing the binding.

| Module | Job |
| ------ | --- |
| `__init__.py` | Public surface: `search` / `files` / `count` / `run` / `rank` / `summary` / `status` |
| `request.py` | `SearchRequest`, `Match`, rank kinds — the shared shape |
| `engine.py` | Subprocess transport (authoritative) + result parsing |
| `session.py` | UDS warm-session client (fail-open accelerator) |
| `_ffi.py` | In-process `libirregex` cffi (fail-open; rootless CWD only) |
| `contract.py` | Mirrored constants from `contract/search_api.toml` |
| `aggregate.py` | `summary` / tally helpers over a hit stream |
| `introspection.py` | `status` / `capabilities` / index freshness |
| `agent.py` | `request_from_tool` — loose agent dict → `SearchRequest` |
| `irregex.py` | Small relate/irregex helpers exposed beside gist |
| `errors.py` | Typed errors (`UnsupportedPatternError`, …) |

## Transport rule

Subprocess is authoritative. UDS and FFI return `None` / decline on any doubt
so the caller answers cold — accelerators never add a failure mode
(`GIST_NO_FFI` / warm eligibility opt-outs).

## When to edit

New request options land in `../../../contract/search_api.toml` first, then
here + the Rust crate + parity tests. Do not reimplement matching in Python.
