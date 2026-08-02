`gist_abi_version` is the session ABI (still 2). It is no longer exported as
`irgx_abi_version`, which `libirgx` owns for the engine plane (1). A
host that version-gates both libraries reads two axes, not one overloaded
integer.
