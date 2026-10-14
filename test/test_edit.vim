vim9script
import autoload 'claude/edit.vim'

def Setup(): number
  writefile([], $FAKE_CLAUDE_LOG)
  enew!
  setline(1, ['let a = 1', 'let x = 1', 'let b = 2'])
  setlocal filetype=vim
  return bufnr()
enddef

def g:Test_edit_opens_diff_and_accept_applies()
  var src = Setup()
  edit.Start(2, 2, 'make it the answer')
  g:WaitFor('tabpagenr("$") == 2')
  assert_equal(2, winnr('$'))
  assert_true(&diff)
  assert_equal(['let a = 1', 'let x = 42', 'let y = 43', 'let b = 2'], getline(1, '$'))
  var log = join(g:FakeLog(), "\n")
  assert_match('--output-format json --tools  --no-session-persistence', log)
  assert_match('Instruction: make it the answer', log)
  # Source buffer is untouched until accepted.
  assert_equal(['let a = 1', 'let x = 1', 'let b = 2'], getbufline(src, 1, '$'))
  feedkeys('ga', 'xt')
  assert_equal(1, tabpagenr('$'))
  assert_equal(['let a = 1', 'let x = 42', 'let y = 43', 'let b = 2'], getbufline(src, 1, '$'))
  assert_false(getwinvar(1, '&diff'))
enddef

def g:Test_edit_reject_leaves_buffer()
  var src = Setup()
  edit.Start(2, 2, 'anything')
  g:WaitFor('tabpagenr("$") == 2')
  ClaudeReject
  assert_equal(1, tabpagenr('$'))
  assert_equal(['let a = 1', 'let x = 1', 'let b = 2'], getbufline(src, 1, '$'))
enddef

def g:Test_edit_error_is_reported_not_applied()
  var src = Setup()
  edit.Start(1, 1, 'FAIL')
  sleep 1500m
  assert_equal(1, tabpagenr('$'))
  assert_equal(['let a = 1', 'let x = 1', 'let b = 2'], getbufline(src, 1, '$'))
  assert_match('edit failed: boom', execute('messages'))
enddef

def g:Test_edit_discarded_if_buffer_changed_meanwhile()
  var src = Setup()
  edit.Start(2, 2, 'anything')
  setline(2, 'let x = 999')
  sleep 1500m
  assert_equal(1, tabpagenr('$'))
  assert_match('buffer changed', execute('messages'))
enddef
