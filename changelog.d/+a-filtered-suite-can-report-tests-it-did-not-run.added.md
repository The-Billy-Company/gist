A verification lane nearly certified a tree as immune to an environment variable
on the strength of a run that never executed. The trap belongs in both packages
that can hit it, so it is now in the README under "Build and test" here as well
as in irregex, which owns `brigade.zig` and carries the longer version.

`zig build test` caches the test run and the environment is part of the cache key.
`-Dtest-filter` reaches the harness as `BRIGADE_FILTER`, an environment variable
set on the run step, and Zig hashes a run step's environment along with its argv.
So a new environment always executes and any environment you have already used
replays from cache - step skipped, nothing run, exit 0 in about a third of a
second here. Note the direction, because I had it backwards at first: the problem
is not that environment variables are missing from the cache key, it is that they
are in it, so every distinct environment earns a durable entry that is replayed
on the second visit.

That is exactly the shape of an immunity probe - set the variable, run; unset it,
run again to confirm - where the confirming leg revisits a seen environment and is
therefore green by construction. The tell is neither the exit code nor the test
count: a cached run still prints `1/1 tests passed` under `--summary all`, and the
only distinguishing token is `cached` against `success <n>ms`.

The README's answer is to drive the compiled test binary directly, which has no
build-cache layer and executes every time, with `BRIGADE_TIMES=1` as the evidence
it did.

Measured here, not transcribed: A, B, A', B' over one probe variable gives
`success 3ms`, `success 3ms`, `cached`, `cached` - four exit-0 runs all claiming
1/1 passed, two of which ran nothing.
