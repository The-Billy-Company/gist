" gist/sink.vim — results become a quickfix (or location) list as they arrive.
"
" Vim's list is the destination every other tool already knows how to drive:
" :cnext, :cdo, :cfdo, the preview window, and every quickfix plugin. So the
" job's stdout is streamed into ONE list — pinned by id, so a concurrent :grep
" can't steal the append — and the window opens on the first batch instead of
" after the last one. That is the whole difference between `:grep` freezing on
" a big tree and results arriving while you read them.
"
" Each output shape gist can produce parses differently, and the fast path
" (errorformat, parsed in C) is used wherever the running Vim has it.

let s:cur = {}

" gist's line shapes. --vimgrep is the ripgrep-compatible one; the rest are
" parsed here because they carry meaning errorformat would flatten away.
let s:efm = '%f:%l:%c:%m,%-G%.%#'
let s:rank_row = '^\s*\d\+\.\s\+\(.\{-}\):\(\d\+\)\s\+\(.*\)$'
let s:count_row = '^\(.\{-}\):\(\d\+\)$'

" Begin one run. spec: {title, shape, loclist, jump, height}.
function! gist#sink#open(spec) abort
  let s:cur = extend({'shape': 'vimgrep', 'loclist': 0, 'jump': 0, 'count': 0,
        \ 'shown': 0, 'win': win_getid()}, a:spec)
  call s:write(' ', {'title': s:cur.title, 'items': []})
  let s:cur.id = s:read({'id': 0}).id
  return s:cur.id
endfunction

function! gist#sink#push(lines) abort
  if empty(s:cur) | return | endif
  if s:cur.shape ==# 'vimgrep' && s:fast()
    call s:write('a', {'id': s:cur.id, 'lines': a:lines, 'efm': s:efm})
    call s:tally()
  else
    call gist#sink#items(s:parse(a:lines))
  endif
endfunction

" Push already-built quickfix entries (the shape blast and similar speak).
function! gist#sink#items(items) abort
  if empty(s:cur) || empty(a:items) | return | endif
  call s:write('a', {'id': s:cur.id, 'items': a:items})
  call s:tally()
endfunction

" Ask the list for its size rather than re-reading every item per batch.
function! s:tally() abort
  let l:got = s:read({'size': 0})
  let s:cur.count = get(l:got, 'size', len(get(s:read({'items': 0}), 'items', [])))
  if s:cur.count > 0 | call s:reveal() | endif
endfunction

" Finish the run: stamp the count into the title, let quickfix plugins hook the
" same autocmd :grep fires, and report how many entries landed.
function! gist#sink#close() abort
  if empty(s:cur) | return 0 | endif
  let l:n = s:cur.count
  if l:n > 0
    call s:write('r', {'id': s:cur.id, 'title': printf('%s (%d)', s:cur.title, l:n)})
  endif
  let l:event = s:cur.loclist ? 'lgrep' : 'grep'
  if exists('#QuickFixCmdPost#' . l:event)
    execute 'silent doautocmd <nomodeline> QuickFixCmdPost' l:event
  endif
  let s:cur = {}
  return l:n
endfunction

function! gist#sink#abandon() abort
  let s:cur = {}
endfunction

function! gist#sink#count() abort
  return get(s:cur, 'count', 0)
endfunction

" One line shape per gist output mode; anything unparseable is dropped rather
" than admitted as a phantom file (the failure mode of a catch-all `%f`).
function! s:parse(lines) abort
  if s:cur.shape ==# 'vimgrep' | return s:parse_vimgrep(a:lines) | endif
  let l:items = []
  for l:line in a:lines
    if empty(l:line) | continue | endif
    if s:cur.shape ==# 'files'
      call add(l:items, {'filename': l:line, 'lnum': 1, 'text': ''})
      continue
    endif
    let l:m = matchlist(l:line, s:cur.shape ==# 'rank' ? s:rank_row : s:count_row)
    if empty(l:m) | continue | endif
    if s:cur.shape ==# 'rank'
      call add(l:items, {'filename': l:m[1], 'lnum': str2nr(l:m[2]), 'text': l:m[3]})
    else
      call add(l:items, {'filename': l:m[1], 'lnum': 1,
            \ 'text': printf('%s match%s', l:m[2], l:m[2] ==# '1' ? '' : 'es')})
    endif
  endfor
  return l:items
endfunction

" Only reached on a Vim too old for setqflist()'s 'lines' key.
function! s:parse_vimgrep(lines) abort
  let l:items = []
  for l:line in a:lines
    let l:m = matchlist(l:line, '^\(.\{-}\):\(\d\+\):\(\d\+\):\(.*\)$')
    if !empty(l:m)
      call add(l:items, {'filename': l:m[1], 'lnum': str2nr(l:m[2]),
            \ 'col': str2nr(l:m[3]), 'text': l:m[4]})
    endif
  endfor
  return l:items
endfunction

function! s:fast() abort
  return has('nvim') || has('patch-8.0.1023')
endfunction

function! s:write(action, what) abort
  if s:cur.loclist
    return setloclist(s:cur.win, [], a:action, a:what)
  endif
  return setqflist([], a:action, a:what)
endfunction

function! s:read(what) abort
  let l:what = extend({'id': get(s:cur, 'id', 0)}, a:what)
  return s:cur.loclist ? getloclist(s:cur.win, l:what) : getqflist(l:what)
endfunction

" Window work waits for a timer: a job callback can land mid-redraw, and
" opening a window there is how plugins earn their "sometimes garbles the
" screen" reputation.
function! s:reveal() abort
  if s:cur.shown || !gist#opt('open_quickfix') | return | endif
  let s:cur.shown = 1
  call timer_start(0, function('s:show', [s:cur.loclist, s:cur.jump, s:cur.win]))
endfunction

function! s:show(loclist, jump, win, _timer) abort
  let l:here = win_getid()
  if a:loclist && !win_gotoid(a:win) | return | endif
  let l:height = gist#opt('qf_height')
  execute 'botright' (a:loclist ? 'lwindow' : 'cwindow') l:height
  if a:jump
    silent! execute a:loclist ? 'lfirst' : 'cfirst'
  elseif win_getid() != l:here
    call win_gotoid(l:here)
  endif
endfunction
