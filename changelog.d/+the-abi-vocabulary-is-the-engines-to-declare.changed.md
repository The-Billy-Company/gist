`contract/surface.toml` no longer declares `[status_codes]`,
`[decline_reasons]` or `[fault_domains]`. They describe what
`include/irregex.h` returns, so they moved to `irregex/contract/engine.toml`,
which this repository already resolves as a sibling — the row schemas,
transports and session semantics that are genuinely ours stay here.

Nothing changed about what libgist returns, and no mirror moved: the Go, Python
and Rust constants are unchanged and their parity tests still read the engine's
contract the same way they read it for `[meta]` and `[request_options]`. The
practical difference is upstream of us. A host that links only libirregex now
has a contract for the codes it receives, and there is exactly one file to edit
when a fault domain gains a member — where before this repo could have added one
that the engine emitting it had never heard of.
