`install.ps1` is the Windows half of `make install-gist`. A Windows user could
build the three binaries and had to place them, put them on PATH, and find the
completions themselves — the one-shot setup existed only as a Makefile target
shelling POSIX tools. The script installs all three executables, persists the
prefix to the user PATH without duplicating an entry it already added, generates
the PowerShell completion from the same flag table argv is parsed with and
sources it from `$PROFILE`, links the editor plugin (symlink first, copy when
Developer Mode is off), and indexes the tree it was run in. Two Windows
specifics get handled rather than papered over: a running `gist.exe` cannot be
overwritten, so a locked target is renamed aside and cleaned up on the next run,
and the PATH edit uses the registry-backed user environment so it survives the
session that made it. Re-running is a no-op, which the native CI lane asserts by
running it twice and counting PATH entries and profile lines.
