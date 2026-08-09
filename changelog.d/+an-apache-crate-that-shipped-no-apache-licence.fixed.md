Both published packages declared Apache-2.0 and carried none of it. The licence
text and the NOTICE live at the repository root, and neither a `.crate` tarball nor
a wheel can reach above its own project directory - so the crate shipped an SPDX
string and no licence, and the wheel shipped the same. Section 4 of that licence
asks a redistributor for exactly those two files, which made this the one packaging
defect that was not cosmetic. It mattered a little more here than elsewhere: this
NOTICE is where the ripgrep interface conventions the package is a drop-in for are
credited, so shipping without it dropped the attribution too.

`LICENSE` and `NOTICE` are now committed beside both manifests, byte-identical to
the root pair. The wheel names them in `license-files`, so they land in
`.dist-info/licenses/` rather than only inside the sdist, where nobody installing
the wheel would ever see them.

`rust-toolchain.toml` stops shipping in the crate on the same pass. It pins 1.97.1
so this repository's contributors lint identically - no business of anyone building
the extracted crate, and it would have quietly overridden the 1.85 `rust-version`
the sources actually ask for. The crate had no `exclude` list at all until now, so
this is also the first thing standing between the tarball and whatever lands beside
the manifest next.
