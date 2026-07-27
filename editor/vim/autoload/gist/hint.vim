" gist/hint.vim — gist's stderr is coaching, so treat it as an offer.
"
" A miss prints why it missed and what would probably fix it:
"
"   gist: no matches for 'Widget' · scope: src
"   gist: try -i — the pattern has uppercase; retry case-insensitive
"   gist: try -uu — gitignored and hidden files were excluded
"
" Nothing here ever reaches the quickfix list — a hint is not a match. What it
" does reach is a prompt: the suggested flags are re-runnable, so a miss costs
" one keystroke instead of retyping the query. `:GistRetry N` picks the same
" offers later, and `g:gist_hint_prompt = 0` keeps the report silent.

let s:say = '^gist: '
" gist separates a suggestion from its reason with a spaced em dash; the ASCII
" spelling is accepted too, and both must be spaced so `--flag` is never it.
let s:dash = '\s\+\%(\%u2014\|--\)\s\+'

" Sort stderr into {tries: [{flags, why}], said: [line], error: bool}.
function! gist#hint#read(lines) abort
  let l:read = {'tries': [], 'said': [], 'error': 0}
  for l:line in a:lines
    if empty(substitute(l:line, '\s', '', 'g')) | continue | endif
    let l:body = substitute(l:line, s:say, '', '')
    " Only a suggestion that names flags is re-runnable; advice in prose
    " ("try a wider scope") is still worth showing, just not as an offer.
    let l:try = matchlist(l:body, '^try\s\+\(.\{-}\)' . s:dash . '\(.*\)$')
    if !empty(l:try) && l:try[1] =~# '^-'
      call add(l:read.tries, {'flags': gist#args#split(l:try[1]), 'why': l:try[2]})
    else
      call add(l:read.said, l:body)
    endif
    if l:body =~# '^error\|^unrecognized\|^usage:' | let l:read.error = 1 | endif
  endfor
  return l:read
endfunction

" Report a finished run. `state` is the search state from gist#search().
function! gist#hint#report(state, code) abort
  let l:read = a:state.hints
  if a:code >= 2 || l:read.error
    return s:echo('ErrorMsg', s:headline(l:read, 'gist failed'))
  endif
  if a:state.found > 0
    if gist#opt('hints') && !empty(l:read.said)
      call s:echo('', s:headline(l:read, ''))
    endif
    return
  endif
  let l:head = s:headline(l:read, printf('gist: no matches for %s', a:state.subject))
  if !gist#opt('hints')
    return s:echo('WarningMsg', l:head)
  endif
  if empty(l:read.tries) || !gist#opt('hint_prompt')
    return s:echo('WarningMsg', s:joined(l:head, l:read.tries))
  endif
  call timer_start(0, function('s:offer', [l:head, l:read.tries]))
endfunction

" The prompt runs on a timer: inputlist() inside a job callback would fight
" whatever redraw is in flight.
"
" A search finishes when it finishes, which may be well after you moved on. If
" anything is already waiting in the typeahead, those keys were meant for the
" buffer, not for a menu that just appeared over it — so the offer degrades to
" the printed form, which :GistRetry can still act on.
function! s:offer(head, tries, _timer) abort
  if getchar(1) isnot 0
    return s:echo('WarningMsg', s:joined(a:head, a:tries))
  endif
  let l:menu = [a:head]
  for l:i in range(len(a:tries))
    call add(l:menu, printf('%d. retry with %s — %s', l:i + 1,
          \ join(a:tries[l:i].flags), a:tries[l:i].why))
  endfor
  let l:pick = inputlist(l:menu)
  redraw
  if l:pick > 0 && l:pick <= len(a:tries)
    call gist#retry(l:pick)
  endif
endfunction

function! s:headline(read, fallback) abort
  return empty(a:read.said) ? a:fallback : join(a:read.said, ' · ')
endfunction

" The printed form of an offer names the command that takes it, so a miss is
" still one step from the answer when the prompt is off or was stood down.
function! s:joined(head, tries) abort
  let l:parts = [a:head]
  for l:i in range(len(a:tries))
    call add(l:parts, printf(':GistRetry %d → %s (%s)', l:i + 1,
          \ join(a:tries[l:i].flags), a:tries[l:i].why))
  endfor
  return join(l:parts, ' | ')
endfunction

function! s:echo(hl, msg) abort
  if empty(a:msg) | return | endif
  if !empty(a:hl) | execute 'echohl' a:hl | endif
  echo a:msg
  if !empty(a:hl) | echohl None | endif
endfunction
