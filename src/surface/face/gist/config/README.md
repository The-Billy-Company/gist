---
doc_radar:
  sentinels:
    - description: "the verb answers all three questions, and none of them exits early"
      file: pkg/kernels/irregex/src/surface/face/gist/config/config.zig
      contains:
        - 'std.mem.eql(u8, verb, "check")'
        - 'std.mem.eql(u8, verb, "init")'
    - description: "init lifts only asserted machine-local state, never a guess about the tree"
      file: pkg/kernels/irregex/src/surface/face/gist/config/config.zig
      contains: ['fn seededSkips(']
    - description: "the inspect path never exits, so check can report both layers"
      file: pkg/kernels/irregex/src/corpus/scope/charter.zig
      contains: ['pub fn inspect() ?*const Charter {']
---

# `gist config` — what is steering this run

ripgrep has a configuration file and no way to ask it anything. To learn what a
`.ripgreprc` is doing you open it and reason about it yourself, which is why the
standing advice for a confusing result is "try `--no-config`": bisection as a
diagnostic, because introspection does not exist.

Persisted configuration earns that introspection or it should not be persisted.

| Command             | Answers                                                                                                                                                                                                           |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gist config`       | What is in force right now, from which file, and whether it can change the answer or only its rendering. `--json` for the machine-readable stack.                                                                 |
| `gist config check` | Is what I wrote valid — **without** running a search. Reports _both_ layers before exiting, because someone fixing their configuration wants the whole list, not one item per run. Exit 2 if either is malformed. |
| `gist config init`  | Write the charter, prefilled from what this machine is already carrying. `--write` creates it; without that it prints to stdout.                                                                                  |

## Why `init` exists

The two facts the charter holds were previously stranded in places no clone
could inherit: search roots in one shell's `GIST_ROOTS`, extra skip directories
in `skips.list` inside the gitignored artifact directory that every cache clear
deletes. So the migration is not "read the docs and hand-write TOML" — gist
already knows what you told it, and `init` writes it down.

**It lifts only facts you asserted, and infers nothing from the shape of the
tree.** A guessed `skip` silently hides files, which is precisely the failure
this layer exists to prevent; being wrong about it would be far worse than
making someone type one line. Keys with nothing to lift are emitted commented
out with an example, since `roots = []` is a declaration ("no roots") and an
example is worth more to the next reader than an assertion nobody meant.

## The two layers it reports

Defined by [ADR-379](../../../../../../../docs/architecture/3-decisions/379-persisted-search-configuration.md).
The charter (`corpus/scope/charter.zig`) is committed and applies to everyone,
ceilinged at `corpus` reach. Preferences
(`surface/exec/cold/argv/preference.zig`) are machine-local and apply only to an
interactive terminal.

The report always names the environment variables that outrank the committed
file, whether or not a charter exists: _"my charter is being ignored"_ and _"I
have no charter but roots are set anyway"_ are the same confusion approached
from opposite directions, and both are a `GIST_ROOTS` someone exported months
ago.
