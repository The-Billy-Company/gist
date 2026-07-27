" gist/job.vim — run one argv, hand back whole lines, never block the editor.
"
" Three runtimes answer the same call: Neovim's jobstart, Vim 8's job_start,
" and a synchronous systemlist() for anything older. The differences they
" insist on — partial trailing chunks in Neovim, exit and channel-close racing
" each other in Vim — are settled here so callers only ever see complete lines
" and exactly one finish.

let s:job = {}

" Start `argv` (a list — no shell, so nothing needs quoting for one).
" `sink` carries three Funcrefs: out(lines), err(lines), done(exit_code).
" Returns a handle for gist#job#stop(), or 0 when the run was synchronous.
"
" Every runtime below hands the child /dev/null for stdin. gist inherits rg's
" rule — a readable non-tty stdin *is* the corpus — so a job's default open
" pipe would make a pathless search wait forever on input no one will write.
" Only a null device reads as "nothing was piped" and searches the tree; an
" empty file does not.
function! gist#job#start(argv, sink) abort
  if !gist#job#async()
    return s:sync(a:argv, a:sink)
  endif
  let l:state = {'sink': a:sink, 'rest': {'out': '', 'err': ''}, 'exit': -1, 'closed': 0}
  if has('nvim')
    let l:state.id = jobstart(a:argv, {
          \ 'on_stdout': function('s:nvim_chunk', ['out', l:state]),
          \ 'on_stderr': function('s:nvim_chunk', ['err', l:state]),
          \ 'on_exit':   function('s:nvim_exit', [l:state]),
          \ 'stdin':     'null',
          \ })
    if l:state.id <= 0 | return 0 | endif
  else
    let l:state.id = job_start(a:argv, {
          \ 'out_cb':    function('s:vim_line', ['out', l:state]),
          \ 'err_cb':    function('s:vim_line', ['err', l:state]),
          \ 'exit_cb':   function('s:vim_exit', [l:state]),
          \ 'close_cb':  function('s:vim_close', [l:state]),
          \ 'out_mode':  'nl',
          \ 'err_mode':  'nl',
          \ 'in_io':     'null',
          \ 'noblock':   1,
          \ })
    if job_status(l:state.id) !=# 'run' | return 0 | endif
  endif
  return l:state
endfunction

function! gist#job#stop(handle) abort
  if type(a:handle) != type({}) || !has_key(a:handle, 'id') | return | endif
  let a:handle.sink = {}
  if has('nvim')
    silent! call jobstop(a:handle.id)
  else
    silent! call job_stop(a:handle.id)
  endif
endfunction

function! gist#job#async() abort
  return gist#opt('async') && (has('nvim') ? exists('*jobstart') : exists('*job_start'))
endfunction

" Neovim hands over raw chunks: the first element continues the previous
" chunk's last line and the last element is a fragment until the next call.
function! s:nvim_chunk(stream, state, _id, data, _event) abort
  if empty(a:state.sink) | return | endif
  let l:lines = copy(a:data)
  let l:lines[0] = a:state.rest[a:stream] . l:lines[0]
  let a:state.rest[a:stream] = remove(l:lines, -1)
  call s:feed(a:state, a:stream, l:lines)
endfunction

function! s:nvim_exit(state, _id, code, _event) abort
  for l:stream in ['out', 'err']
    if !empty(a:state.rest[l:stream])
      call s:feed(a:state, l:stream, [a:state.rest[l:stream]])
      let a:state.rest[l:stream] = ''
    endif
  endfor
  call s:finish(a:state, a:code)
endfunction

function! s:vim_line(stream, state, _ch, line) abort
  call s:feed(a:state, a:stream, [a:line])
endfunction

" Vim fires exit_cb and close_cb in either order; the run is over once both
" have landed, which is the only point where all output is guaranteed read.
function! s:vim_exit(state, _job, code) abort
  let a:state.exit = a:code
  if a:state.closed | call s:finish(a:state, a:code) | endif
endfunction

function! s:vim_close(state, _ch) abort
  let a:state.closed = 1
  if a:state.exit >= 0 | call s:finish(a:state, a:state.exit) | endif
endfunction

function! s:feed(state, stream, lines) abort
  if empty(a:state.sink) || empty(a:lines) | return | endif
  call call(a:state.sink[a:stream], [a:lines])
endfunction

" The sink is dropped before the last callback so a stopped job, a second
" close_cb, or an exit racing its channel can never finish the run twice.
function! s:finish(state, code) abort
  if empty(a:state.sink) | return | endif
  let l:sink = a:state.sink
  let a:state.sink = {}
  call call(l:sink.done, [a:code])
endfunction

" Old Vim, or async switched off: one blocking run, same callbacks, same order.
function! s:sync(argv, sink) abort
  let l:err = tempname()
  let l:null = has('win32') ? 'NUL' : '/dev/null'
  let l:cmd = join(map(copy(a:argv), 'shellescape(v:val)'), ' ')
  let l:out = systemlist(l:cmd . ' 2> ' . shellescape(l:err) . ' < ' . l:null)
  let l:code = v:shell_error
  let l:said = filereadable(l:err) ? readfile(l:err) : []
  call delete(l:err)
  if !empty(l:out) | call call(a:sink.out, [l:out]) | endif
  if !empty(l:said) | call call(a:sink.err, [l:said]) | endif
  call call(a:sink.done, [l:code])
  return 0
endfunction
