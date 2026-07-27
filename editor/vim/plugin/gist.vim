" gist.vim — the gist code locator, wired the way Vim already searches.
"
" Installed and nothing else done, you get: :grep running gist, :Gist and
" friends filling the quickfix list without blocking, <Leader>gg on the word
" under the cursor, <Tab> completing gist's real flags, and :help gist.
"
" Nothing here decides policy. Every behavior is a g:gist_* option read at
" the moment it matters (buffer-local b:gist_* wins), every key is a <Plug>
" mapping you can re-bind, and a default mapping is only claimed if that key
" is still free. See :help gist-options.

if exists('g:loaded_gist') || &compatible
  finish
endif
let g:loaded_gist = 1

let s:cpo = &cpoptions
set cpoptions&vim

" ------------------------------------------------------------------- 'grepprg'
" 'auto' (default) claims 'grepprg' only while it still holds a value the
" editor chose for you — Vim's built-in grep, or the ripgrep line Neovim
" writes for itself when rg is on $PATH. A 'grepprg' you set in your vimrc is
" a decision, not a gap to fill, and survives untouched. 'always' takes it
" regardless; 'never' leaves it alone. 0/1 work too.
let s:stock = '^\%(grep\|findstr\|internal\)\>\|^rg --vimgrep -uu\s*$'
let s:wire = get(g:, 'gist_grepprg', 'auto')
if type(s:wire) == type(0)
  let s:wire = s:wire ? 'always' : 'never'
endif
if s:wire ==# 'always' || (s:wire ==# 'auto' && &grepprg =~# s:stock)
  let &grepprg = get(g:, 'gist_binary', 'gist') . ' --vimgrep $*'
  let &grepformat = '%f:%l:%c:%m,%f:%l:%m'
endif
unlet s:wire s:stock

" -------------------------------------------------------------------- commands
" No -bar: a '|' belongs to the pattern here, so `:Gist foo|bar` needs no
" escaping. -complete asks the installed binary what its flags and types are.
let s:complete = '-complete=customlist,gist#args#complete'

execute 'command! -bang -nargs=*' s:complete
      \ 'Gist call gist#command("vimgrep", <bang>0, <q-args>)'
execute 'command! -bang -nargs=*' s:complete
      \ 'GistRank call gist#command("rank", <bang>0, <q-args>)'
execute 'command! -bang -nargs=*' s:complete
      \ 'GistFiles call gist#command("files", <bang>0, <q-args>)'
execute 'command! -bang -nargs=*' s:complete
      \ 'LGist call gist#command("vimgrep", <bang>0, <q-args>, 1)'
execute 'command! -bang -nargs=*' s:complete 'Grank call gist#command("rank", <bang>0, <q-args>)'
unlet s:complete

command! -nargs=? GistRetry  call gist#retry(str2nr(<q-args>))
command!          GistStop   call gist#stop()
command! -bang    GistIndex  call gist#index(<bang>0)
command!          GistStatus call gist#status()
command!          GistHealth call gist#health#show()

command! -nargs=* -complete=tag  GistBlast   call gist#kin#command('blast', <q-args>)
command! -nargs=* -complete=file GistSimilar call gist#kin#command('similar', <q-args>)

" -------------------------------------------------------------------- mappings
nnoremap <silent> <Plug>(gist-cword)     :<C-u>call gist#cword('vimgrep', 0)<CR>
nnoremap <silent> <Plug>(gist-rank)      :<C-u>call gist#cword('rank', 0)<CR>
nnoremap <silent> <Plug>(gist-cword-loc) :<C-u>call gist#cword('vimgrep', 0, 1)<CR>
xnoremap <silent> <Plug>(gist-selection) :<C-u>call gist#visual('vimgrep', 0)<CR>
nnoremap <silent> <Plug>(gist-operator)  :<C-u>set operatorfunc=gist#operator<CR>g@
nnoremap <silent> <Plug>(gist-blast)     :<C-u>GistBlast<CR>
nnoremap <silent> <Plug>(gist-similar)   :<C-u>GistSimilar<CR>
nnoremap <silent> <Plug>(gist-stop)      :<C-u>GistStop<CR>

" A default mapping is a suggestion: it is only made if you have not mapped
" the <Plug> yourself and the key is still unclaimed in that mode.
function! s:suggest(mode, lhs, plug) abort
  if hasmapto(a:plug, a:mode) || !empty(maparg(a:lhs, a:mode))
    return
  endif
  execute a:mode . 'map <silent> ' . a:lhs . ' ' . a:plug
endfunction

if get(g:, 'gist_default_mappings', 1)
  let s:lead = get(g:, 'gist_map_prefix', '<Leader>g')
  call s:suggest('n', s:lead . 'g', '<Plug>(gist-cword)')
  call s:suggest('n', s:lead . 'r', '<Plug>(gist-rank)')
  call s:suggest('n', s:lead . 'o', '<Plug>(gist-operator)')
  call s:suggest('n', s:lead . 'b', '<Plug>(gist-blast)')
  call s:suggest('n', s:lead . 's', '<Plug>(gist-similar)')
  call s:suggest('x', s:lead . 'g', '<Plug>(gist-selection)')
  unlet s:lead
endif

" --------------------------------------------------------------------- :help
" A copied directory has no tags file, and a plugin that promises `:help gist`
" should not need a manual :helptags to keep the promise.
let s:doc = expand('<sfile>:p:h:h') . '/doc'
if filereadable(s:doc . '/gist.txt') && !filereadable(s:doc . '/tags')
      \ && filewritable(s:doc) == 2
  silent! execute 'helptags' fnameescape(s:doc)
endif
unlet s:doc

let &cpoptions = s:cpo
unlet s:cpo
