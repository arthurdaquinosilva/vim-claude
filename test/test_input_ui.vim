vim9script
import autoload 'claude.vim'

def Placeholder(buf: number): string
  var p = filter(prop_list(1, {bufnr: buf}), (_, x) => get(x, 'type', '') == 'claude_placeholder')
  return empty(p) ? '' : p[0].text
enddef

def Plain(s: string): string
  return substitute(s, '%#[^#]*#', '', 'g')->substitute('%%', '%', 'g')
enddef

def g:Test_prompt_sign_and_placeholder()
  claude.NewChat()
  claude.Open()
  var buf = claude.Debug().input_buf
  var signs = sign_getplaced(buf, {group: 'claude_input'})[0].signs
  assert_equal([[1, 'ClaudePrompt']], mapnew(signs, (_, s) => [s.lnum, s.name]))
  assert_match('Ask Claude', Placeholder(buf))
  assert_equal('ClaudeInput', &wincolor)

  setline(1, ['hello', 'world'])
  doautocmd TextChanged
  assert_equal('', Placeholder(buf))
  signs = sign_getplaced(buf, {group: 'claude_input'})[0].signs
  assert_equal([[1, 'ClaudePrompt'], [2, 'ClaudeCont']], mapnew(signs, (_, s) => [s.lnum, s.name]))
enddef

def g:Test_input_grows_with_content_and_is_capped()
  claude.NewChat()
  claude.Open()
  deletebufline('%', 1, '$')
  doautocmd TextChanged
  assert_equal(3, winheight(0))
  setline(1, map(range(6), (_, i) => 'line ' .. i))
  doautocmd TextChanged
  assert_equal(6, winheight(0))
  setline(1, map(range(40), (_, i) => 'line ' .. i))
  doautocmd TextChanged
  assert_equal(12, winheight(0))
  deletebufline('%', 1, '$')
  doautocmd TextChanged
  assert_equal(3, winheight(0))
enddef

def g:Test_busy_placeholder_and_bars()
  claude.NewChat()
  claude.Open()
  var buf = claude.Debug().input_buf
  var input_win = win_getid()
  claude.Send('SLOW')
  g:WaitFor('claude#Busy()')
  assert_match('working', Placeholder(buf))

  g:statusline_winid = input_win
  var bar = Plain(claude.InputStatusLine())
  assert_equal(winwidth(input_win), strdisplaywidth(bar))
  assert_match('ctrl-c stop', bar)

  var chat_win = win_findbuf(claude.Debug().chat_buf)[0]
  g:statusline_winid = chat_win
  bar = Plain(claude.StatusLine())
  assert_equal(winwidth(chat_win), strdisplaywidth(bar))
  assert_match('^── ✻ Claude [⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] ', bar)
  assert_match('ask before edits ──$', bar)

  claude.Stop()
  assert_match('Ask Claude', Placeholder(buf))
  g:statusline_winid = input_win
  assert_match('enter send', Plain(claude.InputStatusLine()))
enddef
