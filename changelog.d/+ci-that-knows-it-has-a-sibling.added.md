This repo had no CI at all after the split, which meant the only thing standing
between a bad commit and `main` was whoever happened to run `zig build test`
locally. It has two workflows now. `ci.yml` is four jobs for the four faces -
the engine on Linux and macOS, the Python binding across 3.12/3.13/3.14, Go,
and Rust - deliberately not one job, because a Zig engine regression and a
clippy nit are different news and a single red X reports them as the same thing.
`windows.yml` is the native Windows lane, on x64 and on windows-11-arm, ported
over from the monorepo it was written in: the suite, a ReleaseFast build, the
index-elision parity gate, a CLI smoke over the rg exit-code contract, the
Win32 block (path separators, ignore rules spelled with `/`, `--max-depth`,
`--one-file-system`, console color, preferences under `%LOCALAPPDATA%`), the
resident tier and its watcher, and `install.ps1` proven by running it. Cross
compilation says the Win32 arm compiles; only a Windows kernel can say whether
`NtCreateFile` really descends an NTFS tree.

The interesting part was the sibling. `build.zig.zon` resolves `irregex` as
`../irregex`, and so do all three bindings independently - the Go `replace`, the
uv source, the Rust path dep - so a bare clone of this repo builds nothing.
`actions/checkout` refuses a `path:` that leaves the workspace, so the obvious
`path: ../irregex` is not on the table. Both repositories are checked out into
subdirectories of the workspace instead, which makes them siblings of each
other, and every one of those relative paths then resolves exactly as written.
Nothing in the package is patched for CI; what builds in CI is the layout a
contributor actually clones.

Two assumptions from the substrate's CI turned out to be false here and are
worth naming, because copying them would have produced a green lane that proved
nothing. Its Go and Rust jobs install no Zig, on the correct reasoning that
those modules link a vendored archive and `go get` needs no toolchain - but
gist's bindings are subprocess transports over the certified binary, so all
three suites need a real `zig build` first, and the Go suite fails rather than
skips without one. And the Python packaging gate stages `libgist` beside
`libirregex` from the *sibling's* `zig-out`, so that checkout gets built too or
the assertion silently takes its skip branch. ripgrep is installed on the Linux
jobs for the same reason: it is the oracle the parity tests compare against, and
without it on PATH they skip, which is a parity gate that has stopped gating.

Dropped on the way over: the monorepo's `paths:` filter and the scope job that
replaced it, both of which existed only because a required status has to be
resolvable on a PR that touches none of the kernel. Here the repository is the
package, so there is no out-of-scope PR and nothing for the filter to say. The
job that collapses the matrix into one verdict stayed, because its reason is a
GitHub fact rather than a monorepo one - a matrix job reports one status per leg
and never one under its own id - but `skipped` is no longer a pass in it, since
nothing gates the legs anymore and a leg that did not run is a lane that was not
proven.

One extraction bug fell out of writing the install step: `install.ps1` still
expected to place `gist.exe`, `relate.exe` and `irregex.exe` out of this
package's `zig-out`, and this package builds exactly one of those now, so the
installer threw before placing anything. It installs `gist`, and its "install
Zig" hint no longer points at a `.mise.toml` that did not come across the split.
