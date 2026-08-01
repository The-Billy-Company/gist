" gist.vim — the search itself: one pipeline, four ways in.
"
" :Gist, :GistRank, :GistFiles and the <Plug> mappings all funnel into
" gist#search(). It resolves the binary, decides which output shape the flags
" will produce, streams stdout into the quickfix list, keeps stderr in the
" coaching channel where it belongs, and remembers enough about the run that
" :GistRetry can re-ask the same question with gist's own suggestion applied.
"
" Options are read at the moment they are used, and a buffer-local twin always
" wins, so `let b:gist_flags = ['-t', 'go']` in an ftplugin is a per-filetype
" search policy with no reload and no plugin support required.

let s:defaults = {
      \ 'binary':           'gist',
      \ 'flags':            [],
      \ 'async':            1,
      \ 'open_quickfix':    1,
      \ 'jump_to_first':    1,
      \ 'hints':            1,
      \ 'hint_prompt':      1,
      \ 'uncap':            1,
      \ 'qf_height':        10,
      \ 'default_mappings': 1,
      \ 'grepprg':          'auto',
      \ }

let s:job = 0
let s:state = {}

function! gist#opt(name) abort
  let l:var = 'gist_' . a:name
  return get(b:, l:var, get(g:, l:var, s:defaults[a:name]))
endfunction

function! gist#defaults() abort
  return copy(s:defaults)
endfunction

" The one entry point. spec: {argv, mode, loclist, jump, subject}.
function! gist#search(spec) abort
  let l:bin = gist#binary()
  if empty(l:bin) | return 0 | endif
  call s:halt()
  let l:spec = extend({'mode': 'vimgrep', 'loclist': 0, 'argv': [],
        \ 'jump': gist#opt('jump_to_first')}, a:spec)
  let l:spec.shape = gist#args#shape(l:spec.argv, l:spec.mode)
  let l:argv = [l:bin] + s:shaping(l:spec) + s:extra(l:spec.argv) + l:spec.argv
  let l:title = 'gist ' . join(l:spec.argv)
  let s:state = {'spec': l:spec, 'argv': l:argv, 'found': 0, 'err': [],
        \ 'subject': get(l:spec, 'subject', l:title), 'clock': reltime(),
        \ 'hints': {'tries': [], 'said': [], 'error': 0}}
  call gist#sink#open({'title': l:title, 'shape': l:spec.shape,
        \ 'loclist': l:spec.loclist, 'jump': l:spec.jump})
  if exists('#User#GistPre')
    doautocmd <nomodeline> User GistPre
  endif
  let s:job = gist#job#start(l:argv, {
        \ 'out':  function('gist#sink#push'),
        \ 'err':  function('s:aside'),
        \ 'done': function('s:finished'),
        \ })
  return 1
endfunction

" --vimgrep is added only when the flags don't already choose a shape: asking
" for `-l` and column-formatted matches at once is a contradiction, not a
" default worth defending.
function! s:shaping(spec) abort
  if a:spec.shape ==# 'rank'
    return s:names(a:spec.argv, '^--rank') ? [] : ['--rank']
  elseif a:spec.shape ==# 'files'
    return s:names(a:spec.argv, '^\%(--files\|-\a*l\a*$\)') ? [] : ['-l']
  elseif a:spec.shape ==# 'counts'
    return []
  endif
  return s:names(a:spec.argv, '^--vimgrep$') ? [] : ['--vimgrep']
endfunction

" An editor is not an agent: the soft output budget that protects a context
" window would silently truncate a quickfix list, so lift it unless asked not.
function! s:extra(argv) abort
  let l:extra = copy(gist#opt('flags'))
  if gist#opt('uncap') && !s:names(a:argv, '^--\%(un\)\=cap$')
    call add(l:extra, '--uncap')
  endif
  return l:extra
endfunction

function! s:names(argv, pattern) abort
  return !empty(filter(copy(a:argv), 'v:val =~# a:pattern'))
endfunction

function! s:aside(lines) abort
  call extend(s:state.err, a:lines)
endfunction

function! s:finished(code) abort
  let s:job = 0
  let s:state.found = gist#sink#close()
  let s:state.code = a:code
  let s:state.hints = gist#hint#read(s:state.err)
  let s:state.elapsed = reltimestr(reltime(s:state.clock))
  call gist#hint#report(s:state, a:code)
  if exists('#User#GistPost')
    doautocmd <nomodeline> User GistPost
  endif
endfunction

" What the last run asked and what came back — the retry offers hang off this,
" and the tests read it instead of scraping the screen.
function! gist#last() abort
  return s:state
endfunction

" Re-ask the last question. With a number, apply that suggestion from gist's
" own stderr first (`:GistRetry 1` after a miss that suggested -i).
function! gist#retry(...) abort
  if empty(s:state) | return gist#warn('gist: nothing to retry') | endif
  let l:spec = deepcopy(s:state.spec)
  let l:nr = a:0 && a:1 > 0 ? a:1 : 0
  if l:nr > 0
    let l:tries = s:state.hints.tries
    if l:nr > len(l:tries)
      return gist#warn(printf('gist: no suggestion %d (have %d)', l:nr, len(l:tries)))
    endif
    let l:spec.argv = l:tries[l:nr - 1].flags + l:spec.argv
  endif
  return gist#search(l:spec)
endfunction

function! gist#stop() abort
  if s:job is 0 | return gist#say('gist: nothing running') | endif
  call s:halt()
  call gist#warn('gist: stopped')
endfunction

function! s:halt() abort
  if s:job isnot 0
    call gist#job#stop(s:job)
    let s:job = 0
    call gist#sink#abandon()
  endif
endfunction

function! gist#running() abort
  return s:job isnot 0
endfunction

" For 'statusline': shows only while a search is in flight.
function! gist#statusline() abort
  return gist#running() ? '[gist…]' : ''
endfunction

" ---------------------------------------------------------------- entry points

" Every command lands here: mode is the output shape asked for, the optional
" trailing argument routes the answer to the window's location list instead.
function! gist#command(mode, bang, args, ...) abort
  let l:loclist = a:0 ? a:1 : 0
  let l:argv = gist#args#split(a:args)
  if empty(l:argv) | return gist#cword(a:mode, a:bang, l:loclist) | endif
  return gist#search({'mode': a:mode, 'argv': l:argv, 'jump': !a:bang,
        \ 'loclist': l:loclist, 'subject': string(a:args)})
endfunction

" The word under the cursor, searched as a word and as a literal — the reflex
" `*` teaches, pointed at the tree instead of the buffer.
function! gist#cword(mode, bang, ...) abort
  let l:word = expand('<cword>')
  if empty(l:word) | return gist#warn('gist: no word under the cursor') | endif
  return s:literal(a:mode, a:bang, l:word, ['--word-regexp'], a:0 ? a:1 : 0)
endfunction

function! gist#visual(mode, bang, ...) abort
  let l:text = s:selected()
  if empty(l:text) | return gist#warn('gist: empty selection') | endif
  return s:literal(a:mode, a:bang, l:text, [], a:0 ? a:1 : 0)
endfunction

" 'operatorfunc': <Plug>(gist-operator) plus any motion searches that text.
function! gist#operator(type) abort
  let l:motion = a:type ==# 'line' ? "'[V']y"
        \ : a:type ==# 'block' ? "`[\<C-v>`]y" : '`[v`]y'
  let l:text = s:yanked(l:motion)
  if empty(l:text) | return gist#warn('gist: nothing to search') | endif
  return s:literal('vimgrep', 0, l:text, [], 0)
endfunction

" A selection or a motion may cross line breaks, and gist can follow it there:
" -U searches the file as one string, so `<Leader>goip` asks for a paragraph
" verbatim — the same question a line-at-a-time grep has no way to put.
function! s:literal(mode, bang, text, flags, loclist) abort
  let l:span = a:text =~# "\n" ? ['--multiline'] : []
  return gist#search({'mode': a:mode, 'loclist': a:loclist,
        \ 'argv': ['--fixed-strings'] + l:span + a:flags + ['--', a:text],
        \ 'jump': !a:bang, 'subject': string(a:text)})
endfunction

function! s:selected() abort
  return s:yanked('gvy')
endfunction

" Yank what the given normal-mode keys select, then put the register and the
" view back — charwise, linewise and blockwise all answer the same way, and a
" linewise yank's trailing newline is not part of what was selected.
function! s:yanked(keys) abort
  let l:saved = [getreg('"'), getregtype('"')]
  let l:view = winsaveview()
  try
    silent execute 'normal! ' . a:keys
    return substitute(@", '\n\+$', '', '')
  finally
    call setreg('"', l:saved[0], l:saved[1])
    call winrestview(l:view)
  endtry
endfunction

" ------------------------------------------------------------------- lifecycle

" Bare `:GistIndex` is the drift-gated incremental fold (a no-op in
" milliseconds when nothing changed); `:GistIndex!` rebuilds from scratch.
function! gist#index(bang) abort
  let l:bin = gist#binary()
  if empty(l:bin) | return | endif
  let l:argv = [l:bin, 'index'] + (a:bang ? [] : ['--auto'])
  call gist#say('gist: indexing…')
  let l:said = []
  call gist#job#start(l:argv, {
        \ 'out':  function('s:collect', [l:said]),
        \ 'err':  function('s:collect', [l:said]),
        \ 'done': function('s:reported', [l:said, 'gist: index done']),
        \ })
endfunction

function! gist#status() abort
  let l:bin = gist#binary()
  if empty(l:bin) | return | endif
  let l:said = []
  call gist#job#start([l:bin, 'status'], {
        \ 'out':  function('s:collect', [l:said]),
        \ 'err':  function('s:collect', [l:said]),
        \ 'done': function('s:reported', [l:said, 'gist: no status']),
        \ })
endfunction

function! s:collect(into, lines) abort
  call extend(a:into, filter(copy(a:lines), '!empty(trim(v:val))'))
endfunction

function! s:reported(said, fallback, code) abort
  call gist#say(empty(a:said) ? a:fallback : join(a:said, ' · '))
endfunction

" ---------------------------------------------------------------------- shared

function! gist#binary() abort
  let l:bin = gist#opt('binary')
  if executable(l:bin) | return l:bin | endif
  call gist#warn(printf('gist: `%s` is not on $PATH — run `zig build -Doptimize=ReleaseFast` (gist package) + install onto PATH, '
        \ . 'or set g:gist_binary', l:bin))
  return ''
endfunction

" A blocking one-shot, for the small answers completion and health need.
function! gist#run_sync(argv) abort
  let l:bin = gist#opt('binary')
  if !executable(l:bin) | return [] | endif
  let l:cmd = join(map([l:bin] + copy(a:argv), 'shellescape(v:val)'), ' ')
  let l:null = has('win32') ? 'NUL' : '/dev/null'
  let l:out = systemlist(l:cmd . ' 2>' . l:null . ' <' . l:null)
  return v:shell_error > 1 ? [] : l:out
endfunction

function! gist#say(msg) abort
  echo a:msg
endfunction

function! gist#warn(msg) abort
  echohl WarningMsg
  echo a:msg
  echohl None
endfunction
