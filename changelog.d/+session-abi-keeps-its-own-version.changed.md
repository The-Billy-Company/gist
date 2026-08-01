`gist_abi_version` is the session ABI (still 2). It is no longer exported as
`irregex_abi_version`, which `libirregex` owns for the engine plane (1). A
host that version-gates both libraries reads two axes, not one overloaded
integer.
