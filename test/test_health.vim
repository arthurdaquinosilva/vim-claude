vim9script
import autoload 'claude.vim'

def g:Test_health_reports_the_environment()
  var out = execute('ClaudeHealth')
  assert_match('+job', out)
  assert_match('getregion()', out)
  assert_match('process', out)
  assert_notmatch('FAIL', out)
enddef

def g:Test_health_flags_a_missing_cli()
  g:claude_cmd = 'definitely-not-claude'
  var out = execute('ClaudeHealth')
  unlet g:claude_cmd
  assert_match('definitely-not-claude: not on \$PATH', out)
enddef

def g:Test_debug_log_records_raw_events()
  var log = tempname()
  g:claude_debug_log = log
  claude.NewChat()
  claude.Send('log me')
  g:WaitFor('!claude#Busy()')
  unlet g:claude_debug_log
  var lines = readfile(log)
  assert_true(len(lines) > 0)
  assert_match(' out {', lines[0])
  delete(log)
enddef
