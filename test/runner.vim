" Minimal test runner: sources a test file, runs every g:Test_* function,
" writes failures to $TEST_OUT and exits non-zero if any failed.
set nocompatible
let s:root = fnamemodify(expand('<sfile>:p:h'), ':h')
execute 'set rtp^=' .. fnameescape(s:root)
filetype plugin on
syntax on
runtime plugin/claude.vim
let g:claude_cmd = s:root .. '/test/fake_claude.sh'
let $FAKE_CLAUDE_LOG = tempname()

func g:WaitFor(expr, ...) abort
  let l:timeout = get(a:, 1, 3000)
  let l:start = reltime()
  while reltimefloat(reltime(l:start)) * 1000 < l:timeout
    if eval(a:expr)
      return 1
    endif
    sleep 10m
  endwhile
  call add(v:errors, 'timed out waiting for: ' .. a:expr)
  return 0
endfunc

func g:FakeLog() abort
  return filereadable($FAKE_CLAUDE_LOG) ? readfile($FAKE_CLAUDE_LOG) : []
endfunc

let s:file = argv(0)
let s:out = []
let s:failed = 0
execute 'source ' .. fnameescape(s:file)
for s:name in sort(getcompletion('Test_', 'function'))
  let s:name = substitute(s:name, '($', '', '')
  let s:name = substitute(s:name, '()$', '', '')
  let v:errors = []
  try
    call call(s:name, [])
  catch
    call add(v:errors, 'exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
  endtry
  if empty(v:errors)
    call add(s:out, 'PASS ' .. s:name)
  else
    let s:failed += 1
    call add(s:out, 'FAIL ' .. s:name)
    call extend(s:out, map(copy(v:errors), '"    " .. v:val'))
  endif
  silent! %bwipeout!
  silent! only!
  silent! tabonly!
endfor
call writefile(s:out, $TEST_OUT)
execute s:failed ? 'cquit!' : 'qall!'
