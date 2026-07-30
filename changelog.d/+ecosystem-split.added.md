`gist` is its own package: the product chassis (both binary faces, the
resident daemon, the session C ABI + bindings, the editor plugin, generated
man page + completions, and the dominance certificate) extracted from
`irregex` at the extraction commit, over the `irregex` and
`relate` libraries as sibling checkouts. CLI binaries build ReleaseFast by
default via `-Dcli-optimize`.
