- **`gist index` and `gist serve` refuse a corpus with no edge.** Standing in a
  home directory, a rootless build took everything beneath it as the corpus and
  a rootless daemon tried to hold that in RAM and park its socket among the
  person's own files. Both now ask `home.hosted()` first - the boundary the
  engine grew this release - and refuse with the one-line fix instead. `index`
  exits 2, because there is no slower way to have an index and someone who
  typed the verb is owed a straight answer about whether they now have one.
  `serve` says it is standing down and queries answer cold.

  Searching a home directory still works, unchanged, live. It is the persisted
  copy of it that was never a good idea.

- **The content shard is rationed.** It is the one tier whose size *is* the
  corpus - a concatenation of every body, which on a developer checkout is a
  fine trade for removing an `open` per file and on someone's Documents folder
  is a duplicate of their files in a blob they never made. It is now admitted
  only inside the tree's disk allowance (`GIST_DISK_MB`, default 512 MiB) and
  declines out loud, because a silently-unwritten accelerator is
  indistinguishable from a slow tool. Indexed search is unaffected; full-scan
  queries read files instead of the shard.
