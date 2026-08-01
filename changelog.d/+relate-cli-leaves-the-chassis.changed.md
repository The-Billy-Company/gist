The `relate` CLI left this package.

Its face (`src/surface/face/relate/`) and the four CLI modules only that
face needed (`flags` · `grade` · `manifest` · `reprise`) moved into the
`relate` package, which can now ship its own binary. The FM-index shelf
had already broken the cycle that forced the face to live here; with the
face gone, `gist` no longer depends on `relate` at all. What stays is the
`gist` binary, the resident daemon, the answer keep's transport, the
session C ABI, and the `--generate` primer. `relate` imports this chassis
for the daemon the keep dials.
