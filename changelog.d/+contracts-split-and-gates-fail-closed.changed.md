This repo now authors `contract/surface.toml` - the row schemas, ABI status
vocabulary, transports, session semantics, analytic and composed planes, tool
boundary, and published package names. All of it previously sat in the kernel's
`search_api.toml`, describing surfaces the kernel does not own.

The contracts we do not author stay with their authors: `analytic.toml` and
`engine.toml` in `irregex`, `kinship.toml` in `relate`. Every binding resolves
them from the author's checkout, and `tools/sync_contract.py` fails when a
sibling is missing or its contract is absent - so a checkout of only this repo
knows what it cannot gate, rather than silently gating nothing.

That matters because **the parity gates now fail closed**. Every binding mirrors
constants from all three contracts so an installed package needs no repo file,
and a per-binding parity test is the only thing keeping five copies of the same
numbers honest. Those tests used to skip when a contract was unreadable, which
was defensible for a wheel and disastrous in a checkout: after the repo split
the locators resolved to files that no longer existed, so the assertions stopped
running and nobody noticed. An unreadable contract is an error now, and it names
the file and the command that restores it.
