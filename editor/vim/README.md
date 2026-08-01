---
doc_radar:
  counts:
    - description: "the plugin's autoload modules — one per concern (job, sink, args, hint, kin, health)"
      glob: editor/vim/autoload/gist/*.vim
      unit: files
      equals: 6
  occurrences:
    - description: "every action is a <Plug> mapping, so every key is re-bindable"
      file: editor/vim/plugin/gist.vim
      pattern: 'nnoremap <silent> <Plug>\(gist-|xnoremap <silent> <Plug>\(gist-'
      min: 8
  sentinels:
    - description: "the installer links the plugin into the pack/*/start contract of an editor that already exists"
      file: editor/install.sh
      contains: ["pack/gist/start", "GIST_VIM_INSTALL", "command -v"]
    - description: "the job layer hands every runtime a null stdin — gist inherits rg's rule that a readable non-tty stdin is the corpus, so an open pipe would hang a pathless search"
      file: editor/vim/autoload/gist/job.vim
      contains: ["'stdin':     'null'", "'in_io':     'null'"]
    - description: "help is a real Vim help file, reachable as :help gist"
      file: editor/vim/doc/gist.txt
      contains: "*gist.txt*"
    - description: "the Lua leg is linted as Neovim rather than skipped — the repo's root Lua runtime is the Redis sandbox, where `vim` does not exist"
      file: editor/vim/lua/selene.toml
      contains: 'std = "lua51+nvim"'
---

# gist.vim

The Vim and Neovim end of [`gist`](../../src/surface/face/gist/README.md).
Indexed search, streamed into the quickfix list, with the two questions a
pattern cannot ask (`relate similar`, `irregex blast`) on the same keys.

## Getting it

Nothing, if you already had Vim installed when you ran `zig build` —
it links this directory into each editor's `pack/*/start/` and mints the help
tags. `GIST_VIM_INSTALL=0` declines. By hand it is one symlink:

```bash
ln -s "$PWD" ~/.vim/pack/gist/start/gist                     # Vim
ln -s "$PWD" ~/.local/share/nvim/site/pack/gist/start/gist   # Neovim
```

On Windows, [`install.ps1`](../../install.ps1) does the same thing to the same
contract — the package roots just have different names, and a link needs
Developer Mode, so it falls back to a copy rather than declining to install:

```powershell
$plugin = "$PWD"
New-Item -ItemType SymbolicLink -Target $plugin `
  -Path "$HOME\vimfiles\pack\gist\start\gist"                          # Vim
New-Item -ItemType SymbolicLink -Target $plugin `
  -Path "$env:LOCALAPPDATA\nvim-data\site\pack\gist\start\gist"        # Neovim
```

Then `:help gist` for the full guide, or `:GistHealth`
(`:checkhealth gist` in Neovim) for what is and is not wired.

## What you get with no configuration

|                             |                                                                                                                   |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `:grep`                     | runs gist — claimed only while `'grepprg'` still holds a value the editor chose for you                           |
| `:Gist {args}`              | argv straight to the binary: `\|`, `$`, `*`, quotes — and the `%` / `#` that `:grep` would expand into file names |
| `:GistRank`                 | the definition first, call sites after, generated files demoted                                                   |
| `<Leader>gg`                | the word under the cursor, as a literal word                                                                      |
| `<Leader>go{motion}`        | the text a motion covers — across line breaks, via gist's `-U`                                                    |
| `<Leader>gb` / `<Leader>gs` | `irregex blast` / `relate similar` into the quickfix list                                                         |
| `<Tab>`                     | completes the installed binary's real flags and `-t` types, read from `--schema`                                  |

Searches never block: results stream in and the window opens on the first
batch, `:GistStop` cancels, and a miss keeps gist's coaching out of the
quickfix list while turning the runnable part into `:GistRetry 1`.

Every default is a `g:gist_*` option (buffer-local `b:gist_*` wins, so an
ftplugin is a per-filetype search policy) and every action is a `<Plug>`
mapping. A default key is only claimed if it is still free.

## The tree

| Path                       | What                                                                                                       |
| -------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `plugin/gist.vim`          | guards, options, commands, `<Plug>` maps, `'grepprg'`, helptags                                            |
| `autoload/gist.vim`        | the pipeline every entry point funnels into                                                                |
| `autoload/gist/job.vim`    | Neovim `jobstart`, Vim 8 `job_start`, and a synchronous fallback, reconciled to whole lines and one finish |
| `autoload/gist/sink.vim`   | streaming into the quickfix or location list, one parse per output shape                                   |
| `autoload/gist/args.vim`   | shell-shaped splitting without a shell; completion answered by the binary                                  |
| `autoload/gist/hint.vim`   | stderr coaching → numbered, re-runnable offers                                                             |
| `autoload/gist/kin.vim`    | `:GistBlast` and `:GistSimilar`                                                                            |
| `autoload/gist/health.vim` | the health report, shared by `:GistHealth` and `lua/gist/health.lua`                                       |
| `lua/gist/health.lua`      | the Neovim `:checkhealth` renderer — the findings stay in Vimscript so the two editors can't disagree      |
| `lua/selene.toml`          | lints that one Lua file as Neovim, not as the Redis sandbox the repo's root config assumes                 |
| `lua/nvim.yml`             | the `vim.*` surface the shim is allowed to touch; an undeclared reach fails Selene against `editor/vim/lua/nvim.yml`             |
| `doc/gist.txt`             | `:help gist`                                                                                               |
| `test/gist_test.vim`       | the headless suite                                                                                         |

## Testing

```bash
the editor suite under editor/vim   # the same suite in Vim and Neovim; self-skips if neither is installed
```

It writes a corpus to a temp directory with its own `$GIST_DIR`, so it never
touches the tree's index, and asserts exact counts rather than "some matches".
Both editors must pass: they disagree about jobs, quickfix and completion
often enough that passing in one proves nothing about the other.
