" gist/args.vim — the command line: how it splits, and what <Tab> knows.
"
" Arguments reach gist as an argv list, so there is no shell in the path and
" nothing to double-escape. What a user types is still split the way a shell
" would split it — quotes and backslashes behave as the fingers expect — but
" `|`, `$`, `&` and friends survive verbatim into the pattern.
"
" Completion is answered by the binary rather than by a hardcoded table:
" `gist --schema` names every flag it accepts and `--type-list` every -t name,
" so the completion can never drift from the gist that is actually installed.

let s:cache = {}

" Split a typed argument string into argv, honoring '…', "…" and backslash.
function! gist#args#split(str) abort
  let l:argv = []
  let l:tok = ''
  let l:live = 0
  let l:quote = ''
  let l:i = 0
  while l:i < strlen(a:str)
    let l:c = a:str[l:i]
    let l:i += 1
    if !empty(l:quote)
      if l:c ==# l:quote
        let l:quote = ''
      elseif l:c ==# '\' && l:quote ==# '"' && l:i < strlen(a:str)
        let l:tok .= a:str[l:i]
        let l:i += 1
      else
        let l:tok .= l:c
      endif
    elseif l:c ==# '"' || l:c ==# "'"
      let l:quote = l:c
      let l:live = 1
    elseif l:c ==# '\' && l:i < strlen(a:str)
      let l:tok .= a:str[l:i]
      let l:live = 1
      let l:i += 1
    elseif l:c =~# '\s'
      if l:live || !empty(l:tok) | call add(l:argv, l:tok) | endif
      let l:tok = ''
      let l:live = 0
    else
      let l:tok .= l:c
    endif
  endwhile
  if l:live || !empty(l:tok) | call add(l:argv, l:tok) | endif
  return l:argv
endfunction

" Which stdout shape will this argv produce? The parse depends on it, and
" guessing wrong is how a count line becomes a file named "path:12".
function! gist#args#shape(argv, fallback) abort
  for l:a in a:argv
    if l:a =~# '^--files\%(-with-matches\|-without-match\)\=$' || l:a =~# '^-\a*l\a*$'
      return 'files'
    elseif l:a =~# '^--count\%(-matches\)\=$' || l:a =~# '^-\a*c\a*$'
      return 'counts'
    endif
  endfor
  return a:fallback
endfunction

function! gist#args#complete(lead, cmdline, pos) abort
  let l:before = strpart(a:cmdline, 0, a:pos)
  let l:words = gist#args#split(substitute(l:before, '^\s*\S\+\s*', '', ''))
  let l:prev = empty(a:lead) ? get(l:words, -1, '') : get(l:words, -2, '')
  if l:prev =~# '^\%(-t\|-T\|--type\|--type-not\|--type-add\)$'
    return s:pick(s:types(), a:lead)
  endif
  if a:lead =~# '^-'
    return s:pick(s:flags(), a:lead)
  endif
  return getcompletion(a:lead, 'file')
endfunction

function! s:pick(pool, lead) abort
  return filter(copy(a:pool), 'stridx(v:val, a:lead) == 0')
endfunction

" Every flag the installed gist admits, read once per session from --schema.
function! s:flags() abort
  if has_key(s:cache, 'flags') | return s:cache.flags | endif
  let l:flags = []
  let l:schema = s:json(['--schema'])
  for l:bucket in values(s:dig(l:schema, ['search', 'ripgrep_compatibility', 'buckets'], {}))
    if type(l:bucket) != type([]) | continue | endif
    for l:row in l:bucket
      if type(l:row) == type({}) | call extend(l:flags, get(l:row, 'spellings', [])) | endif
    endfor
  endfor
  for l:row in s:dig(l:schema, ['search', 'native_additions'], [])
    call add(l:flags, get(l:row, 'native', ''))
  endfor
  call filter(l:flags, '!empty(v:val) && v:val =~# "^-"')
  let s:cache.flags = uniq(sort(l:flags))
  return s:cache.flags
endfunction

function! s:types() abort
  if has_key(s:cache, 'types') | return s:cache.types | endif
  let l:rows = gist#run_sync(['--type-list'])
  let s:cache.types = map(filter(l:rows, 'v:val =~# "^\\w"'), 'matchstr(v:val, "^[^:]\\+")')
  return s:cache.types
endfunction

function! s:json(argv) abort
  let l:raw = join(gist#run_sync(a:argv), '')
  try
    return json_decode(l:raw)
  catch
    return {}
  endtry
endfunction

function! s:dig(obj, keys, default) abort
  let l:at = a:obj
  for l:key in a:keys
    if type(l:at) != type({}) || !has_key(l:at, l:key) | return a:default | endif
    let l:at = l:at[l:key]
  endfor
  return l:at
endfunction

" Forget what the binary told us — for after an upgrade, or a test.
function! gist#args#forget() abort
  let s:cache = {}
endfunction
