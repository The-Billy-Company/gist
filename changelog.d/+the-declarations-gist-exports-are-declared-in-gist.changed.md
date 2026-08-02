The FFI transport, the contract mirror and the parity gates over both now live
here rather than in the substrate, across all three bindings.

Python gains `gist._native` and `gist._daemon`, moved from `irgx.runtime`, and
they carry the `gist_*` cdef with them; `irgx.runtime.loader` grew a face
registry so a product registers its declarations, its library stem and its ABI
expectation, and the substrate composes one cffi type universe from what
registered. `gist._contract` holds the published `dist` / `import` names and the
tool-boundary aliases and routing keys, which `irgx.contract.abi` used to carry.
Rust gains `gist::contract` with the same four constants. Both are gated here
against this repository's own `contract/surface.toml` and `include/gist.h`.

Two tests arrived with their subjects. `tests/test_span_parity.py` holds
`gist --json` and the engine's own iterator to the same submatch spans, the claim
`irgx.h` names this tool the authority for; it is a statement about two tiers and
the far one is this repository's binary. `exact/ladder_test.go` drives the shared
cold tier through `rank` and asserts an answer can say how much work it did and
which tier did it.

None of it was unused where it was. It moved because a substrate whose tests need
its consumers checked out is a substrate its consumers cannot be released
without, and because a mirror should be checked against the header that owns it.
