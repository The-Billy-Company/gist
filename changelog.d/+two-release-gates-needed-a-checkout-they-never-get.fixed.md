Two release gates were running their stdlib scripts through the project environment, so they needed a sibling checkout the release job has no reason to clone.

Both are a dozen lines of `pathlib` and `tomllib`: one reads the declared version to compare against the tag, the other reads the built wheel's `Requires-Dist` to prove the shipped dependency resolves from the index rather than from a path. Neither imports anything outside the standard library, but `uv run` without `--no-project` syncs the project first - and syncing means resolving the `[tool.uv.sources]` entry that points `irregex` at `../../../irregex/bindings/python`, which is exactly the development-only entry the second gate exists to catch. So the gate against a path reference shipping could not run without one.

The version check is guarded on a tag ref, which is why a manual dry run never reached it; it would have failed the actual release. `--no-project` on both, and the reason is written down beside them.
