" gist/kin.vim — the two questions an exact pattern can't ask.
"
" `zig build` puts three binaries on PATH, and the other two answer
" what grep cannot: `blast blast SYMBOL` is the live blast radius of a
" symbol (its definition, dependents, dependencies, structural twins, ripple,
" and the comments that name it) read from CURRENT bytes, and `relate similar
" FILE` is the compression-nearest neighborhood of the buffer you are in.
"
" Both land in the same quickfix list as a search, so :cnext walks a blast
" radius exactly the way it walks matches. That is the point: no new UI to
" learn, just two more things the list can hold.

let s:groups = [
      \ ['def',        ['seed', 'def']],
      \ ['dependent',  ['direct', 'dependents']],
      \ ['dependency', ['direct', 'dependencies']],
      \ ['twin',       ['tangential', 'twins']],
      \ ['ripple',     ['tangential', 'ripple']],
      \ ['comment',    ['comments']],
      \ ]

" Blast radius of a symbol → quickfix. Groups arrive labeled so the list
" reads as an ordered story: the definition, who uses it, what it uses, then
" the echoes it leaves in twins, ripple, and prose.
function! gist#kin#blast(symbol, argv) abort
  let l:symbol = empty(a:symbol) ? expand('<cword>') : a:symbol
  if empty(l:symbol) | return gist#warn('gist: no symbol under the cursor') | endif
  let l:bin = gist#kin#binary('blast')
  if empty(l:bin) | return | endif
  let l:said = {'out': [], 'err': []}
  call gist#say(printf('gist: blast %s …', l:symbol))
  call gist#job#start([l:bin, 'blast', l:symbol, '--json'] + a:argv, {
        \ 'out':  function('s:gather', [l:said, 'out']),
        \ 'err':  function('s:gather', [l:said, 'err']),
        \ 'done': function('s:blasted', [l:symbol, l:said]),
        \ })
endfunction

function! s:blasted(symbol, said, code) abort
  let l:report = s:decode(join(a:said.out, ''))
  if empty(l:report)
    return gist#warn(printf('gist: blast %s — %s', a:symbol,
          \ empty(a:said.err) ? 'no report' : a:said.err[0]))
  endif
  let l:items = []
  for [l:group, l:path] in s:groups
    call s:collect(l:items, s:at(l:report, l:path, []), l:group)
  endfor
  if empty(l:items)
    return gist#warn(printf('gist: blast %s — no live neighborhood%s', a:symbol,
          \ empty(get(l:report, 'notes', [])) ? '' : ' · ' . l:report.notes[0]))
  endif
  call gist#sink#open({'title': 'blast ' . a:symbol, 'shape': 'entries',
        \ 'loclist': 0, 'jump': gist#opt('jump_to_first')})
  call gist#sink#items(l:items)
  let l:omitted = get(s:at(l:report, ['stats'], {}), 'omitted', 0)
  call gist#say(printf('blast %s [%s] · %d entries%s', a:symbol,
        \ s:at(l:report, ['seed', 'kind'], 'unknown'), gist#sink#close(),
        \ l:omitted > 0 ? printf(' · %d omitted (raise --budget)', l:omitted) : ''))
endfunction

function! s:collect(items, rows, group) abort
  if type(a:rows) != type([]) | return | endif
  for l:row in a:rows
    if type(l:row) != type({}) || empty(get(l:row, 'path', '')) | continue | endif
    let l:note = '[' . a:group . ']'
    if !empty(get(l:row, 'in', '')) | let l:note .= ' in ' . l:row['in'] | endif
    if !empty(get(l:row, 'use', '')) | let l:note .= ' ' . l:row['use'] | endif
    if has_key(l:row, 'distance') | let l:note .= ' d=' . string(l:row.distance) | endif
    if !empty(get(l:row, 'text', '')) | let l:note .= ' ' . l:row.text | endif
    call add(a:items, {'filename': l:row.path, 'lnum': get(l:row, 'line', 1),
          \ 'text': l:note, 'type': a:group ==# 'def' ? 'I' : ''})
  endfor
endfunction

" Compression-nearest files to this one → quickfix, closest first.
function! gist#kin#similar(path, argv) abort
  let l:path = empty(a:path) ? expand('%:p') : a:path
  if empty(l:path) || !filereadable(l:path)
    return gist#warn('gist: no readable file to compare')
  endif
  let l:bin = gist#kin#binary('relate')
  if empty(l:bin) | return | endif
  let l:rel = fnamemodify(l:path, ':.')
  let l:said = {'out': [], 'err': []}
  call gist#sink#open({'title': 'similar ' . l:rel, 'shape': 'entries',
        \ 'loclist': 0, 'jump': 0})
  call gist#job#start([l:bin, 'similar', l:rel]
        \ + (empty(a:argv) ? ['--top', '10'] : a:argv), {
        \ 'out':  function('s:kinship'),
        \ 'err':  function('s:gather', [l:said, 'err']),
        \ 'done': function('s:related', [l:rel, l:said]),
        \ })
endfunction

" `relate similar` prints "<distance>  <path>", nearest first.
function! s:kinship(lines) abort
  let l:items = []
  for l:line in a:lines
    let l:m = matchlist(l:line, '^\s*\([0-9.]\+\)\s\+\(\S.*\)$')
    if empty(l:m) | continue | endif
    call add(l:items, {'filename': l:m[2], 'lnum': 1, 'text': 'distance ' . l:m[1]})
  endfor
  call gist#sink#items(l:items)
endfunction

function! s:related(subject, said, code) abort
  if gist#sink#close() == 0
    call gist#warn(printf('gist: no kin for %s%s', a:subject,
          \ empty(a:said.err) ? '' : ' · ' . substitute(a:said.err[0], '^relate: ', '', '')))
  endif
endfunction

" :GistBlast / :GistSimilar — a leading non-flag word is the subject, the rest
" reaches the binary untouched, and no subject at all means "what I'm on".
function! gist#kin#command(verb, args) abort
  let l:argv = gist#args#split(a:args)
  let l:subject = !empty(l:argv) && l:argv[0] !~# '^-' ? remove(l:argv, 0) : ''
  return a:verb ==# 'blast'
        \ ? gist#kin#blast(l:subject, l:argv)
        \ : gist#kin#similar(l:subject, l:argv)
endfunction

" relate and blast ride alongside gist; name the fix when one is missing.
function! gist#kin#binary(name) abort
  let l:bin = get(g:, 'gist_' . a:name . '_binary', a:name)
  if executable(l:bin) | return l:bin | endif
  call gist#warn(printf('gist: %s is not on $PATH — run `zig build -Doptimize=ReleaseFast` (gist package) + install onto PATH', a:name))
  return ''
endfunction

function! s:gather(into, stream, lines) abort
  call extend(a:into[a:stream], a:lines)
endfunction

function! s:decode(raw) abort
  try
    return json_decode(a:raw)
  catch
    return {}
  endtry
endfunction

function! s:at(obj, keys, ...) abort
  let l:default = a:0 ? a:1 : {}
  let l:at = a:obj
  for l:key in a:keys
    if type(l:at) != type({}) || !has_key(l:at, l:key) | return l:default | endif
    let l:at = l:at[l:key]
  endfor
  return l:at
endfunction
