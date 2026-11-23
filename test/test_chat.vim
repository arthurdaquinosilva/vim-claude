vim9script
import autoload 'claude.vim'

def ChatLines(): list<string>
  return getbufline(claude.Debug().chat_buf, 1, '$')
enddef

def StopAndWait()
  claude.Stop()
  g:WaitFor('!claude#Busy()')
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

def g:Test_restart_resumes_the_session()
  Reset()
  claude.Send('one')
  g:WaitFor('!claude#Busy()')
  g:claude_extra_args = ['--verbose-fake']   # a launch argument changed: restart
  claude.Send('two')
  g:WaitFor('!claude#Busy()')
  unlet g:claude_extra_args
  var args = filter(g:FakeLog(), (_, l) => l =~ '^ARGS ')
  assert_equal(2, len(args))
  assert_match('--resume 11111111-2222-3333-4444-555555555555', args[1])
enddef

def Ctrl(): list<dict<any>>
  return mapnew(filter(g:FakeLog(), (_, l) => l =~ '^CTRL '), (_, l) => json_decode(l[5 :]).request)
enddef

def g:Test_model_and_mode_change_in_place_without_restart()
  Reset()
  claude.Send('one')
  g:WaitFor('!claude#Busy()')
  claude.SetModel('haiku')
  claude.SetMode('plan')
  claude.SetMode('acceptEdits')
  g:WaitFor('len(g:FakeLog()) > 0 && len(filter(g:FakeLog(), "v:val =~ ''^CTRL ''")) == 3')
  assert_equal([{subtype: 'set_model', model: 'haiku'}, {subtype: 'set_permission_mode', mode: 'plan'},
    {subtype: 'set_permission_mode', mode: 'acceptEdits'}], Ctrl())
  assert_equal('acceptEdits', claude.Debug().mode)
  # The reply to set_model tells which model is in effect.
  g:WaitFor("claude#InputStatusLine(win_getid())->stridx('haiku') >= 0")
  claude.Send('two')
  g:WaitFor('!claude#Busy()')
  assert_equal(1, len(filter(g:FakeLog(), (_, l) => l =~ '^ARGS ')))
  claude.SetModel('default')
  claude.SetMode('default')
enddef

def g:Test_bypass_mode_asks_first()
  Reset()
  g:claude_confirm_bypass = true
  claude.SetMode('bypassPermissions')
  assert_equal('default', claude.Debug().mode)
  g:claude_confirm_bypass = false
  claude.SetMode('bypassPermissions')
  assert_equal('bypassPermissions', claude.Debug().mode)
  unlet g:claude_confirm_bypass
  claude.SetMode('default')
enddef

def g:Test_cycle_mode_follows_the_cli_order()
  Reset()
  var seen: list<string> = []
  for _ in range(4)
    claude.CycleMode()
    add(seen, claude.Debug().mode)
  endfor
  assert_equal(['acceptEdits', 'plan', 'default', 'acceptEdits'], seen)
  claude.SetMode('default')
enddef

def g:Test_stop_interrupts_a_running_turn()
  Reset()
  claude.Send('SLOW please')
  g:WaitFor("index(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), '  Working') >= 0")
  assert_true(claude.Debug().busy)
  StopAndWait()
  assert_false(claude.Debug().busy)
  assert_equal('  ■ Interrupted', ChatLines()[-1])
enddef

def g:Test_retry_mode_denial_prompts_and_allow_retries()
  g:claude_permission_prompt = 'retry'
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
  unlet g:claude_permission_prompt
enddef

def Replies(): list<dict<any>>
  return mapnew(filter(g:FakeLog(), (_, l) => l =~ '^STDIN {"type":"control_response"'),
    (_, l) => json_decode(l[6 :]).response)
enddef

def Press(key: string)
  g:WaitFor('!empty(popup_list())')
  feedkeys(key, 'tx')
enddef

def g:Test_permission_prompt_answers_the_cli_in_place()
  Reset()
  claude.Send('CTRLPERM edit it')
  g:WaitFor('!empty(popup_list())')
  assert_match('--permission-prompt-tool stdio', filter(g:FakeLog(), (_, l) => l =~ '^ARGS ')[0])
  var popup = popup_list()[0]
  var text = join(getbufline(winbufnr(popup), 1, '$'), "\n")
  # The popup shows the actual change.
  assert_match('- two', text)
  assert_match('+ 2', text)
  assert_match('^ Edit a.txt ', popup_getoptions(popup).title)
  assert_true(claude.Debug().busy)
  # Allow for this session -> a rule that applies in the running process.
  feedkeys('a', 'tx')
  # Second request (Bash) is shown next, no restart in between.
  g:WaitFor('!empty(popup_list())')
  assert_match('# Run tests', join(getbufline(winbufnr(popup_list()[0]), 1, '$'), "\n"))
  feedkeys('n', 'tx')
  g:WaitFor('!claude#Busy()')
  var r = Replies()
  assert_equal('allow', r[0].response.behavior)
  assert_equal([{type: 'addRules', rules: [{toolName: 'Edit'}], behavior: 'allow', destination: 'session'}],
    r[0].response.updatedPermissions)
  assert_equal('r1', r[0].request_id)
  assert_equal('deny', r[1].response.behavior)
  assert_equal(1, len(filter(g:FakeLog(), (_, l) => l =~ '^ARGS ')))
  var chat = join(ChatLines(), "\n")
  assert_match('✓ Allowed for this session: Edit a.txt', chat)
  assert_match('✗ Denied: Bash npm test', chat)
  # Denials the user already answered are not asked again after the turn.
  assert_notmatch('Needs permission', chat)
  assert_equal([], popup_list())
enddef

def g:Test_permission_prompt_accept_edits_changes_mode_without_restart()
  Reset()
  claude.Send('CTRLPERM edit it')
  Press('e')
  Press('y')
  g:WaitFor('!claude#Busy()')
  assert_equal('acceptEdits', claude.Debug().mode)
  assert_equal([{type: 'setMode', mode: 'acceptEdits', destination: 'session'}],
    Replies()[0].response.updatedPermissions)
  claude.SetMode('default')
enddef

def g:Test_escape_denies_a_permission_prompt()
  Reset()
  claude.Send('CTRLPERM edit it')
  Press("\<Esc>")
  Press("n")
  g:WaitFor('!claude#Busy()')
  assert_equal(['deny', 'deny'], mapnew(Replies(), (_, r) => r.response.behavior))
enddef

def g:Test_stop_sends_interrupt_and_keeps_the_process()
  Reset()
  claude.Send('SLOW please')
  g:WaitFor("index(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), '  Working') >= 0")
  claude.Stop()
  assert_true(claude.Debug().busy)  # not over until the CLI ends the turn
  g:WaitFor('!claude#Busy()')
  assert_equal('  ■ Interrupted', ChatLines()[-1])
  assert_equal(1, len(filter(g:FakeLog(), (_, l) => l =~ '"subtype":"interrupt"')))
  # Same process: the next message does not start a new one.
  claude.Send('hello again')
  g:WaitFor('!claude#Busy()')
  assert_equal(1, len(filter(g:FakeLog(), (_, l) => l =~ '^ARGS ')))
enddef

def g:Test_stop_kills_a_process_that_ignores_the_interrupt()
  Reset()
  claude.Send('SLOW NOINT please')
  g:WaitFor("index(getbufline(" .. claude.Debug().chat_buf .. ", 1, '$'), '  Working') >= 0")
  claude.Stop()
  g:WaitFor('!claude#Busy()', 6000)
  assert_equal('  ■ Interrupted', ChatLines()[-1])
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
  StopAndWait()
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
  StopAndWait()
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

def g:Test_code_fences_work_inside_wrapping_markdown_regions()
  # vim-polyglot's Markdown wraps paragraphs in a region (mkdNonListItemBlock)
  # whose 'contains' only lists its own items; fences must still get through.
  Reset()
  claude.Open()
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  syntax region testWrapBlock start=/^\ze  \S/ end=/^\ze✻ Claude:$/ contains=markdownCode keepend containedin=claudeMsgClaude,claudeMsgYou
  # Like a fresh session: the Markdown syntax exists before any fence rule.
  doautocmd Syntax
  claude.Send('CODE please')
  g:WaitFor('!claude#Busy()')
  var lnum = index(ChatLines(), '  function f() { return x; }') + 1
  var names = join(synstack(lnum, 3)->map((_, id) => synIDattr(id, 'name')), ' ')
  assert_match('claudeFence\d\+ .*javaScript', names)
enddef

def g:Test_quote_selection_from_reply_into_input()
  Reset()
  claude.Open()
  claude.Send('CODE please')
  g:WaitFor('!claude#Busy()')
  var input = claude.Debug().input_buf
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  # Lines of the js block -> fenced js, indent removed.
  var l1 = index(ChatLines(), '  const x = 1;') + 1
  execute "normal! " .. l1 .. "GVj\<Esc>"
  claude.QuoteSelection()
  assert_equal(['```js', 'const x = 1;', 'function f() { return x; }', '```', ''], getbufline(input, 1, '$'))
  assert_equal(input, bufnr())
  assert_equal(line('$'), line('.'))

  # Part of a prose line (charwise) -> a quote, appended after a blank line.
  stopinsert
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  var lk = index(ChatLines(), '  Look:') + 1
  execute "normal! " .. lk .. "G3|ve\<Esc>"
  claude.QuoteSelection()
  assert_equal(['> Look', ''], getbufline(input, 6, '$'))

  # The visual <CR> mapping is set in the transcript.
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  assert_match('QuoteSelection', maparg('<CR>', 'x'))
enddef

def g:Test_tool_results_show_diffs_output_and_todos()
  Reset()
  claude.Send('TOOLS please')
  g:WaitFor('!claude#Busy()')
  var lines = ChatLines()
  var i = index(lines, '  ● Read a.txt')
  assert_equal('    ⎿ Read 42 lines', lines[i + 1])
  i = index(lines, '  ● Edit a.txt')
  assert_equal('    ⎿ Updated a.txt with 1 addition and 1 removal', lines[i + 1])
  assert_equal(['       1   one', '       2 - two', '       2 + 2', '       3   three'], lines[i + 2 : i + 5])
  # Output is capped, with the remainder counted.
  i = index(lines, '  ● Bash ls')
  assert_equal('    ⎿ a.txt', lines[i + 1])
  assert_equal(['      b.txt', '      c.txt', '      d.txt', '      … +6 lines'], lines[i + 2 : i + 5])
  # Todo list.
  i = index(lines, '  ● Update todo list')
  assert_equal(['    ⎿ ☒ Plan', '      ◼ Building', '      ☐ Ship'], lines[i + 1 : i + 3])
  # Added and removed lines are highlighted.
  var buf = claude.Debug().chat_buf
  var ed = index(lines, '  ● Edit a.txt') + 2
  var kinds = mapnew(range(ed + 1, ed + 3), (_, l) => map(prop_list(l, {bufnr: buf}), (_, p) => p.type))
  assert_equal([['claude_tool_ctx'], ['claude_tool_del'], ['claude_tool_add']], kinds)
enddef

def g:Test_tool_details_can_be_turned_off()
  g:claude_tool_details = false
  Reset()
  claude.Send('TOOLS please')
  g:WaitFor('!claude#Busy()')
  unlet g:claude_tool_details
  assert_equal(-1, index(ChatLines(), '    ⎿ Read 42 lines'))
  assert_notequal(-1, index(ChatLines(), '  ● Read a.txt'))
enddef

def Sent(): list<string>
  return filter(g:FakeLog(), (_, l) => l =~ '^STDIN ')
enddef

def g:Test_slash_command_is_sent_verbatim_without_editor_context()
  Reset()
  g:claude_last_ctx = {file: expand('%:p'), line: 1, total: 1}
  claude.Send('/hi Bob')
  g:WaitFor('!claude#Busy()')
  var msg = json_decode(Sent()[0][6 :])
  assert_equal('/hi Bob', msg.message.content)
  # A normal message still carries the editor context.
  claude.Send('plain')
  g:WaitFor('!claude#Busy()')
  unlet g:claude_last_ctx
enddef

def g:Test_clear_model_and_help_are_handled_locally()
  Reset()
  claude.Send('first')
  g:WaitFor('!claude#Busy()')
  assert_equal(1, len(Sent()))
  claude.Send('/model haiku')
  claude.Send('/help')
  assert_match('/compact ', join(ChatLines(), "\n"))
  assert_match('… and 1 more (custom commands and skills)', join(ChatLines(), "\n"))
  claude.Send('/clear')
  assert_equal([''], ChatLines())
  assert_equal(1, len(Sent()))   # none of them reached the CLI
  claude.SetModel('default')
enddef

def g:Test_unknown_command_is_refused_and_kept_in_the_input()
  Reset()
  claude.Send('warm up')
  g:WaitFor('!claude#Busy()')
  claude.Open()
  claude.Send('/nonsense foo')
  var warn = execute('messages')
  assert_match('unknown command /nonsense', warn)
  assert_equal(['/nonsense foo'], getbufline(claude.Debug().input_buf, 1, '$'))
  assert_equal(1, len(Sent()))
  # A leading space sends it as plain text.
  claude.Send(' /nonsense foo')
  g:WaitFor('!claude#Busy()')
  assert_equal(2, len(Sent()))
enddef

def g:Test_compact_shows_progress_and_result()
  Reset()
  claude.Send('/compact')
  g:WaitFor('!claude#Busy()')
  assert_match('conversation compacted (19.1k → 6.7k tokens)', join(ChatLines(), "\n"))
enddef

def g:Test_slash_candidates_come_from_the_cli_and_custom_files()
  Reset()
  # Before the CLI has reported anything: the basics.
  assert_true(index(mapnew(claude.SlashCandidates(''), (_, i) => i.word), '/compact') >= 0)
  claude.Send('hello')
  g:WaitFor('!claude#Busy()')
  var words = mapnew(claude.SlashCandidates(''), (_, i) => i.word)
  assert_true(index(words, '/hi') >= 0)       # reported by the CLI
  assert_true(index(words, '/help') >= 0)     # handled by the plugin
  assert_equal(-1, index(words, '/__internal'))
  assert_equal('/clear', words[0])
  assert_equal('Start a new conversation', claude.SlashCandidates('clear')[0].menu)
enddef

def g:Test_custom_command_descriptions_are_read_from_claude_dir()
  var dir = tempname()
  mkdir(dir .. '/.claude/commands', 'p')
  writefile(['---', 'description: Say hello to someone', '---', 'Say hello to $ARGUMENTS'], dir .. '/.claude/commands/hi.md')
  var old = getcwd()
  execute 'cd ' .. fnameescape(dir)
  var items = claude.SlashCandidates('hi')
  execute 'cd ' .. fnameescape(old)
  delete(dir, 'rf')
  assert_equal('Say hello to someone', items[0].menu)
enddef

def g:Test_plan_approval_popup()
  Reset()
  claude.SetMode('plan')
  claude.Send('CTRLPLAN make a plan')
  g:WaitFor('!empty(popup_list())')
  var text = join(getbufline(winbufnr(popup_list()[0]), 1, '$'), "\n")
  assert_match('# Plan\n1. Do it\n2. Test it', text)
  assert_match('approve + auto-accept edits', text)
  assert_match("Claude's plan", popup_getoptions(popup_list()[0]).title)
  feedkeys('a', 'tx')
  g:WaitFor('!claude#Busy()')
  var r = Replies()[0]
  assert_equal('allow', r.response.behavior)
  assert_equal([{type: 'setMode', mode: 'acceptEdits', destination: 'session'}], r.response.updatedPermissions)
  assert_equal('acceptEdits', claude.Debug().mode)
  assert_match('✓ Plan approved (auto-accepting edits)', join(ChatLines(), "\n"))
  claude.SetMode('default')
enddef

def g:Test_plan_approval_keep_planning_and_plain_approve()
  Reset()
  claude.SetMode('plan')
  claude.Send('CTRLPLAN one')
  Press('n')
  g:WaitFor('!claude#Busy()')
  assert_equal('deny', Replies()[0].response.behavior)
  assert_match('keep planning', Replies()[0].response.message)
  assert_equal('plan', claude.Debug().mode)
  writefile([], $FAKE_CLAUDE_LOG)
  claude.Send('CTRLPLAN two')
  Press('y')
  g:WaitFor('!claude#Busy()')
  assert_equal('default', claude.Debug().mode)   # back to what it was before plan mode
  claude.SetMode('default')
enddef

def g:Test_ask_user_question_collects_answers()
  Reset()
  claude.Send('CTRLASK pick')
  g:WaitFor('!empty(popup_list())')
  var first = join(getbufline(winbufnr(popup_list()[0]), 1, '$'), "\n")
  assert_match('Which color?', first)
  assert_match('2. Blue', first)
  assert_match('(1/2)', popup_getoptions(popup_list()[0]).title)
  feedkeys('2', 'tx')
  g:WaitFor('!empty(popup_list()) && getbufline(winbufnr(popup_list()[0]), 1)[0] =~ "sizes"')
  feedkeys('1', 'tx')
  feedkeys('3', 'tx')
  assert_match('3. \[x\] L', join(getbufline(winbufnr(popup_list()[0]), 1, '$'), "\n"))
  feedkeys("\<CR>", 'tx')
  g:WaitFor('!claude#Busy()')
  var r = Replies()[0].response
  assert_equal('allow', r.behavior)
  assert_equal({'Which color?': 'Blue', 'Which sizes?': 'S, L'}, r.updatedInput.answers)
  assert_equal(2, len(r.updatedInput.questions))
  assert_match('✓ Answered: Blue · S, L', join(ChatLines(), "\n"))
enddef

def g:Test_skipping_a_question_denies()
  Reset()
  claude.Send('CTRLASK pick')
  Press("\<Esc>")
  g:WaitFor('!claude#Busy()')
  assert_equal('deny', Replies()[0].response.behavior)
  assert_match('✗ Skipped the question', join(ChatLines(), "\n"))
enddef

def g:Test_context_usage_shows_in_the_statusline_and_warns()
  Reset()
  claude.Open()
  claude.Send('CTX please')
  g:WaitFor('!claude#Busy()')
  var bar = claude#InputStatusLine(win_getid())
  # The last API call counts: 20 + 879980 of a 1M window.
  assert_match('⚠ ctx 88%\|ctx 88%', bar)
  assert_match('! Context is 88% full', join(ChatLines(), "\n"))
  g:claude_show_cost = true
  assert_match('\$0.05', claude#InputStatusLine(win_getid()))
  unlet g:claude_show_cost
  claude.NewChat()
  assert_notmatch('ctx', claude#InputStatusLine(win_getid()))
enddef
