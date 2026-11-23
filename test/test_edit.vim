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
  g:WaitFor("execute('messages') =~ 'edit failed: boom'", 10000)
  assert_equal(1, tabpagenr('$'))
  assert_equal(['let a = 1', 'let x = 1', 'let b = 2'], getbufline(src, 1, '$'))
  assert_match('edit failed: boom', execute('messages'))
enddef

def g:Test_edit_discarded_if_buffer_changed_meanwhile()
  var src = Setup()
  edit.Start(2, 2, 'anything')
  setline(2, 'let x = 999')
  g:WaitFor("execute('messages') =~ 'buffer changed'", 10000)
  assert_equal(1, tabpagenr('$'))
  assert_match('buffer changed', execute('messages'))
enddef

def g:Test_edit_times_out_instead_of_hanging()
  var src = Setup()
  g:claude_edit_timeout = 1
  edit.Start(1, 1, 'HANG')
  g:WaitFor("execute('messages') =~ 'edit timed out after 1s'", 10000)
  unlet g:claude_edit_timeout
  assert_equal(1, tabpagenr('$'))
  # Not stuck: a new edit can start.
  edit.Start(2, 2, 'again')
  g:WaitFor('tabpagenr("$") == 2')
  ClaudeReject
enddef

def g:Test_edit_refuses_a_huge_selection()
  var src = Setup()
  setline(1, repeat(['line'], 600))
  g:claude_edit_max_lines = 500
  edit.Start(1, 600, 'rewrite everything')
  unlet g:claude_edit_max_lines
  assert_match('selection too large for an inline edit (600 lines, limit 500)', execute('messages'))
  assert_equal(1, tabpagenr('$'))
  assert_equal(0, len(filter(g:FakeLog(), (_, l) => l =~ '^PROMPT')))
enddef

def g:Test_a_cancelled_edit_cannot_finish_the_next_one()
  var src = Setup()
  edit.Start(1, 1, 'HANG')
  edit.Cancel()
  edit.Start(2, 2, 'real one')
  # The cancelled process dies and reports its exit; that must not touch the new request.
  g:WaitFor('tabpagenr("$") == 2')
  assert_equal(2, tabpagenr('$'))
  ClaudeReject
enddef
