This package no longer depends on `_buildkit`, a sibling that existed on one machine and had no remote. It borrowed one file from it — `brigade.zig`, the shard-aware test runner — which now lives in `irregex` and is reached through the dependency on `irregex` this build already declares. One fewer edge in the graph, and one fewer unpublished repository standing between a clone and a test run.

Two doc comments pointed at a `_buildkit/build.zig` helper that is no longer reachable from any of these repositories; they now describe the fan-out this build actually performs.
