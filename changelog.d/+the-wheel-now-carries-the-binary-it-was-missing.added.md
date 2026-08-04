`pip install gist-search` used to buy a Python face with nothing behind it: the
published wheel was `py3-none-any`, every verb shells out to a `gist` binary,
and nothing in the distribution put one anywhere the resolver could find. The
README's own quickstart — `import gist; gist.search(...)` — raised
`GistNotFoundError` on the first call unless whoever ran it had separately
built the Zig sources and put the result on `PATH` or `$GIST_BIN`. Import
succeeding proved nothing about the product working.

The wheel now bundles a native `gist` CLI per platform. `hatch_build.py`
force-includes it at `gist/bin/gist[.exe]` and stamps the platform tag that
promise requires (`py3-none-<platform>`, never `any`, once a native binary is
inside); `scripts/build_wheels.py` cross-compiles the same six-target matrix
`irregex`'s own wheel already ships (macOS arm64/x86_64, Linux
x86_64/aarch64, Windows amd64/arm64), stripped, so the CLI wheel costs 4 MB
instead of 22. None of it is reachable without `irregex>=1.1.0`'s matching
`_resolve` rung, which is why that floor moved in the same release.

`release.yml` proves it rather than asserting it: `wheels` builds the matrix
and runs a real search — not an import — against the build host's own wheel,
then `smoke` repeats that on the real GitHub-hosted runner for every other
target, installing only the one wheel `pip`'s own tag matching picks out of
the six, with no source checkout and no `PATH`/`GIST_BIN` override to fall
back on. `publish` now waits on both.
