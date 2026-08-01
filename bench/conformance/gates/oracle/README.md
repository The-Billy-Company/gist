# bench/conformance/gates/oracle

The Python **reference oracles** the shell gates lean on — heavier checks whose
ground truth comes from an independent engine or an accounting model rather than
a `rg` diff.

| File                       | Oracle                                                                                                                                                                     |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `indexed_pcre_oracle.py`   | proves the trigram-prefiltered PCRE2 path (`gist -P`) returns exactly what an un-prefiltered PCRE2 scan would — the prefilter may prune candidates but never a true match  |
| `index_size_accounting.py` | accounts for every byte of the persisted index (trigram posting lists + metadata) so a size regression is attributable, not mysterious; read by `certificate/mint/mint.sh` |
