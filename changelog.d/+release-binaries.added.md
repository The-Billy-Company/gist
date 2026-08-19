Every release now attaches a downloadable archive per platform, with a
`SHA256SUMS` beside them.

macOS, Linux, and Windows, each on x86_64 and arm64. Until now the only way to
get the CLI without already having a language runtime was to install Zig and
build from source; now there is a URL, and Homebrew, `cargo binstall`, and a
plain `curl | tar` all have something to point at.

Nothing is rebuilt to publish them. Each archive holds the exact binary that
ran a real search on that architecture's own hardware in the release's smoke
matrix, so an asset and its wheel cannot disagree about what this version's
`gist` is.
