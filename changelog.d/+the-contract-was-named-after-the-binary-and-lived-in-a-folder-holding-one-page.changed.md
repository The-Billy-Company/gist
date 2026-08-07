The import contract moved to `charter.zone` at the repository root, out of the
`contract/` drawer and out from under the package's own name.

Two things were wrong with the old spelling. A contract governs the directory it
sits in, so a folder holding one page bought nothing - the manifest, the
formatter config, and the CI config all already live at the root, and this
belongs beside them. And naming it after the package spent the filename on a
third copy of a name that is already on the file's first line and already in the
path, which meant every repository in the ecosystem called the same kind of
document something different.

`charter.zone` is that one name. Nested packages take a role name instead -
`kernel.zone`, `service.zone` - because there the path already says which one it
is. Identity was never in the filename: the `package` block is what every
verdict, every `--package` filter, and every workspace lookup reads, so nothing
downstream can tell the two spellings apart. Needs `zoning` 1.3.1, which is
where a contract at a package root is first discovered; the pin moves with this.
