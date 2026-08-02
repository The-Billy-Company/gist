<!--
The Windows-descent invariants this matrix exercises are the *engine's*, and
they are asserted where they live: `portal.zig` (the comptime fork seam and the
demand-paged section), `corpus/read/inode.zig` (volume identity), and
`corpus/scope/paths.zig` + its two consumers (one separator, normalized at the
seam) all sit in the sibling `irregex` package, as does the probe slate under
`bench/apparatus/harness/probes.zig` that this harness mirrors class-for-class.
A contract can only be checked against a file in its own repository, so pinning
them from here would assert paths this checkout does not contain. The native
Windows CI lane is not wired in either package yet.
-->


# `bench/targets` — the target matrix, executed

> "You are not going to displace ripgrep — it's **more portable**."

That is a claim about a _matrix_, so this harness measures one. It cross-compiles
gist for every triple ripgrep declares in its own release workflow, plus targets
ripgrep publishes nothing for, **from one machine with no cross toolchains
installed** — and grades each target by what it actually proved, never by what it
would be nice to say.

## The evidence tiers

A portability certificate that only proves "it links" is worth little, so a row
is promoted only on evidence:

| Tier            | What was proven                                                                                                                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tree-broken`   | the build failed on diagnostics that also break the **host's own** target, so the row is a report about the working tree and carries no portability information either way                                                 |
| `unbuilt`       | nothing linked — or an artifact appeared whose own header contradicts the target it was built for                                                                                                                          |
| `builds`        | an artifact exists **and** its ELF/Mach-O/PE header reports the promised format, architecture, width, and endianness                                                                                                       |
| `runs`          | that artifact executed on a machine of that architecture and answered a real query — including a **PCRE2 lookbehind**, which the linear engine cannot represent, so serving it proves the vendored C cross-compiled too    |
| `conforms-wine` | the full slate came back byte-identical — but through **Wine's** reimplementation of Win32, not a Windows kernel. Strictly above `runs`, strictly below `conforms`, and never folded into either                           |
| `conforms`      | all twelve of `../harness/probes.zig`'s query classes came back **byte-identical** (stdout **and** exit code) to the native oracle, in **both** the live-scan and the indexed pass, on a real machine of that architecture |

Three details carry most of the weight.

**Identity is read from the bytes.** `objfmt.py` parses the ELF/Mach-O/PE header
itself rather than shelling `file`/`readelf` — so the certificate does not depend
on which binutils a machine happens to carry, and a build that silently fell back
to the host fails at `builds` instead of passing. Its `verify()` is checked in
`selftest` against a deliberately mislabeled artifact, so the check cannot rot
into a no-op.

**The indexed pass is the point on big-endian.** Running the live scan on s390x
proves the matcher works. Building gist's on-disk index _inside_ the s390x
container and getting byte-identical answers proves the artifact format is
genuinely endian-neutral — which is the kind of thing that is either true or
silently, catastrophically false. It was in fact false when this harness first
ran it: see [the bug this found](#the-bug-this-found) below.

## A sweep is hermetic against its own repository

Roughly ten agents edit this package at once, and a full sweep takes tens of
minutes — long enough that a build will sometimes compile against a file
somebody else is halfway through saving. That is indistinguishable from a
portability failure, and it is not hypothetical: one sweep scored six perfectly
portable targets `unbuilt` on a neighbor's `use of undeclared identifier`, and
another produced a row reading literally `file contents changed during update`.

So the sweep never compiles the shared tree. `crossbuild.frozen` copies the
package plus the path dependencies its `build.zig.zon` names, compile-checks that
copy for the **host's own** triple, and re-freezes if the copy was caught
mid-save. Every target is then built from those exact bytes, whose digest is
recorded in the output — so all twenty-two rows describe one identical tree, and
the sweep is reproducible rather than merely repeatable.

Retrying is not the same as hiding. If no freeze compiles, the real failure is
recorded, every failed row is scored `tree-broken`, and the certificate
**refuses** the sweep instead of publishing an inconclusive one.

## The oracle is pinned to ripgrep

Comparing cross builds to our own native build only proves gist is
self-consistent. So before the sweep, the native binary is diffed against a real
`rg` on the same corpus with the same flags — all twelve classes, stdout bytes
and exit codes. The reporter **refuses to use the word `conforms`** unless that
check passed, which makes every conforming row transitively a statement about
ripgrep's own output.

One flag matters here: gist caps its own output at ~100 KB with a
`gist: output truncated` diagnostic (an agent token budget rg has no equivalent
of). The slate therefore passes `--uncap`; without it the dense classes would be
compared as truncated prefixes and "conforms" would cover a third of the bytes.

## The corpus is generated, not checked in

`corpus.py` synthesizes ~200 Go-shaped files from a fixed seed: identical bytes on
every machine, every run, inside every container. Pointing the harness at the repo
would make a conformance diff depend on whatever the ~10 coworker agents saved in
the last second.

It is shaped so **every** probe class answers non-trivially — a probe that matches
nothing conforms vacuously, which is the failure mode that makes a green
portability sweep worthless. `python3 corpus.py selftest` asserts determinism and
digest agreement; `portable.py selftest` asserts the harness's twelve probes still
match `probes.zig` line for line (a Python harness cannot `@import` Zig data, so
the parity check replaces the copy's honesty).

## Execution lanes

| Lane               | Targets                                                  | Mechanism                                                                     |
| ------------------ | -------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `native`           | `aarch64-macos`                                          | run directly (this is also the oracle)                                        |
| `rosetta`          | `x86_64-macos`                                           | `arch -x86_64`                                                                |
| `docker:linux/…`   | amd64 · arm64 · 386 · arm/v7 · s390x · ppc64le · riscv64 | Docker + binfmt, one container start per pass                                 |
| `wine:linux/amd64` | `x86_64-windows-gnu` · `x86-windows-gnu`                 | Wine inside a Linux container — the PE loads, Win32 is reimplemented          |
| `none`             | `aarch64-windows-gnu` · FreeBSD · NetBSD                 | **no machine of that kind on this host** — the row honestly stops at `builds` |

A `none` lane is a fact about the measuring host, not about the artifact, and the
harness records it as such rather than emulating a pass. Docker is optional: if it
is absent, every containerized row is recorded at `builds` with the reason
attached.

**A lane declares what it is allowed to certify.** `matrix.py`'s `LANE_CEILING`
caps the Wine lane at `conforms-wine`, and the scorer reads that cap at its last
promotion — so a Windows row that reproduced every byte still cannot be rounded up
to `conforms`, and a future lane cannot forget to declare its own ceiling. The
Wine image is **built by the harness** rather than pulled (`WINE_DOCKERFILE`), so a
sweep does not depend on somebody's `latest`; `wine32:i386` is in it because a
PE32 loads through WoW64 and refuses without the 32-bit loader.

## Running it

```bash
python3 bench/targets/portable.py run          # the sweep → artifact/portable.json
python3 bench/targets/portable.py status       # read the last sweep back
python3 bench/targets/portable.py selftest     # offline: probe parity, corpus, objfmt
python3 bench/targets/portable.py run --only s390x-linux-gnu --only riscv64-linux-musl
python3 bench/targets/portable.py run --no-exec   # build + identify only, no Docker
```

`run` needs a native build first (`zig build -Doptimize=ReleaseFast`) — that
binary _is_ the oracle. Per-target prefixes are deleted as the sweep goes
(~25 MB × 22 otherwise); `--keep` retains them for inspection.

## The bug this found

The harness paid for itself before it certified anything. On its first executed
sweep, `s390x-linux-gnu` **built, ran, and returned zero matches for every
probe** — on a corpus where a literal appears in all 200 files.

The cause was in the matcher, not the harness. gist's scanner compares sixteen
bytes at a time and `@bitCast`s the resulting `@Vector(16, bool)` to a `u16` to
get a movemask, then takes `@ctz` of it to find the first hit. That bitcast's
lane→bit order follows **target endianness**. Measured from one source with one
compiler on two targets, with a compare true only in lane 0:

| Target               | mask     | `@ctz` | first-hit lane it reports |
| -------------------- | -------- | -----: | ------------------------- |
| `aarch64-linux-musl` | `0x0001` |      0 | 0 — correct               |
| `s390x-linux-gnu`    | `0x8000` |     15 | 15 — off by the vector    |

So on a big-endian machine every match was reported fifteen bytes from where it
was, and the surviving-candidate loop discarded them all. The fix is a single
seam — `kernel/math/bits.zig`'s `laneMask`, which reverses the bits inside a
`comptime` branch on target endianness, so little-endian builds lower to exactly
the bare `@bitCast` they did before and pay nothing. Twenty-five call sites across
the scanner, the class-run scanner, and the regex prefilter now route through it.

This is the argument for the `conforms` tier existing at all: `builds` and `runs`
were both green on that binary. Only byte-comparison against the oracle caught
it.

## The port this forced

The first sweep scored **0 of ripgrep's 4 Windows triples** — not a measurement
problem, a missing port. gist's descent was `openat`/dirfd-relative all the way
down, and `openat` is the one POSIX primitive Windows has no spelling for.

The fix is one seam, `../../src/portal.zig`, exported as `irregex.portal`. It is
POSIX-shaped on purpose — the call sites read the way they always did — and states
the Windows difference in exactly one place:

| What the engine asks for                      | POSIX arm          | Windows arm                                                                                                                                                                                                                                |
| --------------------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| open a name **relative to an open directory** | `openat(dirfd, …)` | `NtCreateFile` with `RootDirectory = dir` — the Win32 shape of the same idea                                                                                                                                                               |
| a whole file as bytes                         | `mmap(PRIVATE)`    | `NtCreateSection` + `NtMapViewOfSection`, section handle dropped — demand-paged, and the view outlives both it and the file handle. Naming the size makes this the safer arm: a file that shrank mid-race fails to map instead of faulting on the vanished tail |
| every entry in a directory, with its clocks   | `getattrlistbulk` / `getdents64` | `NtQueryDirectoryFile` — one record carries the name, the attributes, and both change clocks, so there is no cheaper names-only call to drop to                                                                                    |
| what kind of thing is this handle             | `stat` mode bits   | `NtQueryInformationFile` attributes + `GetFileType` device class                                                                                                                                                                           |
| which volume is this on (`--one-file-system`) | `st_dev`, already in the stat | `NtQueryInformationFile(.Id)` — its own entry point (`inode.devicePath`), because it is a *different* query here and folding it into the stat would tax every entry to serve a once-per-directory flag. Not `FileFsVolumeInformation`, which Wine answers `NOT_IMPLEMENTED` |
| a path the walker just handed back            | already `/`-joined — `paths.slashed` is comptime the identity, so the seam costs nothing here | `\`-joined, so it is normalized once at each walker seam: the serial walk takes a copy (the walker overwrites the bytes it lends), the haystack rewrites the join it already owns. The ignore protocol, depth counting, and the render all speak `/`      |
| the canonical path                            | `realpath(3)`      | `GetFinalPathNameByHandle` (symlinks already followed), `GetFullPathName` if the open is refused                                                                                                                                           |
| the argument list                             | a pre-split `argv` | one command-line string that must be **parsed**, so the iterator needs an allocator                                                                                                                                                        |
| is stdin readable yet                         | `poll(POLLIN)`     | unreachable — a unix socket cannot be this process's stdin, so the guard has nothing to guard                                                                                                                                              |

Two things degrade rather than block, which is why the port fits in one pass:

- **The resident daemon is absent.** It needs a unix socket, `flock`, and
  `SCM_RIGHTS`; none exist on Windows. `portal.resident_sessions` is a `comptime`
  `false` there, and the socket writer, the fd-passing receive, the shared-memory
  map, and the singleton lock each decline through it. The warm tier is an
  optimization the cold path never depends on, so a Windows build answers cold and
  says so. Gating at the _entry_ also keeps the whole listener graph out of
  semantic analysis instead of half-porting it.
- **One of the two pager hints declines.** `WILLNEED` ports exactly onto
  `PrefetchVirtualMemory` — same instruction, batch the fault-in now — and that is
  the hint the measured win lives in. `SEQUENTIAL` has no view-level spelling on
  NT, which says "expect a forward streaming read" as a flag on the *open*, before
  this seam ever sees a handle; it declines rather than being faked, because
  prefetching the whole range to imitate it would reintroduce the eager read the
  section mapping exists to delete.

The little-endian POSIX rows are untouched by construction: every fork is a
`comptime` branch and the POSIX arm _is_ the call it replaced.

### Wine proves the port; only a kernel proves the platform

Which is why the Windows rows here are capped at `conforms-wine` and the rest of
the question is asked somewhere else: a native lane
(`../../../../../.github/workflows/gist-windows.yml`) on hosted **x64 and arm64**
runners, which runs the whole `zig build test` suite, a ReleaseFast build, the
same index-elision parity gate the Linux leg runs, an end-to-end CLI smoke over a
real NTFS checkout, and a Win32 contract step for the behaviors that exist only
here — the `/` render, an ignore rule spelled through a separator, `--max-depth`'s
component count, `--one-file-system` over one volume, `--color=always` with no
`TERM`, and `%LOCALAPPDATA%\gist\preferences` found but held out of force in a
pipe. arm64 is the half worth having: it is where a weakly ordered memory model
stops forgiving an acquire/release pair that x86's total store order lets slide.

The two lanes answer different questions and neither substitutes for the other —
this harness asks _"does every target still agree, byte for byte, with a native
oracle?"_ across 22 triples from one machine; the native lane asks _"does the
Win32 arm hold on the kernel it was written for?"_ on the two that matter.

## Wiring Layer H into the certificate

The splicer is `../certify/certify_portable_report.py`. It is **fail-closed** and
writes nothing while exiting non-zero if any of these hold: a triple ripgrep
declares is not even `builds` — on _either_ side of the partition, so dropping
some Windows rows fails as loudly as dropping all of them;
the Windows rows are missing, so the gap
would go undisclosed; a Windows triple is scored at the native `conforms` rung it
did not earn; the Windows rows are present but none executed; gist reaches nothing
beyond ripgrep's matrix; the oracle was not pinned byte-for-byte to a real `rg`; no
_cross_ target conformed; or any row is `tree-broken`. A spliced Layer H is therefore its own receipt.

Note the scope deliberately. Matrix domination is now **unqualified at `builds`** —
every triple ripgrep declares, Windows included, plus targets it publishes no asset
for. The _evidence tier_ is still partitioned, and the reporter keeps it that way:
POSIX triples conform on real machines of their own architecture, Windows triples
conform under Wine, and the gate refuses to splice if a Windows row ever appears at
the native `conforms` rung or if the Windows rows are present but none executed.

The layer also publishes a side-car receipt at
`../certify/artifact/portable.json` — the spliced claim as data (per-target tier
and lane, ripgrep coverage, the pinned `rg` version, the frozen-tree digest, and
the sha256 of the sweep it was lifted from), so a re-mint can re-verify the table
without re-running the sweep. It is written only after the section is spliced _and_
read back, so a receipt can never vouch for a section that is not in the file.

The line to add to `../certify/certify_layers.sh`:

```bash
python3 "$HERE/certify_portable_report.py" --certificate "$CERT" --json "$ROOT/bench/targets/artifact/portable.json"
```

(`$HERE` = `bench/certify`, `$CERT` = `bench/certify/artifact/CERTIFICATE.md`,
`$ROOT` = the package root — match whatever those scripts already call them.)

## Files

| File                     | Role                                                                          |
| ------------------------ | ----------------------------------------------------------------------------- |
| `portable.py`            | the driver — scores each row's evidence into a tier, sweeps, reports          |
| `matrix.py`              | the population: which targets, which twelve queries, which lanes exist here   |
| `crossbuild.py`          | a frozen tree that provably compiles, and one artifact per triple from it     |
| `slate.py`               | interrogating one binary — four lanes, one comparable answer, the `rg` oracle |
| `objfmt.py`              | what an artifact _is_, read from its own ELF/Mach-O/PE header                 |
| `corpus.py`              | the deterministic generated conformance corpus                                |
| `ripgrep-matrix.json`    | ripgrep's declared/published matrix as data, with URLs + read dates           |
| `artifact/portable.json` | the last sweep's machine-readable result                                      |
