vim9script
import autoload 'claude.vim'
import autoload 'claude/util.vim'

def StopAndWait()
  claude.Stop()
  g:WaitFor('!claude#Busy()')
enddef

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
  var Texts = (lnum: number, type: string): list<string> =>
    filter(prop_list(lnum, {bufnr: buf}), (_, p) => p.type == type)->map((_, p) => p.text)
  var Signs = (): list<list<any>> =>
    mapnew(sign_getplaced(buf, {group: 'claude_input'})[0].signs, (_, x) => [x.lnum, x.name])
  assert_equal([[1, 'ClaudePrompt']], Signs())
  assert_equal('yes', &l:signcolumn)
  assert_equal('Ask Claude…', Placeholder(buf))
  assert_equal([repeat('─', winwidth(0) - 2)], Texts(1, 'claude_border'))

  setline(1, ['hello', 'world'])
  doautocmd TextChanged
  assert_equal('', Placeholder(buf))
  assert_equal([[1, 'ClaudePrompt']], Signs())
  # The border moves under the last line.
  assert_equal([], Texts(1, 'claude_border'))
  assert_equal(1, len(Texts(2, 'claude_border')))
enddef

def g:Test_input_grows_with_content_and_is_capped()
  claude.NewChat()
  claude.Open()
  deletebufline('%', 1, '$')
  doautocmd TextChanged
  assert_equal(2, winheight(0))   # one line plus the bottom border
  setline(1, map(range(6), (_, i) => 'line ' .. i))
  doautocmd TextChanged
  assert_equal(7, winheight(0))
  setline(1, map(range(40), (_, i) => 'line ' .. i))
  doautocmd TextChanged
  assert_equal(12, winheight(0))
  deletebufline('%', 1, '$')
  doautocmd TextChanged
  assert_equal(2, winheight(0))
enddef

def g:Test_busy_placeholder_and_bars()
  claude.NewChat()
  claude.Open()
  var buf = claude.Debug().input_buf
  var input_win = win_getid()
  var chat_win = win_findbuf(claude.Debug().chat_buf)[0]
  var rule = '  ' .. repeat('─', winwidth(chat_win) - 2)
  # Idle: a plain rule above, a quiet info line below.
  assert_equal(rule, Plain(claude.StatusLine(chat_win)))
  var bar = Plain(claude.InputStatusLine(input_win))
  assert_equal(winwidth(input_win), strwidth(bar))
  assert_match('ask before edits $', bar)
  assert_notmatch('─', bar)

  claude.Send('SLOW')
  g:WaitFor('claude#Busy()')
  assert_match('working', Placeholder(buf))
  bar = Plain(claude.InputStatusLine(input_win))
  assert_equal(winwidth(input_win), strwidth(bar))
  # The test window is too narrow for the hint and the status together: the
  # status (activity next to the mode) stays whole and the hint makes way.
  assert_notmatch('ctrl-c', bar)
  assert_notmatch('…$', bar)
  assert_match('[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] thinking… · ask before edits $', bar)
  var wide = Plain(util.Bar([['ctrl-c', ''], [' to stop', '']],
    [['⠋ writing…', ''], [' · ', ''], ['ask before edits', '']], 80, 'R', true))
  assert_match('^  ctrl-c to stop \+⠋ writing… · ask before edits $', wide)
  assert_equal(rule, Plain(claude.StatusLine(chat_win)))

  StopAndWait()
  assert_equal('Ask Claude…', Placeholder(buf))
  assert_notmatch('ctrl-c\|…', Plain(claude.InputStatusLine(input_win)))
enddef

def g:Test_panel_windows_have_no_colorcolumn()
  set colorcolumn=60,80
  claude.Open()
  assert_equal('', getwinvar(win_findbuf(claude.Debug().chat_buf)[0], '&colorcolumn'))
  assert_equal('', &l:colorcolumn)
  set colorcolumn&
enddef

def g:Test_quitting_chat_window_keeps_editor_height()
  claude.NewChat()
  silent! only!
  var full = winheight(0)
  var editor = win_getid()
  claude.Open()
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  quit
  doautocmd WinResized
  g:WaitFor('winnr("$") == 1')
  assert_equal(editor, win_getid())
  assert_equal(full, winheight(0))
enddef

def g:Test_panel_takes_half_the_screen_and_follows_resize()
  claude.NewChat()
  silent! only!
  claude.Open()
  var chat = win_findbuf(claude.Debug().chat_buf)[0]
  assert_true(abs(winwidth(chat) - &columns / 2) <= 1, 'width ' .. winwidth(chat))
  claude.Close()
  g:claude_width = 0.3
  claude.Open()
  chat = win_findbuf(claude.Debug().chat_buf)[0]
  assert_true(abs(winwidth(chat) - float2nr(&columns * 0.3)) <= 1, 'width ' .. winwidth(chat))
  unlet g:claude_width
  doautocmd VimResized
  assert_true(abs(winwidth(chat) - &columns / 2) <= 1, 'width ' .. winwidth(chat))
enddef

def g:Test_input_does_not_hard_wrap_with_global_textwidth()
  set textwidth=20
  claude.NewChat()
  claude.Open()
  assert_equal(0, &l:textwidth)
  feedkeys("a" .. repeat('word ', 10) .. "\<Esc>", 'xt')
  assert_equal(1, line('$'))
  set textwidth&
enddef

# Typing a newline used to leave the window scrolled to the new line, hiding
# the lines above it until the next keystroke. (Vim wants one row to spare
# while the last of several lines is empty, because of the border under it.)
# The scrolling itself needs a real terminal; here we check the sizing.
def g:Test_input_keeps_a_spare_row_while_the_last_line_is_empty()
  claude.NewChat()
  claude.Open()
  var buf = claude.Debug().input_buf
  var win = win_findbuf(buf)[0]
  win_gotoid(win)
  # One line, empty or not: the line and the border, nothing spare.
  setline(1, 'first line')
  doautocmd TextChanged
  assert_equal(2, winheight(win))
  # A fresh newline: two lines and the border, plus the spare row.
  append(1, '')
  normal! 2G
  doautocmd TextChangedI
  assert_equal(4, winheight(win))
  # Typing on it takes the spare row away again.
  setline(2, 'x')
  doautocmd TextChangedI
  assert_equal(3, winheight(win))
  # The same for a third line.
  append(2, '')
  normal! 3G
  doautocmd TextChangedI
  assert_equal(5, winheight(win))
  setline(3, 'y')
  doautocmd TextChangedI
  assert_equal(4, winheight(win))
  # Without the border there is nothing to make room for.
  g:claude_input_border = false
  append(3, '')
  doautocmd TextChangedI
  assert_equal(4, winheight(win))
  unlet g:claude_input_border
enddef

def g:Test_new_line_keys_make_room_before_inserting()
  claude.NewChat()
  claude.Open()
  var buf = claude.Debug().input_buf
  var win = win_findbuf(buf)[0]
  win_gotoid(win)
  setline(1, 'first line')
  doautocmd TextChanged
  assert_equal(2, winheight(win))
  # <C-j> and <S-CR> are mapped to grow the window and then break the line.
  assert_match('MakeRoomForNewline', maparg('<C-j>', 'i'))
  assert_match('MakeRoomForNewline', maparg('<S-CR>', 'i'))
  assert_match('MakeRoomForNewline', maparg('o', 'n'))
  assert_match('MakeRoomForNewline', maparg('O', 'n'))
  # Enter still sends rather than breaking the line.
  assert_match('SubmitInput', maparg('<CR>', 'i'))
enddef
