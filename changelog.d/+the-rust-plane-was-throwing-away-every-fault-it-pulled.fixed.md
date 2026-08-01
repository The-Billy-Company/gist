A native failure through the Rust in-process plane read `analytic run: native
status -3` when the engine had already said which file and which byte.

`plane::fault` exists to enrich that: pull the thread's last fault, render the
name, the path and the offset into the message. It pulled it, then tested the
return for `IRREGEX_OK` - which is the pull's "this thread has nothing to
confess". `IRREGEX_MATCH` is "a fault was written". So the test was inverted:
every real incident took the bail-out branch and every message fell back to the
bare status number, while the one case that got through was the empty slot,
whose `name` is `""`.

Nothing caught it because the rendering was a closure inside the only function
that called it, unreachable without a loaded engine. It is `incident()` now,
taking the pull as an argument, with a fake one in the tests - and the four rows
that pin it fail on the inverted spelling.

While there: the offset is only appended after a path when `at_space` is
`AT_FILE`, so a pattern offset can no longer be printed as a position inside a
filename.
