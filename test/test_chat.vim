vim9script
import autoload 'claude.vim'

def ChatLines(): list<string>
  return getbufline(claude.Debug().chat_buf, 1, '$')
enddef

def Reset()
  claude.NewChat()
  writefile([], $FAKE_CLAUDE_LOG)
enddef

def g:Test_open_creates_panel_and_toggle_closes_it()
  Reset()
  claude.Open()
  assert_equal(3, winnr('$'))
  assert_equal('claudeinput', &filetype)
  assert_true(claude.IsOpen())
  var chat = claude.Debug().chat_buf
  assert_equal('claudechat', getbufvar(chat, '&filetype'))
  assert_false(getbufvar(chat, '&modifiable'))
  claude.Toggle()
  assert_equal(1, winnr('$'))
  claude.Toggle()
  assert_equal(3, winnr('$'))
enddef

def g:Test_send_streams_reply_tools_and_footer()
  Reset()
  claude.Send('hi there')
  g:WaitFor('!claude#Busy()')
  var lines = ChatLines()
  assert_equal('▌ You', lines[0])
  assert_equal('hi there', lines[1])
  assert_equal('▌ Claude', lines[3])
  assert_equal('Hello **world**', lines[4])
  assert_equal('second line', lines[5])
  assert_notequal(-1, index(lines, '  ● Read src/main.c'))
  assert_notequal(-1, index(lines, '    ⎿ File does not exist.'))
  assert_notequal(-1, index(lines, 'Done.'))
  assert_equal(-1, match(lines, 'SUBAGENT'))
  assert_equal(1, count(lines, '▌ Claude'))
  assert_match('^  ── \d\+\.\ds$', lines[-1])
  assert_false(claude.Debug().busy)
  assert_equal('11111111-2222-3333-4444-555555555555', claude.Debug().session_id)
enddef

def g:Test_sent_payload_is_stream_json_with_context()
  Reset()
  g:claude_last_ctx = {file: getcwd() .. '/README.md', line: 4, total: 10}
  claude.Send('question')
  g:WaitFor("match(g:FakeLog(), '^STDIN') >= 0")
  var stdin = filter(g:FakeLog(), (_, l) => l =~ '^STDIN ')[0][6 :]
  var msg = json_decode(stdin)
  assert_equal('user', msg.type)
  assert_match('^question\n\n<editor-context>The user is looking at README.md (cursor on line 4 of 10)', msg.message.content)
  unlet g:claude_last_ctx
enddef

def g:Test_second_message_reuses_process_and_new_chat_resets()
  Reset()
  claude.Send('one')
  g:WaitFor("!claude#Busy()")
  claude.Send('two')
  g:WaitFor("count(map(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), 'v:val'), '▌ Claude') == 2 && !claude#Busy()")
  assert_equal(1, len(filter(g:FakeLog(), (_, l) => l =~ '^ARGS ')))
  claude.NewChat()
  assert_equal([''], ChatLines())
  assert_equal('', claude.Debug().session_id)
enddef

def g:Test_restart_after_new_chat_resumes_session()
  Reset()
  claude.Send('one')
  g:WaitFor('!claude#Busy()')
  claude.SetModel('haiku')   # forces a restart on the next message
  claude.Send('two')
  g:WaitFor('!claude#Busy()')
  var args = filter(g:FakeLog(), (_, l) => l =~ '^ARGS ')
  assert_equal(2, len(args))
  assert_match('--resume 11111111-2222-3333-4444-555555555555', args[1])
  assert_match('--model haiku', args[1])
  claude.SetModel('default')
enddef

def g:Test_stop_interrupts_a_running_turn()
  Reset()
  claude.Send('SLOW please')
  g:WaitFor("index(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), 'Working') >= 0")
  assert_true(claude.Debug().busy)
  claude.Stop()
  assert_false(claude.Debug().busy)
  assert_equal('  ■ Interrupted', ChatLines()[-1])
enddef

def g:Test_permission_denial_prompts_and_allow_retries()
  Reset()
  claude.Send('PERM edit it')
  g:WaitFor('!empty(popup_list())')
  assert_match('Needs permission: Bash npm test, Edit a.txt', join(ChatLines(), "\n"))
  popup_close(popup_list()[0], 1)  # "Allow for this session"
  assert_equal(['Bash(npm test)', 'Edit'], claude.Debug().allowed)
  g:WaitFor('len(filter(g:FakeLog(), "v:val =~ ''^ARGS ''")) == 2')
  var args = filter(g:FakeLog(), (_, l) => l =~ '^ARGS ')
  assert_match('--allowedTools Bash(npm test) Edit', args[1])
  g:WaitFor("match(g:FakeLog(), 'Permission granted') >= 0")
  g:WaitFor('!claude#Busy()')
  claude.Send('PERM again')
  g:WaitFor('!empty(popup_list())')
  popup_close(popup_list()[0], 3)  # Deny the second time
  assert_equal('  ✗ Denied', ChatLines()[-1])
enddef

def g:Test_scrolled_back_window_is_not_dragged_to_bottom()
  Reset()
  claude.Open()
  claude.Send('one')
  g:WaitFor('!claude#Busy()')
  var w = win_findbuf(claude.Debug().chat_buf)[0]
  claude.Send('DRIP')
  g:WaitFor("index(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), 'first') >= 0")
  win_execute(w, 'normal! gg')   # user scrolls back while Claude is still writing
  g:WaitFor('!claude#Busy()')
  assert_equal(1, line('.', w))
  assert_notequal(-1, index(ChatLines(), 'more 5'))
  # A window left at the bottom follows the stream.
  win_execute(w, 'normal! G')
  claude.Send('three')
  g:WaitFor('!claude#Busy()')
  assert_equal(line('$', w), line('.', w))
enddef

def g:Test_explain_selection_and_add_to_input()
  Reset()
  new
  setline(1, ['int a;', 'int b;', 'int c;'])
  setlocal filetype=c
  execute 'silent file ' .. tempname() .. '.c'
  :2,3ClaudeExplain
  g:WaitFor('!claude#Busy()')
  var text = join(ChatLines(), "\n")
  assert_match('Explain this code from `.*\.c` (lines 2-3):\n\n```c\nint b;\nint c;\n```', text)

  wincmd p
  wincmd t
  var src = bufnr()
  :1,2ClaudeAdd
  var input = claude.Debug().input_buf
  assert_match('^@.*\.c#L1-2 $', getbufline(input, 1)[0])
enddef

def g:Test_submit_from_input_and_history()
  Reset()
  claude.Open()
  setline(1, ['multi', 'line'])
  feedkeys("\<CR>", 'xt')
  g:WaitFor('!claude#Busy()')
  assert_equal([''], getbufline(claude.Debug().input_buf, 1, '$'))
  assert_equal(['▌ You', 'multi', 'line'], ChatLines()[0 : 2])
  feedkeys("\<C-p>", 'xt')
  assert_equal(['multi', 'line'], getbufline(claude.Debug().input_buf, 1, '$'))
enddef

def g:Test_missing_cli_warns_without_crashing()
  Reset()
  var saved = g:claude_cmd
  g:claude_cmd = '/nonexistent/claude'
  claude.Send('hello')
  assert_false(claude.Debug().busy)
  assert_equal('  ✖ Not sent', ChatLines()[-1])
  g:claude_cmd = saved
enddef

def g:Test_yank_code_block()
  Reset()
  claude.Send('hi')
  g:WaitFor('!claude#Busy()')
  claude.Open()
  wincmd k
  setbufvar(bufnr(), '&modifiable', 1)
  append('$', ['```vim', 'echo 1', 'echo 2', '```'])
  setbufvar(bufnr(), '&modifiable', 0)
  normal! Gk
  feedkeys('gy', 'xt')
  assert_equal("echo 1\necho 2\n", @")
enddef
