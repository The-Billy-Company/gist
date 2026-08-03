The root README had a Quickstart but no Install section, so the three published
bindings appeared nowhere a reader looks first, and the Rust README's wiring
block still said `cargo add irregex` / `cargo add gist` under an "Once
published" comment - two names that resolve to unrelated crates now that the
real ones are [`irgx`](https://crates.io/crates/irgx) and
[`gist-search`](https://crates.io/crates/gist-search).

The Go README was wrong in a way that only bites after you follow it. It gave
`go get github.com/The-Billy-Company/gist/bindings/go`, which is correct, and
then never said that the module root holds no package: the importable paths are
`bindings/go/exact` and `bindings/go/index`. Fetch succeeded, import failed.

All three now name the registry, the distribution, and the identifier you
actually type, and the Python README says at the install - not forty lines below
it - that the package is the bindings and the `gist` binary still has to be on
`PATH`.
