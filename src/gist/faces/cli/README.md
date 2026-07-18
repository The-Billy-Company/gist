# gist/faces/cli

The `gist` binary's entrypoint + the machine-readable capability manifest.

| File         | Role                                                                                                                                                                                                                                          |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `main.zig`   | The `gist` executable entrypoint — dispatches the two lifecycle verbs `index` / `status`, the bare `gist <pattern> [PATH...]` shorthand (no verb), the explicit `gist rg` alias, and the top-level `--help` / `--version` / `--schema` flags. |
| `schema.zig` | `gist --schema` — the static JSON capability manifest (verbs, native flags, types, defaults, legacy aliases, exit codes) an agent or codegen step consumes instead of scraping `--help`.                                                      |

Read-only introspection lives in [`../status/`](../status). The bare
shorthand and `gist rg` both route through the one unified search engine in
[`../ripgrep/`](../ripgrep) — a byte-for-byte `rg` DEFAULT drop-in (gitignore
precedence, piped stdin, coloring, exit codes) that transparently uses the
persisted trigram index, when one covers the searched roots, purely to elide
reads of files it proves can't match (never to change the file set or
output). Build and run with `zig build cli -- <verb>` (see
[`../../../README.md`](../../../README.md)).
