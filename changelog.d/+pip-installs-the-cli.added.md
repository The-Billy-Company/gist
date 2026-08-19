`pip install gist-search` now puts `gist` on your PATH.

The wheel already carried the binary for all six platforms; it just kept it
somewhere only Python could reach. Now the same file lands in the environment's
`bin/` (`Scripts/` on Windows) as well, so installing the package installs the
tool. What you get there is the native binary itself, not a console-script
shim - a Python entry point would pay interpreter startup, some 30ms, in front
of something that answers a warm query in under one.
