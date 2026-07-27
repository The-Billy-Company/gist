" gist_test.vim — headless assertions for the Vim plugin, in Vim and Neovim.
"
"   vim  -es      -u NONE -i NONE -S editor/vim/test/gist_test.vim
"   nvim --headless -u NONE -i NONE -S editor/vim/test/gist_test.vim
"
" A fresh corpus is written to a temp directory and every search runs against
" that, so the assertions are exact instead of "some matches were found". The
" gist index lives in the same temp directory ($GIST_DIR), so a test run never
" touches the tree's real one. Exits non-zero on the first failing assertion
" it can report, and skips cleanly when the binary isn't installed.

set nocompatible
set noswapfile
set shortmess+=F

let s:here = expand('<sfile>:p:h')
let s:plugin = fnamemodify(s:here, ':h')
execute 'set runtimepath^=' . fnameescape(s:plugin)

let s:passed = 0
let s:failed = []

function! s:say(msg) abort
  call writefile([a:msg], '/dev/stdout', 'a')
endfunction

function! s:ok(name, cond) abort
  if a:cond
    let s:passed += 1
  else
    call add(s:failed, a:name)
    call s:say('not ok - ' . a:name)
  endif
endfunction

function! s:eq(name, got, want) abort
  if a:got == a:want
    let s:passed += 1
  else
    call add(s:failed, a:name)
    call s:say(printf('not ok - %s: got %s, want %s', a:name,
          \ string(a:got), string(a:want)))
  endif
endfunction

function! s:done() abort
  call s:say(printf('%s: %d passed, %d failed', s:label(), s:passed, len(s:failed)))
  if empty(s:failed) | qall! | endif
  cquit 1
endfunction

function! s:label() abort
  return has('nvim') ? 'nvim' : 'vim'
endfunction

" Vim runs job callbacks while sleeping; Neovim has wait().
function! s:settle(...) abort
  let l:ms = a:0 ? a:1 : 10000
  if exists('*wait')
    call wait(l:ms, '!gist#running()')
    return
  endif
  let l:start = reltime()
  while gist#running() && reltimefloat(reltime(l:start)) * 1000 < l:ms
    sleep 10m
  endwhile
endfunction

function! s:search(cmd) abort
  execute a:cmd
  call s:settle()
endfunction

" ------------------------------------------------------------------- fixture

let s:tmp = tempname()
call mkdir(s:tmp . '/sub', 'p')
call writefile(['alpha needle line', 'nothing here'], s:tmp . '/alpha.txt')
call writefile(['beta NEEDLE upper'], s:tmp . '/beta.txt')
call writefile(['gamma needle deep', 'needle twice'], s:tmp . '/sub/gamma.txt')
let s:reg = 'sentinel register contents'
call setreg('"', s:reg)
let $GIST_DIR = s:tmp . '/.gist'
let $GIST_NO_AUTOSERVE = '1'
execute 'lcd' fnameescape(s:tmp)

" ------------------------------------------------------------------- loading

runtime! plugin/gist.vim
call s:ok('plugin loads', get(g:, 'loaded_gist', 0) == 1)
for s:cmd in ['Gist', 'GistRank', 'GistFiles', 'LGist', 'GistRetry', 'GistStop',
      \ 'GistIndex', 'GistStatus', 'GistBlast', 'GistSimilar', 'GistHealth']
  call s:ok('command :' . s:cmd, exists(':' . s:cmd) == 2)
endfor
call s:ok('grepprg claims the default', &grepprg =~# '^gist ')
call s:ok('grepformat has no catch-all %f', &grepformat !~# ',%f$')
call s:ok('<Plug>(gist-cword) exists', !empty(maparg('<Plug>(gist-cword)', 'n')))
call s:ok('default mapping suggested', !empty(maparg('<Leader>gg', 'n'))
      \ || !empty(maparg('\gg', 'n')))
call s:eq('statusline idle', gist#statusline(), '')

" --------------------------------------------------------------- pure pieces

call s:eq('split: plain', gist#args#split('-t zig foo'), ['-t', 'zig', 'foo'])
call s:eq('split: single quotes', gist#args#split("-F 'a b|c'"), ['-F', 'a b|c'])
call s:eq('split: double quotes', gist#args#split('"a \"b\" c"'), ['a "b" c'])
call s:eq('split: backslash escape', gist#args#split('a\ b c'), ['a b', 'c'])
call s:eq('split: empty string arg', gist#args#split("-F '' x"), ['-F', '', 'x'])
call s:eq('split: nothing', gist#args#split('   '), [])
call s:eq('shape: default', gist#args#shape(['foo'], 'vimgrep'), 'vimgrep')
call s:eq('shape: -l', gist#args#shape(['-l', 'foo'], 'vimgrep'), 'files')
call s:eq('shape: --files-with-matches',
      \ gist#args#shape(['--files-with-matches'], 'vimgrep'), 'files')
call s:eq('shape: -c', gist#args#shape(['-c', 'foo'], 'vimgrep'), 'counts')
call s:eq('shape: -C is not -c', gist#args#shape(['-C', '2'], 'vimgrep'), 'vimgrep')
call s:eq('shape: mode wins when unsniffed',
      \ gist#args#shape(['foo'], 'rank'), 'rank')

let s:read = gist#hint#read([
      \ "gist: no matches for 'Widget' · scope: src",
      \ 'gist: try -i — the pattern has uppercase; retry case-insensitive',
      \ 'gist: try --engine auto — the pattern needs PCRE2',
      \ 'gist: try a wider scope — drop the PATH args'])
call s:eq('hints: two runnable tries', len(s:read.tries), 2)
call s:eq('hints: flags parsed', s:read.tries[0].flags, ['-i'])
call s:eq('hints: multi-word flags', s:read.tries[1].flags, ['--engine', 'auto'])
call s:eq('hints: prose stays prose', len(s:read.said), 2)
call s:ok('hints: no error flagged', !s:read.error)
call s:ok('hints: unknown flag is an error',
      \ gist#hint#read(['gist: unrecognized flag --nope']).error)

" With the prompt off (and whenever a pending keystroke stands the prompt
" down) the offers still have to say how to take them, or the coaching is a
" fact rather than a next step.
let s:was_prompt = get(g:, 'gist_hint_prompt', 1)
let g:gist_hint_prompt = 0
let s:printed = execute("call gist#hint#report("
      \ . "{'hints': s:read, 'found': 0, 'subject': \"'Widget'\"}, 1)")
let g:gist_hint_prompt = s:was_prompt
call s:ok('hints: the printed miss names the command that retries it',
      \ s:printed =~# ':GistRetry 1 → -i' && s:printed =~# ':GistRetry 2 → --engine auto')

if empty(gist#binary())
  call s:say('gist binary not on $PATH — skipping the live half')
  call s:done()
endif

" ------------------------------------------------------------------ searching

let g:gist_hint_prompt = 0
let g:gist_open_quickfix = 0

call s:search('Gist! -F needle')
let s:hits = getqflist()
call s:eq('search: three matches', len(s:hits), 3)
call s:ok('search: filename resolved', bufname(s:hits[0].bufnr) =~# 'alpha.txt$')
call s:eq('search: line number', s:hits[0].lnum, 1)
call s:ok('search: column carried', s:hits[0].col > 0)
call s:eq('search: text is the line', s:hits[0].text, 'alpha needle line')
call s:ok('search: title names the query', getqflist({'title': 0}).title =~# 'needle (3)$')
call s:eq('search: exit code', gist#last().code, 0)
call s:eq('search: reported count', gist#last().found, 3)
call s:ok('search: no hints on a hit', empty(gist#last().hints.tries))
call s:ok('search: --uncap sent', index(gist#last().argv, '--uncap') >= 0)
call s:ok('search: --vimgrep sent', index(gist#last().argv, '--vimgrep') >= 0)

call s:search('Gist! -i -F needle')
call s:eq('case-insensitive picks up NEEDLE', len(getqflist()), 4)

call s:search('GistRank! -F needle')
let s:ranked = getqflist()
call s:ok('rank: entries parsed', len(s:ranked) > 0)
call s:ok('rank: line number kept', s:ranked[0].lnum > 0)
call s:ok('rank: badge kept in text', s:ranked[0].text =~# '^\[\%(def\|use\)\]')
call s:ok('rank: --rank sent', index(gist#last().argv, '--rank') >= 0)
call s:ok('rank: --vimgrep not sent', index(gist#last().argv, '--vimgrep') < 0)

call s:search('GistFiles! -F needle')
let s:files = getqflist()
call s:eq('files: two files', len(s:files), 2)
call s:eq('files: no line noise', s:files[0].text, '')
call s:ok('files: -l sent', index(gist#last().argv, '-l') >= 0)

call s:search('Gist! -c -F needle')
call s:ok('counts: parsed as N matches', getqflist()[0].text =~# '^\d\+ match')

" A '|' would end a Vim command and confuse a shell; here it reaches the
" regex engine exactly as typed.
call s:search('Gist! ''needle|nothing''')
call s:eq('alternation survives unescaped', len(getqflist()), 4)

" ---------------------------------------------------------------- misses

call setqflist([])
call s:search('Gist! -F ZZQQabsent')
call s:eq('miss: nothing in the list', len(getqflist()), 0)
call s:eq('miss: exit code 1', gist#last().code, 1)
call s:ok('miss: gist explained itself', !empty(gist#last().hints.said))

call s:search('Gist! -F NEEDLE')
call s:eq('miss: uppercase misses lowercase corpus', len(getqflist()), 1)

" A miss that suggests -i, then :GistRetry applying it.
call s:search('Gist! -F Needle')
let s:tries = gist#last().hints.tries
call s:ok('retry: a suggestion was offered', !empty(s:tries))
if !empty(s:tries)
  call s:ok('retry: it is a flag', s:tries[0].flags[0] =~# '^-')
  call gist#retry(1)
  call s:settle()
  call s:ok('retry: rerun applied the flag',
        \ index(gist#last().argv, s:tries[0].flags[0]) >= 0)
  call s:ok('retry: and it found something', len(getqflist()) > 0)
endif
call s:ok('retry: out-of-range is refused', gist#retry(99) != 1)

" ------------------------------------------------------------------ location

call setqflist([])
call s:search('LGist! -F needle')
call s:eq('loclist: filled', len(getloclist(0)), 3)
call s:eq('loclist: quickfix untouched', len(getqflist()), 0)

" ------------------------------------------------------------- word under cursor

call setqflist([])
execute 'edit' fnameescape(s:tmp . '/alpha.txt')
call cursor(1, 7)
call gist#cword('vimgrep', 1)
call s:settle()
call s:eq('cword: searched the word', len(getqflist()), 3)
call s:ok('cword: as a literal word',
      \ index(gist#last().argv, '--word-regexp') >= 0)

" ------------------------------------------------------------------ selection
" Driven through the <Plug> mapping rather than the function it calls: the
" ':<C-u>' that leaves visual mode is what sets the marks the yank reads, so
" calling gist#visual() directly would test a path no keystroke takes.

function! s:select(keys) abort
  call setqflist([])
  execute 'edit!' fnameescape(s:tmp . '/alpha.txt')
  call cursor(1, 1)
  call feedkeys(a:keys . "\<Plug>(gist-selection)", 'x')
  call s:settle()
endfunction

call s:select('6lve')
call s:eq('visual: the selection, literally', len(getqflist()), 3)
call s:eq('visual: exactly what was highlighted', gist#last().argv[-1], 'needle')
call s:ok('visual: one line stays one line',
      \ index(gist#last().argv, '--multiline') < 0)

" Both lines of alpha.txt, verbatim: only a search that reads across the line
" break can match them, so this is the -U path end to end.
call s:select('VG')
call s:eq('visual: spanning lines searched as one string', len(getqflist()), 1)
call s:ok('visual: --multiline sent',
      \ index(gist#last().argv, '--multiline') >= 0)
call s:eq('visual: no trailing newline in the pattern',
      \ gist#last().argv[-1], "alpha needle line\nnothing here")
call s:eq('visual: register unharmed', getreg('"'), s:reg)

" The operator: <Leader>go plus a motion, here 'ip' for the whole paragraph.
call setqflist([])
execute 'edit!' fnameescape(s:tmp . '/alpha.txt')
call cursor(1, 1)
call feedkeys("\<Plug>(gist-operator)ip", 'x')
call s:settle()
call s:eq('operator: the motion is the pattern', len(getqflist()), 1)
call s:ok('operator: crossed the line break',
      \ index(gist#last().argv, '--multiline') >= 0)
call s:eq('operator: register unharmed', getreg('"'), s:reg)

" --------------------------------------------------------------- options obeyed

let g:gist_flags = ['-i']
call s:search('Gist! -F needle')
call s:eq('g:gist_flags applied', len(getqflist()), 4)
let g:gist_flags = []

let b:gist_flags = ['-i']
call s:search('Gist! -F needle')
call s:eq('b:gist_flags beats the global', len(getqflist()), 4)
unlet b:gist_flags

let g:gist_uncap = 0
call s:search('Gist! -F needle')
call s:ok('g:gist_uncap off drops the flag', index(gist#last().argv, '--uncap') < 0)
let g:gist_uncap = 1

" 'grepprg' politeness needs a fresh editor: an explicit choice must survive.
let s:cmd = printf('%s %s -u NONE -i NONE --cmd %s --cmd %s --cmd %s',
      \ shellescape(v:progpath), has('nvim') ? '--headless' : '-es',
      \ shellescape('let g:gist_grepprg = "never"'),
      \ shellescape('set runtimepath^=' . s:plugin),
      \ shellescape('runtime! plugin/gist.vim'))
let s:probe = system(s:cmd . ' --cmd ' . shellescape('call writefile([&grepprg],'
      \ . ' "/dev/stdout")') . ' --cmd quit')
call s:ok('g:gist_grepprg = never leaves grepprg alone', s:probe !~# 'gist')

" ------------------------------------------------------------------- siblings

if executable('relate')
  call setqflist([])
  execute 'edit' fnameescape(s:tmp . '/alpha.txt')
  GistSimilar
  call s:settle()
  call s:ok('similar: answered without error', v:errmsg ==# '')
endif

if executable('irregex')
  call setqflist([])
  GistBlast needle
  call s:settle()
  call s:ok('blast: answered without error', v:errmsg ==# '')
endif

" --------------------------------------------------------------------- health

let s:health = gist#health#report()
call s:ok('health: reports rows', len(s:health) >= 4)
call s:eq('health: binary row is ok', s:health[0].level, 'ok')
" run_sync reads stdout only, so a semver here is also the proof that
" `gist --version` answers on stdout the way ripgrep's does.
call s:ok('health: the version came back', s:health[0].msg =~# '\v \d+\.\d+\.\d+$')
call s:ok('health: index row knows the corpus',
      \ s:health[1].msg =~# '\v^index: \w+, \d+ files'
      \ || s:health[1].msg =~# 'no trigram index')
call s:ok('health: every row is leveled',
      \ empty(filter(copy(s:health), 'index(["ok","warn","error","info"], v:val.level) < 0')))

call s:done()
