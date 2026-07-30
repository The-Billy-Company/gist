`--version` / `-V` answers on **stdout** for all three faces, as ripgrep's
does. It had been going to the diagnostic channel, so `gist --version` read
back empty from anything that captured only stdout — `$(gist --version)`, a
CI provenance step, an editor asking which binary it is talking to — while
looking perfectly fine in a terminal, where both streams land on the same
screen. A version that was asked for is an answer, not a diagnostic. The
Python and Rust bindings already read whichever stream carried it, so they
keep working against older binaries.
