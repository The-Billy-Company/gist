# gist tests

Contract-only, cold subprocess, warm session/FFI, and cross-language parity.
Kinship, retrieval, atlas, compose, and row-decoder suites live with the packages
that own them (`relate`, `blast`, `irregex`).

Nothing here skips. A prerequisite this suite needs is a prerequisite this
repository builds, so a missing one is a broken environment rather than an
optional capability, and CI fails the run on any skip at all.

Three of these gate what gist itself declares, which is why they are here rather
than in the substrate:

| File | What it holds |
|---|---|
| `test_contract_surface.py` | `gist._contract` and the verb table do not drift from `contract/surface.toml`: published names, tool-boundary aliases, routing keys, and that every gist verb resolves in the loaded library. |
| `test_cdef_header_parity.py` | `gist._native.CDEF` is spelled the way `include/gist.h` spells it. cffi resolves an ABI-mode symbol lazily, so a stale name is invisible until the call. |
| `test_span_parity.py` | `gist --json` and the engine's own iterator report the same submatch spans over zero-width and nullable patterns. `irgx.h` names this tool the authority for that, and the tool is built here. |

```bash
cd bindings/python && uv run pytest
```
