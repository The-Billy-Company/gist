`gist-bench` lives here now, and can be built again. The harness spent the split
in the engine package, where it could not compile at all: its `session` mode
spawns a real `gist serve` daemon on a thread and speaks the real socket frame
grammar to it, and `gist` depends on `irregex` rather than the reverse, so the
imports it needed pointed the wrong way down the dependency edge. Everything
that drives it — `certificate/`, `dominance/`, `certify_session.sh`, the warm
and scanner races — is already here, and now so is the binary.

`bench.zig`, `certify.zig`, `flagbench.zig`, and `sessionprof.zig` moved into
`bench/apparatus/harness/`. The three instruments they read did not: `probes`,
`pmu`, and `stats` stay with the engine and arrive as Zig modules through the
`irregex` dependency, because that package's own rungs and bounds read them too.
One registry and one significance test across both repos is what keeps a class
name meaning the same thing in a race here and a rung there.

The warm race was the visible casualty and is the clearest proof it is fixed.
`dominance/races/warm.sh` had been failing outright on a missing `zig build
bench` step; it now completes and wins 20 of 20 queries against every tool in
the field, at a 1012x geomean over ripgrep on the resident path.

New and restored steps: `zig build lab` installs `gist-bench` and `warden`;
`bench`, `verify`, `certify`, `flagbench`, `sessionprof`, and `warden` each run
their lane. `session` is new as a step — the daemon lane was previously
reachable only by argv, despite being the one number a long-lived client
actually sees. `cli` is back for running the built binary straight out of the
build graph. The monorepo's `gist` step is gone rather than ported: it existed
to install the CLI without the lab, which is what a bare `zig build` already
does here.
