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
  assert_equal(['❯ You:', '', '  hi there', '', '✻ Claude:', '', '  Hello **world**', '  second line'],
    lines[0 : 7])
  assert_notequal(-1, index(lines, '  ● Read src/main.c'))
  assert_notequal(-1, index(lines, '    ⎿ File does not exist.'))
  assert_notequal(-1, index(lines, '  Done.'))
  assert_equal(-1, match(lines, 'SUBAGENT'))
  assert_equal(1, count(lines, '✻ Claude:'))
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
  g:WaitFor("count(map(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), 'v:val'), '✻ Claude:') == 2 && !claude#Busy()")
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
  g:WaitFor("index(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), '  Working') >= 0")
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
  g:WaitFor("index(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), '  first') >= 0")
  win_execute(w, 'normal! gg')   # user scrolls back while Claude is still writing
  g:WaitFor('!claude#Busy()')
  assert_equal(1, line('.', w))
  assert_notequal(-1, index(ChatLines(), '  more 5'))
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
  assert_match('  Explain this code from `.*\.c` (lines 2-3):\n\n  ```c\n  int b;\n  int c;\n  ```', text)

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
  assert_equal(['❯ You:', '', '  multi', '  line'], ChatLines()[0 : 3])
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
  append('$', ['  ```vim', '  echo 1', '    nested', '  ```'])
  setbufvar(bufnr(), '&modifiable', 0)
  normal! Gk
  feedkeys('gy', 'xt')
  # The transcript's 2-space body indent is removed, nested indent kept.
  assert_equal("echo 1\n  nested\n", @")
enddef

def g:Test_markdown_tables_are_formatted()
  Reset()
  claude.Send('TABLE please')
  g:WaitFor('!claude#Busy()')
  var lines = ChatLines()
  var at = index(lines, '  Intro')
  assert_equal([
    '  Intro',
    '  ┌────────┬──────────┐',
    '  │ Action │ Effect   │',
    '  ├────────┼──────────┤',
    '  │ add    │ Adds one │',
    '  └────────┴──────────┘',
  ], lines[at : at + 5])
  assert_equal('', lines[at + 6])
  assert_equal('  After', lines[at + 7])
  # A table that ends the reply is formatted when the block closes.
  assert_equal('  ┌───┬───┐', lines[at + 9])
  assert_equal('  │ a │ 1 │', lines[at + 12])
  assert_equal(-1, match(lines, '^\s*|'))
enddef

def g:Test_table_rows_are_not_concealed()
  # Markdown syntaxes that conceal `code` delimiters must not shift borders.
  Reset()
  claude.Send('TABLE please')
  g:WaitFor('!claude#Busy()')
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  syntax region markdownCode matchgroup=markdownCodeDelimiter start="`" end="`" concealends
  var lnum = index(ChatLines(), '  │ add    │ Adds one │') + 1
  assert_true(lnum > 0)
  var concealed = 0
  for col in range(1, strlen(getline(lnum)))
    concealed += synconcealed(lnum, col)[0]
  endfor
  assert_equal(0, concealed)
  assert_equal(['claudeMsgClaude', 'claudeTableRow'], synstack(lnum, 6)->map((_, id) => synIDattr(id, 'name')))
  # Inline code keeps its color through a text property instead.
  var p = prop_list(lnum)
  assert_equal(1, len(p))
  assert_equal(['claude_code', 'add'], [p[0].type, strpart(getline(lnum), p[0].col - 1, p[0].length)])
enddef

def g:Test_table_code_highlight_has_a_color()
  highlight clear markdownCode
  highlight clear mkdCode
  claude.LinkCodeHighlight()
  assert_equal('String', hlget('claudeTableCode')[0].linksto)
  highlight claudeTableCode ctermfg=1
  claude.LinkCodeHighlight()
  assert_equal('claudeTableCode', synIDattr(synIDtrans(hlID('claudeTableCode')), 'name'))
enddef

def g:Test_headers_show_time_and_live_indicator()
  Reset()
  claude.Send('SLOW please')
  g:WaitFor("index(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), '  Working') >= 0")
  var buf = claude.Debug().chat_buf
  var you = index(ChatLines(), '❯ You:') + 1
  var hdr = index(ChatLines(), '✻ Claude:') + 1
  var Props = (lnum: number, type: string): list<dict<any>> =>
    filter(prop_list(lnum, {bufnr: buf}), (_, p) => p.type == type)
  assert_match('^\d\d:\d\d$', Props(you, 'claude_time')[0].text)
  assert_match('^\d\d:\d\d$', Props(hdr, 'claude_time')[0].text)
  assert_match('^  [⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] writing…$', Props(hdr, 'claude_live')[0].text)
  # Your message is dimmed.
  assert_equal(1, len(Props(you + 2, 'claude_user')))
  assert_equal(3, Props(you + 2, 'claude_user')[0].col)
  claude.Stop()
  assert_equal([], Props(hdr, 'claude_live'))
enddef

def g:Test_claude_header_appears_before_first_token()
  Reset()
  claude.Send('SLOW please')
  # Right after sending, before any output: header with "thinking…".
  var lines = ChatLines()
  assert_equal(['✻ Claude:', ''], lines[-2 :])
  var live = filter(prop_list(len(lines) - 1, {bufnr: claude.Debug().chat_buf}), (_, p) => p.type == 'claude_live')
  assert_match('thinking…$', live[0].text)
  claude.Stop()
enddef

def g:Test_code_fences_get_language_syntax()
  Reset()
  claude.Open()
  claude.Send('CODE please')
  g:WaitFor('!claude#Busy()')
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  var Names = (text: string, col: number): string =>
    join(synstack(index(ChatLines(), text) + 1, col)->map((_, id) => synIDattr(id, 'name')), ' ')
  assert_match('claudeFence\d\+ .*javaScript', Names('  function f() { return x; }', 3))
  assert_match('claudeFence\d\+ .*python', Names('  def g():', 3))
  # Unknown languages fall back to Markdown's plain code block.
  assert_notmatch('claudeFence', Names('  zzz', 3))
  # Survives a syntax reload.
  setlocal syntax=claudechat
  assert_match('javaScript', Names('  function f() { return x; }', 3))
enddef

def g:Test_unbalanced_backticks_do_not_spill_into_next_message()
  Reset()
  claude.Open()
  claude.Send("show a ```js fenced snippet, then a ```python one")
  g:WaitFor('!claude#Busy()')
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  var lnum = index(ChatLines(), '✻ Claude:') + 1
  assert_equal('claudeClaude', synIDattr(synID(lnum, 1, 1), 'name'))
  var done = index(ChatLines(), '  Done.') + 1
  assert_notmatch('Code', join(synstack(done, 3)->map((_, id) => synIDattr(id, 'name'))))
enddef
