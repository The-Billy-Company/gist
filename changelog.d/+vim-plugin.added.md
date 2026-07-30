gist ships an **editor face**: a Vim and Neovim plugin (`editor/vim/`) that
`make install-gist` links into `pack/*/start/` for whichever editors are
already on the machine. Nothing is added to a vimrc, `:help gist` is minted at
install time, and a checkout that moves updates the plugin with it.

The usual ripgrep integration is one line — `set grepprg=rg\ --vimgrep` — and
inherits four consequences the plugin does not. Searches run in a job and
stream into the quickfix list as they arrive, so a large tree does not freeze
the editor and `:GistStop` can cancel. Arguments are handed over as argv, so
`:Gist foo|bar` and `:Gist 'a b'` reach the regex engine as typed instead of
through the user's `'shell'`. Each output shape is parsed for what it is,
which retires the catch-all `%f` in `'grepformat'` that turns a stray stderr
line into a quickfix entry pointing at a file that never existed. And a miss
keeps gist's coaching out of the list while turning the runnable part of it
into a numbered offer, so `try -i` becomes `:GistRetry 1`.

The three faces stay themselves: `:GistRank` is the definition-first view,
`:GistSimilar` is `relate similar` on the current buffer, and `:GistBlast`
puts a symbol's live blast radius in the quickfix list so `:cnext` walks a
change's consequences the way it walks matches. A selection or motion that
crosses line breaks is searched with `-U` as one string, which a
line-at-a-time grep cannot express at all. Completion asks the installed
binary — `--schema` for flags, `--type-list` for `-t` names — so `<Tab>` can
never drift from the gist that is actually there.

Two runtime facts the plugin settles rather than exposes. Neovim's default
job stdin is an open pipe, and gist inherits ripgrep's rule that a readable
non-tty stdin _is_ the corpus, so a pathless search would have waited forever
on input no one was going to write; every runtime now hands the child a null
device. And `'grepprg'` is claimed only while it still holds a value the
editor chose for itself — Vim's built-in grep or the ripgrep line Neovim
writes when rg is on `$PATH` — because a `'grepprg'` in a vimrc is a decision,
not a gap to fill.

`make test-gist-vim` runs the suite in both editors against a temp corpus with
its own `$GIST_DIR`; both must pass, since the two runtimes disagree about
jobs, quickfix, and completion often enough that one proves nothing about the
other.
