# tools

Maintenance scripts for this repo. Standard library only, no build step — run
them with `python3 tools/<name>.py`.

| Script | What it does |
|---|---|
| `sync_contract.py` | Verifies the foreign contracts are reachable as sibling checkouts (`../irregex`, `../relate`). |
| `version_parity.py` | Proves every mirror of this package's version still equals `build.zig.zon`, and that the release bot was told about each one. |
| `registry_readme.py` | Verifies every relative link in `README.md` still resolves, and mints the link-corrected copy PyPI and crates.io publish. |

## The README, on an index that is not GitHub

PyPI and crates.io each show a README as the whole project page, and each
resolves a relative link against its own URL rather than against GitHub. A
repository-relative path is a 404 under `pypi.org/project/gist-search/`, and on
crates.io a well-formed URL into the crate's own subdirectory pointing at a file
that was never there - the worse of the two, because nothing looks broken.

`registry_readme.py` is the one rewriter both ends share. It absolutizes every
relative target against the `repository` URL the manifest already declares -
`raw` for an image, `tree` or `blob` by what the path is on disk - and refuses
outright on a target the repository does not contain. Python calls it from
`bindings/python/hatch_readme.py` at wheel-build time, so the corrected page
exists only inside the artifact. Cargo has no metadata hook, so for crates.io
this writes `bindings/rust/PROJECT_README.md`, which is gitignored and which
`readme` points at: `cargo package` fails loudly if it was never generated, and
`cargo build` never reads it.

```bash
python3 tools/registry_readme.py --check   # the gate (CI's `version` job)
python3 tools/registry_readme.py           # mint bindings/rust/PROJECT_README.md
```

Mint it immediately before `cargo package`, never earlier. A missing file fails
loudly; a stale one would ship quietly, so absent is the state to leave it in.

## One version, and where the copies are

`build.zig.zon`'s `.version` is the single authority. `src/root.zig` reads it
through a build option, Rust reads `CARGO_PKG_VERSION`, and Python reads its
installed distribution metadata — none of them restate it. What is left is the
publishing manifests that cannot import anything, and each carries an
`x-release-please-version` marker that `release-please-config.json` lists and
the release bot rewrites in one commit.

`version_parity.py` is what keeps that honest: it discovers marked lines rather
than holding a list, so it fails on a mirror that drifted **and** on a mirror
the release config never learned about. It runs in CI (the `version` job) and
takes `--json`.

## Four contracts, one of them ours

There are four contracts, split by who authors the thing being described:

| File | Authored in | Declares |
|---|---|---|
| `contract/surface.toml` | **here** | transports, the resident session, the tool boundary, the published package names |
| `irregex/contract/analytic.toml` | `irregex` | the row schemas, enums, verb table and producer map every analytic answer rides |
| `irregex/contract/engine.toml` | `irregex` | the request surface, match kinds, exit codes, the ABI status vocabulary, and the version axes |
| `relate/contract/kinship.toml` | `relate` | the compression plane — channels, grade bands, verbs, lifecycle |

The analytic tables are substrate: gist, relate and blast all return those rows,
so they are declared once beside the generator that lowers them
(`irregex/tools/build_schema_tables.py`) rather than in whichever product
declared them first.

Bindings resolve the two foreign contracts from the authoring sibling (or an
`IRGX_*_CONTRACT` override). Parity tests fail closed when a contract is
unreadable, so a checkout without siblings cannot silently skip the gate.
`sync_contract.py` is the explicit sibling check.
