vim9script
import autoload 'claude.vim'

def Wins(): dict<any>
  var d = claude.Debug()
  var Here = (b: number): number => filter(win_findbuf(b), (_, w) => win_id2tabwin(w)[0] == tabpagenr())[0]
  var chat = Here(d.chat_buf)
  var input = Here(d.input_buf)
  return {chat: getwininfo(chat)[0], input: getwininfo(input)[0]}
enddef

def Fresh()
  claude.NewChat()
  claude.Close()
  g:claude_position = 'right'
enddef

def g:Test_position_from_name_modifiers_and_option()
  g:claude_position = 'right'
  assert_equal('right', claude.Position('', ''))
  assert_equal('left', claude.Position('left', ''))
  assert_equal('top', claude.Position('top', ''))
  assert_equal('bottom', claude.Position('horizontal', ''))
  assert_equal('right', claude.Position('vertical', ''))
  # An explicit name beats modifiers and the option.
  assert_equal('top', claude.Position('top', 'vertical botright'))
  # Modifiers beat the option: :vertical / :horizontal pick the direction,
  # :topleft and :botright the side; whatever is not said comes from the option.
  assert_equal('right', claude.Position('', 'vertical'))
  assert_equal('left', claude.Position('', 'vertical topleft'))
  assert_equal('left', claude.Position('', 'aboveleft vertical'))
  assert_equal('bottom', claude.Position('', 'horizontal'))
  assert_equal('top', claude.Position('', 'horizontal topleft'))
  assert_equal('bottom', claude.Position('', 'botright horizontal'))
  g:claude_position = 'top'
  assert_equal('top', claude.Position('', ''))
  assert_equal('left', claude.Position('', 'vertical'))
  assert_equal('bottom', claude.Position('', 'botright'))
  g:claude_position = 'nonsense'
  assert_equal('right', claude.Position('', ''))
  # An unknown name is refused.
  assert_equal('', claude.Position('sideways', ''))
  assert_match('unknown position sideways', execute('messages'))
  g:claude_position = 'right'
enddef

def g:Test_each_position_builds_the_right_layout()
  var cols = &columns
  var lines = &lines
  for [pos, check] in [['right', 'side'], ['left', 'side'], ['top', 'band'], ['bottom', 'band']]
    Fresh()
    claude.Open(true, pos)
    var w = Wins()
    assert_equal(pos, t:claude_position)
    # The input is always right under the transcript, as wide as it.
    assert_equal(w.chat.wincol, w.input.wincol, pos)
    assert_equal(w.chat.width, w.input.width, pos)
    assert_true(w.input.winrow > w.chat.winrow, pos)
    if check == 'side'
      assert_true(w.chat.width < cols - 10, pos)
      assert_equal(pos == 'left' ? 1 : w.chat.wincol, w.chat.wincol)
      assert_equal(pos == 'left', w.chat.wincol == 1, pos)
    else
      # A band spans the whole screen and keeps its height.
      assert_equal(cols, w.chat.width, pos)
      assert_equal(pos == 'top', w.chat.winrow == 1, pos)
      assert_true(w.chat.height + w.input.height >= 5, pos)
    endif
  endfor
  Fresh()
enddef

def g:Test_commands_take_a_position_and_modifiers()
  Fresh()
  g:claude_position = 'right'
  execute 'ClaudeOpen bottom'
  assert_equal('bottom', t:claude_position)
  claude.Close()
  execute 'horizontal topleft ClaudeToggle'
  assert_equal('top', t:claude_position)
  execute 'ClaudeToggle'
  assert_false(claude.IsOpen())
  execute 'vertical topleft ClaudeOpen'
  assert_equal('left', t:claude_position)
  claude.Close()
  execute 'ClaudeToggle vertical'
  assert_equal('right', t:claude_position)
  # Completion offers the names.
  assert_equal(['right', 'left', 'top', 'bottom', 'vertical', 'horizontal'], split(claude#CompletePositions(), "\n"))
  Fresh()
enddef

def g:Test_open_elsewhere_moves_an_open_panel_and_keeps_the_conversation()
  Fresh()
  claude.Open(true, 'right')
  claude.Send('keep me')
  g:WaitFor('!claude#Busy()')
  var chat_buf = claude.Debug().chat_buf
  var before = getbufline(chat_buf, 1, '$')
  setbufline(claude.Debug().input_buf, 1, 'half-typed draft')
  var chats = len(win_findbuf(chat_buf))
  execute 'ClaudeOpen bottom'
  assert_equal('bottom', t:claude_position)
  assert_equal(chat_buf, claude.Debug().chat_buf)
  assert_equal(before, getbufline(chat_buf, 1, '$'))
  assert_equal(['half-typed draft'], getbufline(claude.Debug().input_buf, 1, '$'))
  assert_equal(chats, len(win_findbuf(chat_buf)))
  assert_equal(3, winnr('$'))
  assert_equal(&columns, Wins().chat.width)
  # Opening it where it already is changes nothing; :ClaudeMove does the same job.
  var id = win_getid()
  execute 'ClaudeOpen bottom'
  execute 'ClaudeMove left'
  assert_equal('left', t:claude_position)
  assert_equal(1, Wins().chat.wincol)
  assert_equal(before, getbufline(chat_buf, 1, '$'))
  # Moving a closed panel just opens it there.
  claude.Close()
  execute 'ClaudeMove top'
  assert_true(claude.IsOpen())
  assert_equal('top', t:claude_position)
  Fresh()
enddef

def g:Test_each_tab_remembers_its_own_position()
  Fresh()
  claude.Open(true, 'right')
  tabnew
  claude.Open(true, 'bottom')
  assert_equal('bottom', t:claude_position)
  # Resizing the screen must not give a bottom panel a side panel's width.
  var h = Wins().chat.height
  doautocmd VimResized
  assert_equal(&columns, Wins().chat.width)
  tabprevious
  assert_equal('right', t:claude_position)
  doautocmd VimResized
  assert_true(Wins().chat.width < &columns - 10)
  tabnext
  tabclose!
  Fresh()
enddef

def g:Test_default_position_comes_from_the_option()
  Fresh()
  g:claude_position = 'left'
  claude.Open()
  assert_equal('left', t:claude_position)
  assert_equal(1, Wins().chat.wincol)
  claude.Close()
  g:claude_position = 'top'
  claude.Open()
  assert_equal('top', t:claude_position)
  # Sending with the panel closed opens it in the default place too.
  claude.Close()
  claude.Send('hello')
  assert_equal('top', t:claude_position)
  g:WaitFor('!claude#Busy()')
  Fresh()
enddef

def g:Test_back_to_code()
  silent! only!
  edit code.txt
  var code = win_getid()
  claude.Open(true, 'bottom', '')
  assert_notequal(code, win_getid())
  ClaudeBack
  assert_equal(code, win_getid())
  claude.Open(true, '', '')
  wincmd k
  ClaudeBack
  assert_equal(code, win_getid())
  Fresh()
  silent! only!
enddef

def g:Test_back_key_is_mapped_in_the_panel_by_default()
  claude.Open(true, 'bottom', '')
  assert_match('Back', maparg(';b', 'n'))
  Fresh()
enddef
