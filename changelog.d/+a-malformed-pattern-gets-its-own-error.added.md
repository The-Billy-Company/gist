The Python and Rust bindings now tell the engine's two exit-2 classes apart,
because they ask for opposite responses. `UnsupportedPatternError` /
`Error::UnsupportedPattern` still means *this pattern is outside the linear
engine, retry on `pcre2`/`auto`* — real advice. The new `BadPatternError` /
`Error::BadPattern` means *no grammar here accepts this at all*: the message
names the defect and points at the offending byte, and no `engine=` choice lifts
it.

Both used to arrive as the unsupported class, so a caller retrying on PCRE2 for
`[abc` retried into a second failure. The new class is a sibling rather than a
subclass, precisely so that `except UnsupportedPatternError` no longer catches
it — a retry loop written against that class would otherwise keep retrying
something nothing can compile.

The classification reads a phrase the engine prints only after asking PCRE2 and
being refused too, so it reports a probe's verdict rather than guessing at one.
Malformed is tested first, because PCRE2's own message can contain "not
supported" and the diagnostic echoes the user's pattern, which can contain any
marker word at all.
