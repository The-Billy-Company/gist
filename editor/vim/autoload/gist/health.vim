" gist/health.vim — one honest answer to "is this actually wired up?"
"
" Editors are where search integrations quietly stop working: a binary that
" left $PATH, an index nobody rebuilt, a 'grepprg' another plugin claimed. The
" report is generated once here and rendered twice — `:GistHealth` in any Vim,
" `:checkhealth gist` in Neovim (lua/gist/health.lua reads this same list).

" Returns [{level, msg, advice}] where level is ok | warn | error | info.
function! gist#health#report() abort
  let l:out = []
  let l:bin = gist#opt('binary')
  if executable(l:bin)
    " `gist 0.2.0` → `0.2.0`: the path already says which binary this is.
    let l:said = split(get(gist#run_sync(['--version']), 0, ''))
    call s:add(l:out, 'ok', printf('%s — %s', exepath(l:bin),
          \ empty(l:said) ? 'version unknown' : l:said[-1]))
  else
    call s:add(l:out, 'error', printf('`%s` not found on $PATH', l:bin),
          \ 'run `zig build -Doptimize=ReleaseFast` (gist package) + install onto PATH, or set g:gist_binary to the full path')
    return l:out
  endif

  call add(l:out, s:index())

  for l:name in ['relate', 'blast']
    let l:sibling = get(g:, 'gist_' . l:name . '_binary', l:name)
    if executable(l:sibling)
      call s:add(l:out, 'ok', printf('%s — :Gist%s available', l:sibling,
            \ l:name ==# 'relate' ? 'Similar' : 'Blast'))
    else
      call s:add(l:out, 'warn', printf('`%s` not found — :Gist%s is disabled',
            \ l:sibling, l:name ==# 'relate' ? 'Similar' : 'Blast'),
            \ 'build the gist package (`zig build -Doptimize=ReleaseFast`) and install the three binaries onto PATH')
    endif
  endfor

  if gist#job#async()
    call s:add(l:out, 'ok', 'async: searches stream into the list without blocking')
  else
    call s:add(l:out, 'warn', 'async unavailable — searches run synchronously',
          \ gist#opt('async') ? 'this Vim has no job control' : 'g:gist_async is off')
  endif

  if &grepprg =~# '\<' . fnamemodify(l:bin, ':t') . '\>'
    call s:add(l:out, 'ok', "'grepprg' → " . &grepprg)
  else
    call s:add(l:out, 'info', "'grepprg' is yours: " . &grepprg,
          \ "let g:gist_grepprg = 'always' to point :grep at gist too")
  endif

  let l:mapped = []
  for l:plug in ['(gist-cword)', '(gist-rank)', '(gist-operator)',
        \ '(gist-blast)', '(gist-similar)', '(gist-selection)']
    let l:lhs = s:bound(l:plug)
    if !empty(l:lhs) | call add(l:mapped, l:lhs . ' → ' . l:plug) | endif
  endfor
  call s:add(l:out, empty(l:mapped) ? 'info' : 'ok',
        \ empty(l:mapped) ? 'no mappings claimed' : 'mappings: ' . join(l:mapped, ', '),
        \ empty(l:mapped) ? 'see :help gist-mappings for the <Plug> names' : '')

  call s:add(l:out, s:helped() ? 'ok' : 'warn',
        \ s:helped() ? ':help gist is tagged' : ':help gist has no tags file',
        \ s:helped() ? '' : 'run :helptags on the plugin''s doc/ directory')
  return l:out
endfunction

" Render for plain Vim; Neovim's :checkhealth renders the same list itself.
function! gist#health#show() abort
  echohl Title | echo 'gist' | echohl None
  for l:row in gist#health#report()
    execute 'echohl' get({'ok': 'MoreMsg', 'warn': 'WarningMsg',
          \ 'error': 'ErrorMsg', 'info': 'Comment'}, l:row.level, 'None')
    echo printf('  %-5s %s', l:row.level, l:row.msg)
    echohl None
    if !empty(l:row.advice) | echo '        → ' . l:row.advice | endif
  endfor
endfunction

function! s:add(out, level, msg, ...) abort
  call add(a:out, s:row(a:level, a:msg, a:0 ? a:1 : ''))
endfunction

function! s:row(level, msg, advice) abort
  return {'level': a:level, 'msg': a:msg, 'advice': a:advice}
endfunction

" What the index knows about this tree, in the terms that decide whether to
" act on it: how much is indexed, whether it is bound here, and how stale.
" Read from `status --json` so the answer survives a reworded status line.
function! s:index() abort
  let l:raw = join(gist#run_sync(['status', '--json']), '')
  let l:got = {}
  try
    let l:got = json_decode(l:raw)
  catch
  endtry
  let l:index = type(l:got) == type({}) ? get(l:got, 'index', v:null) : v:null
  if type(l:index) != type({})
    return s:row('warn', 'no trigram index for this tree',
          \ 'run :GistIndex — searches still answer live, just slower')
  endif
  if !get(l:got, 'bound_here', 1)
    return s:row('warn', 'the index was built over ' . string(get(l:got, 'built_over', '')),
          \ 'run :GistIndex to re-bind it here — until then searches scan live')
  endif
  return s:row('ok', printf('index: %s, %d files, built %s ago (newer edits fold in per query)',
        \ get(l:got, 'state', 'ready'), get(l:index, 'files_indexed', 0),
        \ s:since(get(get(l:got, 'freshness', {}), 'age_seconds', 0))), '')
endfunction

function! s:since(seconds) abort
  let l:n = float2nr(a:seconds)
  if l:n < 90 | return l:n . 's' | endif
  if l:n < 5400 | return (l:n / 60) . 'm' | endif
  if l:n < 172800 | return (l:n / 3600) . 'h' | endif
  return (l:n / 86400) . 'd'
endfunction

" The key a <Plug> ended up on, when this Vim can tell us; otherwise just the
" fact that something claimed it.
" The key a <Plug> is bound to, tagged with its mode unless that mode is
" normal: one key legitimately reaches two <Plug>s (<Leader>gg is the cword
" search in normal mode and the selection search in visual), and a row that
" prints the same key twice untagged reads like a collision.
function! s:bound(plug) abort
  let l:rhs = '<Plug>' . a:plug
  if exists('*maplist')
    for l:map in maplist()
      if get(l:map, 'rhs', '') ==# l:rhs
        let l:mode = trim(get(l:map, 'mode', ''))
        return l:map.lhs . (empty(l:mode) || l:mode ==# 'n' ? '' : ' (' . l:mode . ')')
      endif
    endfor
    return ''
  endif
  for l:mode in ['n', 'x']
    if hasmapto(l:rhs, l:mode) | return l:mode . 'map' | endif
  endfor
  return ''
endfunction

function! s:helped() abort
  if exists('*getcompletion') | return !empty(getcompletion('gist.txt', 'help')) | endif
  return !empty(globpath(&runtimepath, 'doc/tags'))
endfunction
