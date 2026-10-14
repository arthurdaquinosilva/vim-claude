vim9script
# claude.vim — chat panel backed by a long-running `claude -p` process that
# speaks stream-json on stdin/stdout.

import autoload 'claude/util.vim'

const SPIN = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
const HDR_USER = '❯ You'
const HDR_CLAUDE = '✻ Claude'
const HDR_PAT = '^\%(❯ You\|✻ Claude\)$'
const LIVE_LABELS = {thinking: 'thinking…', responding: 'writing…'}
const MODES = ['default', 'acceptEdits', 'plan', 'bypassPermissions']
const MODE_LABELS = {default: 'ask before edits', acceptEdits: 'auto-accept edits',
  plan: 'plan mode', bypassPermissions: 'bypass permissions'}

var chat_buf = -1
var input_buf = -1

var job: job = null_job
var gen = 0                 # bumps on every process start; stale callbacks are ignored
var proc_sig = ''           # args the running process was started with
var session_id = ''
var model_name = ''         # as reported by the CLI
var model = ''              # as requested by the user ('' = CLI default)
var perm_mode = ''
var session_allowed: list<string> = []

var busy = false
var status_text = ''
var spin_i = 0
var spin_timer = 0
var turn_start: list<any> = []
var stderr_tail: list<string> = []

var last_kind = ''          # 'user' | 'header' | 'text' | 'tool' | 'info'
var text_open = false
var streamed = false        # current assistant message arrived via deltas
var touched_files = false
var text_start = 0          # first line of the text block being streamed
var turn_header = false     # "✻ Claude" already printed for this turn
var live_lnum = 0           # line of the "✻ Claude" header showing the spinner

var history: list<string> = []
var hist_idx = -1
var file_cache: list<string> = []

def Opt(name: string, default: any): any
  return get(g:, 'claude_' .. name, default)
enddef

def Mode(): string
  return perm_mode != '' ? perm_mode : Opt('permission_mode', 'default')
enddef

def Model(): string
  return model != '' ? model : Opt('model', '')
enddef

def Warn(msg: string)
  echohl WarningMsg | echomsg 'claude: ' .. msg | echohl None
enddef

# ---------------------------------------------------------------- panel

def ChatWins(): list<number>
  return bufexists(chat_buf) ? win_findbuf(chat_buf) : []
enddef

def InputWins(): list<number>
  return bufexists(input_buf) ? win_findbuf(input_buf) : []
enddef

export def IsOpen(): bool
  return !empty(filter(ChatWins(), (_, w) => win_id2tabwin(w)[0] == tabpagenr()))
enddef

# Keep LSP/completion plugins (coc, etc.) from attaching to panel buffers.
def DetachCompletion()
  b:coc_enabled = 0
  b:coc_suggest_disable = 1
  b:ale_enabled = 0
  b:copilot_enabled = false
enddef

def SetupChatBuf()
  DetachCompletion()
  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
  setlocal nomodifiable
  setlocal filetype=claudechat
  silent! file claude://chat
  chat_buf = bufnr()
  prop_type_add('claude_code', {bufnr: chat_buf, highlight: 'claudeTableCode'})
  prop_type_add('claude_time', {bufnr: chat_buf, highlight: 'ClaudeTime'})
  prop_type_add('claude_live', {bufnr: chat_buf, highlight: 'ClaudeLive'})
  prop_type_add('claude_user', {bufnr: chat_buf, highlight: 'ClaudeUserText'})

  nnoremap <buffer><silent> q <ScriptCmd>Close()<CR>
  nnoremap <buffer><silent> <C-c> <ScriptCmd>Stop()<CR>
  for key in ['i', 'a', 'I', 'A', 'o', 'O', '<CR>']
    execute 'nnoremap <buffer><silent> ' .. key .. ' <ScriptCmd>FocusInput(true)<CR>'
  endfor
  nnoremap <buffer><silent> ]] <ScriptCmd>search(HDR_PAT, 'W')<CR>
  nnoremap <buffer><silent> [[ <ScriptCmd>search(HDR_PAT, 'bW')<CR>
  nnoremap <buffer><silent> gy <ScriptCmd>YankCodeBlock()<CR>

  augroup claude_chat
    autocmd! * <buffer>
    autocmd BufWinLeave <buffer> timer_start(0, (_) => CloseOrphanInput())
  augroup END
enddef

def SetupChatWin()
  setlocal wrap linebreak breakindent nonumber norelativenumber nolist nospell
  setlocal signcolumn=no foldcolumn=0 colorcolumn= winfixwidth conceallevel=2
  setlocal foldmethod=expr foldlevel=99
  &l:foldexpr = "getline(v:lnum) =~# '" .. HDR_PAT .. "' ? '>1' : '1'"
  &l:statusline = '%!claude#StatusLine()'
enddef

def SetupInputBuf()
  DetachCompletion()
  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
  setlocal filetype=claudeinput
  silent! file claude://input
  input_buf = bufnr()
  &l:omnifunc = 'claude#CompleteMention'

  setlocal completeopt=menuone,noinsert,popup
  # Enter picks the highlighted @file while the menu is open, otherwise sends.
  inoremap <buffer><silent><expr> <CR> pumvisible() ? "\<C-y> " : "\<Cmd>call claude#SubmitInput()\<CR>"
  inoremap <buffer><expr> <Tab> pumvisible() ? "\<C-n>" : "\<Tab>"
  inoremap <buffer><expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<S-Tab>"
  inoremap <buffer> <S-CR> <CR>
  nnoremap <buffer><silent> <CR> <ScriptCmd>SubmitInput()<CR>
  inoremap <buffer><silent> <C-c> <ScriptCmd>Stop()<CR>
  nnoremap <buffer><silent> <C-c> <ScriptCmd>Stop()<CR>
  nnoremap <buffer><silent> q <ScriptCmd>Close()<CR>
  inoremap <buffer><silent> <C-p> <ScriptCmd>History(-1)<CR>
  inoremap <buffer><silent> <C-n> <ScriptCmd>History(1)<CR>
  nnoremap <buffer><silent> <C-p> <ScriptCmd>History(-1)<CR>
  nnoremap <buffer><silent> <C-n> <ScriptCmd>History(1)<CR>

  prop_type_add('claude_placeholder', {bufnr: input_buf, highlight: 'ClaudePlaceholder'})

  augroup claude_input
    autocmd! * <buffer>
    # Refresh first: once the @file menu is open, refreshing is skipped.
    autocmd TextChanged,TextChangedI,BufWinEnter,CompleteDone <buffer> RefreshInput()
    autocmd TextChangedI,TextChangedP <buffer> MentionComplete()
    autocmd WinResized * RefreshInput()
  augroup END
enddef

def SetupInputWin()
  setlocal wrap linebreak nonumber norelativenumber nolist signcolumn=yes foldcolumn=0
  setlocal nocursorline nocursorcolumn colorcolumn= winfixheight winfixwidth
  &l:fillchars = &g:fillchars .. ',eob: '
  &l:wincolor = 'ClaudeInput'
  &l:statusline = '%!claude#InputStatusLine()'
  RefreshInput()
enddef

# ---------------------------------------------------------------- look

def DefineHighlights()
  if Opt('input_tint', false)
    # Opt-in: a shade lighter (dark themes) or darker (light) than Normal.
    var dark = &background == 'dark'
    var normal = hlget('Normal', true)
    var n = empty(normal) ? {} : normal[0]
    var cbg = get(n, 'ctermbg', '') =~ '^\d\+$' ? str2nr(n.ctermbg) : -1
    var gbg = get(n, 'guibg', '') =~ '^#\x\{6}$' ? n.guibg : (dark ? '#1c1c1c' : '#ffffff')
    execute printf('highlight default ClaudeInput ctermbg=%d guibg=%s',
      util.ShadeCterm(cbg, dark), util.Shade(gbg, dark ? 0.06 : -0.04))
  else
    # Same background as the editor (transparent when Normal is).
    highlight default link ClaudeInput Normal
  endif
  var inbg = hlget('ClaudeInput', true)[0]
  var sp = hlget('Special', true)
  var spfg = empty(sp) ? {} : sp[0]
  execute printf('highlight default ClaudeInputSign ctermbg=%s guibg=%s',
    get(inbg, 'ctermbg', 'NONE'), get(inbg, 'guibg', 'NONE'))
  execute printf('highlight default ClaudePromptSign ctermfg=%s guifg=%s ctermbg=%s guibg=%s cterm=bold gui=bold',
    get(spfg, 'ctermfg', 'NONE'), get(spfg, 'guifg', 'NONE'),
    get(inbg, 'ctermbg', 'NONE'), get(inbg, 'guibg', 'NONE'))
  sign_define('ClaudePrompt', {text: '❯', texthl: 'ClaudePromptSign'})
  sign_define('ClaudeCont', {text: ' ', texthl: 'ClaudeInputSign'})
  # Speakers: you in the prompt color, Claude in Claude's orange.
  highlight default ClaudeAssistant ctermfg=173 guifg=#d97757 cterm=bold gui=bold
  highlight default ClaudeLive ctermfg=173 guifg=#d97757
  highlight default link ClaudeTime Comment
  highlight default link ClaudeUserText Comment
  var spc = hlget('Special', true)
  var sp0 = empty(spc) ? {} : spc[0]
  execute printf('highlight default ClaudeYou ctermfg=%s guifg=%s cterm=bold gui=bold',
    get(sp0, 'ctermfg', 'NONE'), get(sp0, 'guifg', 'NONE'))
  highlight default link ClaudeRule Comment
  LinkCodeHighlight()
  highlight default link ClaudeTitle Title
  highlight default link ClaudeBusy Special
  highlight default link ClaudeChip Directory
  highlight default link ClaudePlaceholder Comment
enddef

# Inline code in tables: use whichever Markdown code group has a color in
# this colorscheme (they differ between Markdown syntaxes), else String.
export def LinkCodeHighlight()
  var group = 'String'
  for g in ['mkdCode', 'markdownCode']
    var h = hlget(g, true)
    if !empty(h) && (has_key(h[0], 'ctermfg') || has_key(h[0], 'guifg'))
      group = g
      break
    endif
  endfor
  # Respect a user-defined color; otherwise (re)link to the found group.
  var cur = hlget('claudeTableCode')
  var custom = !empty(cur) && !has_key(cur[0], 'linksto') && !get(cur[0], 'cleared', false)
  if !custom
    execute 'highlight! link claudeTableCode ' .. group
  endif
enddef

DefineHighlights()
augroup claude_colors
  autocmd!
  autocmd ColorScheme * DefineHighlights()
augroup END

# Inline "❯ " prompt, continuation indent, placeholder; then fit the height.
def RefreshInput()
  # Touching text props or window sizes would close the completion menu.
  if !bufexists(input_buf) || pumvisible()
    return
  endif
  var n = getbufinfo(input_buf)[0].linecount
  prop_clear(1, n, {bufnr: input_buf})
  # "❯" on the first line, tinted blanks on the rest (signs never shift).
  sign_unplace('claude_input', {buffer: input_buf})
  sign_placelist(mapnew(range(1, n), (_, l) => ({group: 'claude_input', buffer: input_buf,
    lnum: l, name: l == 1 ? 'ClaudePrompt' : 'ClaudeCont'})))
  if n == 1 && getbufline(input_buf, 1)[0] == ''
    var hint = busy ? 'Claude is working…  ctrl-c to stop'
                    : 'Ask Claude…  @ to mention a file'
    prop_add(1, 0, {bufnr: input_buf, type: 'claude_placeholder', text: hint, text_align: 'after'})
  endif
  var lines = getbufline(input_buf, 1, '$')
  # Only resize an input box stacked right under the chat: in any other
  # layout (e.g. the chat was just :q'd) resizing would squash its neighbours.
  for w in filter(InputWins(), (_, id) => UnderChat(id))
    var rows = util.DisplayRows(lines, winwidth(w) - 2, 0)
    var h = min([max([rows, Opt('input_height', 1)]), Opt('input_max_height', 12)])
    if winheight(w) != h
      win_execute(w, 'resize ' .. h)
    endif
    if rows <= h && line('w0', w) > 1
      # Everything fits: show it from the top instead of the scrolled view.
      win_execute(w, 'winrestview({topline: 1})')
    endif
  endfor
enddef

def UnderChat(input_win: number): bool
  var i = getwininfo(input_win)
  if empty(i) || i[0].tabnr != tabpagenr()
    return false
  endif
  for c in ChatWins()
    var ci = getwininfo(c)[0]
    if ci.tabnr == i[0].tabnr && ci.wincol == i[0].wincol && ci.width == i[0].width
        && ci.winrow + ci.height + 1 == i[0].winrow
      return true
    endif
  endfor
  return false
enddef

export def InputStatusLine(winid: number = 0): string
  var lefts = [
    [['enter', 'ClaudeTitle'], [' send · ', ''], ['ctrl-j', 'ClaudeTitle'], [' newline · ', ''],
     ['@', 'ClaudeTitle'], [' file · ', ''], ['ctrl-p', 'ClaudeTitle'], [' history', '']],
    [['enter', 'ClaudeTitle'], [' send · ', ''], ['ctrl-j', 'ClaudeTitle'], [' newline', '']],
    [['enter', 'ClaudeTitle'], [' send', '']],
  ]
  if busy
    lefts = [[['ctrl-c', 'ClaudeTitle'], [' stop', '']]]
  endif
  var right: list<list<string>> = []
  var ctx = get(g:, 'claude_last_ctx', {})
  if Opt('include_context', true) && !empty(ctx) && get(ctx, 'file', '') != ''
    right = [[fnamemodify(ctx.file, ':t') .. ':' .. ctx.line, 'ClaudeChip']]
  endif
  return util.Rule(lefts, right, winwidth(winid != 0 ? winid : g:statusline_winid), 'ClaudeRule')
enddef

# g:claude_width: columns (> 1) or a fraction of the screen (<= 1); default half.
def PanelWidth(): number
  var w = Opt('width', 0.5)
  return type(w) == v:t_float || w <= 1 ? float2nr(&columns * (w == 0 ? 0.5 : w)) : w
enddef

def OnVimResized()
  if Opt('position', 'right') == 'bottom'
    return
  endif
  for w in ChatWins() + InputWins()
    if win_id2tabwin(w)[0] == tabpagenr()
      win_execute(w, 'vertical resize ' .. PanelWidth())
      break
    endif
  endfor
enddef

augroup claude_resize
  autocmd!
  autocmd VimResized * OnVimResized()
augroup END

def CreatePanel()
  var pos = Opt('position', 'right')
  var width = PanelWidth()
  if pos == 'left'
    topleft vsplit
    execute 'vertical resize ' .. width
  elseif pos == 'bottom'
    botright split
    execute 'resize ' .. Opt('height', 18)
  else
    botright vsplit
    execute 'vertical resize ' .. width
  endif
  if bufexists(chat_buf)
    execute 'silent buffer ' .. chat_buf
  else
    silent enew
    SetupChatBuf()
  endif
  SetupChatWin()
  var chat_win = win_getid()

  belowright split
  execute 'resize ' .. Opt('input_height', 1)
  if bufexists(input_buf)
    execute 'silent buffer ' .. input_buf
  else
    silent enew
    SetupInputBuf()
  endif
  SetupInputWin()
  win_execute(chat_win, 'normal! G')
enddef

export def Open(focus: bool = true)
  if !IsOpen()
    var from = win_getid()
    CreatePanel()
    if !focus
      win_gotoid(from)
    endif
  endif
  if focus
    FocusInput(true)
  endif
enddef

export def Toggle()
  if IsOpen()
    Close()
  else
    Open()
  endif
enddef

export def Close()
  for w in InputWins() + ChatWins()
    if win_id2tabwin(w)[0] == tabpagenr() && winnr('$') > 1
      execute 'silent! :' .. win_id2win(w) .. 'close'
    endif
  endfor
enddef

def CloseOrphanInput()
  if empty(ChatWins())
    for w in InputWins()
      if winnr('$') > 1
        execute 'silent! :' .. win_id2win(w) .. 'close'
      endif
    endfor
  endif
enddef

def FocusInput(insert: bool)
  if !IsOpen()
    CreatePanel()
  endif
  var wins = filter(InputWins(), (_, w) => win_id2tabwin(w)[0] == tabpagenr())
  if empty(wins)
    # Input window was closed on its own; recreate it under the chat window.
    win_gotoid(filter(ChatWins(), (_, w) => win_id2tabwin(w)[0] == tabpagenr())[0])
    belowright split
    execute 'resize ' .. Opt('input_height', 1)
    execute 'silent buffer ' .. input_buf
    SetupInputWin()
  else
    win_gotoid(wins[0])
  endif
  if insert
    normal! G$
    startinsert!
  endif
enddef

# ---------------------------------------------------------------- render

# Run `F` with the chat buffer modifiable, keeping windows that were at the
# bottom glued to the bottom (and leaving scrolled-back windows alone).
def Modify(F: func)
  if !bufexists(chat_buf)
    return
  endif
  var follow = filter(ChatWins(), (_, w) => line('.', w) >= line('$', w))
  setbufvar(chat_buf, '&modifiable', 1)
  F()
  setbufvar(chat_buf, '&modifiable', 0)
  for w in follow
    win_execute(w, 'normal! G')
  endfor
enddef

def LastLine(): string
  return getbufline(chat_buf, '$')[0]
enddef

def BufEmpty(): bool
  return getbufinfo(chat_buf)[0].linecount == 1 && getbufline(chat_buf, 1)[0] == ''
enddef

def Append(lines: list<string>)
  Modify(() => {
    if BufEmpty()
      setbufline(chat_buf, 1, lines)
    else
      appendbufline(chat_buf, '$', lines)
    endif
  })
enddef

def EnsureBlank()
  if bufexists(chat_buf) && LastLine() != ''
    Append([''])
  endif
enddef

def EnsureChatBuf()
  if bufexists(chat_buf)
    return
  endif
  var from = win_getid()
  CreatePanel()
  win_gotoid(from)
enddef

def LineCount(): number
  return getbufinfo(chat_buf)[0].linecount
enddef

# Speaker line ("❯ You" / "✻ Claude") with the time right-aligned.
def Header(name: string, time: string)
  CloseText()
  if bufexists(chat_buf) && !BufEmpty()
    EnsureBlank()
  endif
  Append([name])
  if time != ''
    prop_add(LineCount(), 0, {bufnr: chat_buf, type: 'claude_time', text: time, text_align: 'right'})
  endif
  last_kind = 'header'
enddef

def RenderUser(text: string, time: string = strftime('%H:%M'))
  Header(HDR_USER, time)
  turn_header = false
  var first = LineCount() + 1
  var lines = split(text, "\n", 1)
  Append(lines)
  # Your own message is dimmed, so Claude's replies stand out.
  for i in range(len(lines))
    if lines[i] != ''
      prop_add(first + i, 1, {bufnr: chat_buf, type: 'claude_user', length: strlen(lines[i])})
    endif
  endfor
  last_kind = 'user'
enddef

# "✻ Claude ⠋ writing…" on the header while the reply is in progress.
def UpdateLive()
  if !bufexists(chat_buf)
    return
  endif
  prop_remove({bufnr: chat_buf, type: 'claude_live', all: true})
  if busy && live_lnum > 0 && live_lnum <= LineCount() && getbufline(chat_buf, live_lnum)[0] == HDR_CLAUDE
    var label = get(LIVE_LABELS, status_text, status_text .. '…')
    prop_add(live_lnum, 0, {bufnr: chat_buf, type: 'claude_live', text_align: 'after',
      text: '  ' .. SPIN[spin_i % len(SPIN)] .. ' ' .. label})
  endif
enddef

def Info(line: string)
  CloseText()
  if last_kind == 'text' || last_kind == 'user'
    EnsureBlank()
  endif
  Append(['  ' .. line])
  last_kind = 'info'
enddef

def BeginText()
  if text_open
    return
  endif
  if last_kind != 'header'
    EnsureBlank()
  endif
  Append([''])
  text_start = getbufinfo(chat_buf)[0].linecount
  text_open = true
  last_kind = 'text'
enddef

def CloseText()
  if text_open
    FormatTablesFrom(text_start)
  endif
  text_open = false
enddef

# Redraw markdown tables from line `start` on as aligned box tables.
def FormatTablesFrom(start: number)
  if !Opt('format_tables', true) || !bufexists(chat_buf) || start < 1
    return
  endif
  var wins = ChatWins()
  var width = empty(wins) ? Opt('width', 80) : winwidth(wins[0])
  var reps = util.FormatTables(getbufline(chat_buf, start, '$'), width - 1)
  if empty(reps)
    return
  endif
  Modify(() => {
    for r in reverse(reps)
      deletebufline(chat_buf, start + r[0], start + r[1])
      appendbufline(chat_buf, start + r[0] - 1, r[2])
      for [li, col, len] in r[3]
        prop_add(start + r[0] + li, col, {bufnr: chat_buf, type: 'claude_code', length: len})
      endfor
    endfor
  })
enddef

def AppendText(s: string)
  if s == ''
    return
  endif
  BeginText()
  var parts = split(s, "\n", 1)
  Modify(() => {
    setbufline(chat_buf, '$', getbufline(chat_buf, '$')[0] .. parts[0])
    if len(parts) > 1
      appendbufline(chat_buf, '$', parts[1 :])
    endif
  })
  # A table just ended (a finished non-table line follows table rows):
  # format it now instead of waiting for the end of the block.
  if len(parts) > 1
    var n = getbufinfo(chat_buf)[0].linecount
    var done = getbufline(chat_buf, max([text_start, n - 2]), n - 1)
    if len(done) == 2 && done[0] =~ '^\s*|' && done[1] !~ '^\s*|'
      FormatTablesFrom(text_start)
    endif
  endif
enddef

def EnsureClaudeHeader(time: string = strftime('%H:%M'))
  if !turn_header
    Header(HDR_CLAUDE, time)
    turn_header = true
    live_lnum = LineCount()
    UpdateLive()
  endif
enddef

export def Clear()
  CloseText()
  last_kind = ''
  if bufexists(chat_buf)
    Modify(() => deletebufline(chat_buf, 1, '$'))
  endif
enddef

# ---------------------------------------------------------------- status

export def StatusLine(winid: number = 0): string
  var title = [['✻ Claude', 'ClaudeTitle']]
  var lefts = [title]
  if busy
    var spin = [[' ' .. SPIN[spin_i % len(SPIN)] .. ' ', 'ClaudeBusy']]
    lefts = [title + spin + [[status_text, 'ClaudeBusy']], title + spin]
  endif
  var m = substitute(model_name != '' ? model_name : Model(), '^claude-', '', '')
  var right = [[(m == '' ? '' : m .. ' · ') .. get(MODE_LABELS, Mode(), Mode()), '']]
  return util.Rule(lefts, right, winwidth(winid != 0 ? winid : g:statusline_winid), 'ClaudeRule')
enddef

def SetBusy(on: bool, what: string = 'thinking')
  busy = on
  status_text = what
  if on && spin_timer == 0
    turn_start = reltime()
    spin_timer = timer_start(100, (_) => {
      spin_i += 1
      UpdateLive()
      redrawstatus!
    }, {repeat: -1})
  elseif !on && spin_timer != 0
    timer_stop(spin_timer)
    spin_timer = 0
  endif
  UpdateLive()
  RefreshInput()
  redrawstatus!
enddef

# ---------------------------------------------------------------- process

def Running(): bool
  return job_status(job) == 'run'
enddef

def BuildArgs(): list<string>
  var cmd = Opt('cmd', 'claude')
  var args = type(cmd) == v:t_list ? copy(cmd) : [cmd]
  args += ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json',
    '--verbose', '--include-partial-messages',
    '--append-system-prompt', 'You are running inside a Vim chat panel. Your replies are '
      .. 'rendered as Markdown in a narrow, wrapped text buffer; keep tables narrow. '
      .. '@path and @path#Lx-y refer to files in the project.']
  if Model() != ''
    args += ['--model', Model()]
  endif
  if Mode() != 'default'
    args += ['--permission-mode', Mode()]
  endif
  if session_id != ''
    args += ['--resume', session_id]
  endif
  args += Opt('extra_args', [])
  if !empty(session_allowed)
    args += ['--allowedTools'] + session_allowed
  endif
  return args
enddef

def StopProcess()
  if !Running()
    return
  endif
  gen += 1  # silence its callbacks
  job_stop(job, 'term')
  var n = 0
  while job_status(job) == 'run' && n < 100
    sleep 10m
    n += 1
  endwhile
  if job_status(job) == 'run'
    job_stop(job, 'kill')
  endif
enddef

def EnsureProcess(): bool
  var cmd = Opt('cmd', 'claude')
  var exe = type(cmd) == v:t_list ? cmd[0] : cmd
  if !executable(exe)
    Warn('`' .. exe .. '` not found. Install Claude Code or set g:claude_cmd.')
    return false
  endif
  var sig = string([Model(), Mode(), session_allowed, Opt('extra_args', [])])
  if Running() && sig == proc_sig
    return true
  endif
  StopProcess()
  gen += 1
  var g = gen
  stderr_tail = []
  job = job_start(BuildArgs(), {
    out_mode: 'nl', err_mode: 'nl', noblock: true, cwd: getcwd(),
    out_cb: (_, msg) => {
      if g == gen
        OnEvent(msg)
      endif
    },
    err_cb: (_, msg) => {
      if g == gen
        AddStderr(msg)
      endif
    },
    exit_cb: (_, code) => {
      if g == gen
        OnExit(code)
      endif
    },
  })
  if job_status(job) != 'run'
    Warn('failed to start ' .. exe)
    return false
  endif
  proc_sig = sig
  return true
enddef

def AddStderr(msg: string)
  add(stderr_tail, msg)
  if len(stderr_tail) > 20
    remove(stderr_tail, 0)
  endif
enddef

def OnExit(code: number)
  if busy
    Info('✖ Claude process exited (code ' .. code .. ')')
    for l in stderr_tail[-5 :]
      Info('  ' .. l)
    endfor
    FinishTurn()
  endif
enddef

def FinishTurn()
  CloseText()
  SetBusy(false)
  if touched_files
    touched_files = false
    # Reload files Claude edited; buffers with unsaved changes still prompt.
    var ar = &autoread
    set autoread
    silent! checktime
    &autoread = ar
  endif
enddef

def SendRaw(payload: string): bool
  if !EnsureProcess()
    return false
  endif
  var msg = {type: 'user', message: {role: 'user', content: payload}}
  ch_sendraw(job, json_encode(msg) .. "\n")
  streamed = false
  turn_header = false
  SetBusy(true, 'thinking')
  # Show "✻ Claude ⠋ thinking…" right away, before the first token.
  EnsureClaudeHeader()
  return true
enddef

# ---------------------------------------------------------------- events

def IsSubagent(ev: dict<any>): bool
  return type(get(ev, 'parent_tool_use_id', v:null)) == v:t_string
enddef

def OnEvent(line: string)
  var ev: any
  try
    ev = json_decode(line)
  catch
    return
  endtry
  if type(ev) != v:t_dict
    return
  endif
  var t = get(ev, 'type', '')
  if t == 'system'
    if get(ev, 'subtype', '') == 'init'
      session_id = get(ev, 'session_id', session_id)
      model_name = get(ev, 'model', model_name)
    endif
  elseif t == 'stream_event'
    if !IsSubagent(ev)
      OnStreamEvent(get(ev, 'event', {}))
    endif
  elseif t == 'assistant'
    if !IsSubagent(ev)
      OnAssistant(get(ev, 'message', {}))
    endif
  elseif t == 'user'
    OnToolResults(ev)
  elseif t == 'result'
    OnResult(ev)
  endif
enddef

def OnStreamEvent(e: dict<any>)
  var et = get(e, 'type', '')
  if et == 'message_start'
    streamed = false
  elseif et == 'content_block_start'
    var block = get(e, 'content_block', {})
    var bt = get(block, 'type', '')
    if bt == 'thinking' || bt == 'redacted_thinking'
      status_text = 'thinking'
    elseif bt == 'tool_use'
      status_text = 'using ' .. get(block, 'name', 'tool')
    elseif bt == 'text'
      status_text = 'responding'
      EnsureClaudeHeader()
    endif
    UpdateLive()
  elseif et == 'content_block_delta'
    var d = get(e, 'delta', {})
    if get(d, 'type', '') == 'text_delta'
      streamed = true
      EnsureClaudeHeader()
      AppendText(get(d, 'text', ''))
    endif
  elseif et == 'content_block_stop'
    CloseText()
  endif
enddef

def OnAssistant(msg: dict<any>)
  for c in get(msg, 'content', [])
    var ct = get(c, 'type', '')
    if ct == 'tool_use'
      EnsureClaudeHeader()
      var name = get(c, 'name', '')
      if index(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'], name) >= 0
        touched_files = true
      endif
      Info('● ' .. util.ToolSummary(name, get(c, 'input', {})))
      last_kind = 'tool'
    elseif ct == 'text' && !streamed
      # CLI without partial messages: render the whole block at once.
      EnsureClaudeHeader()
      AppendText(get(c, 'text', ''))
      CloseText()
    endif
  endfor
enddef

def OnToolResults(ev: dict<any>)
  var content = get(get(ev, 'message', {}), 'content', [])
  if type(content) != v:t_list || IsSubagent(ev)
    return
  endif
  for c in content
    if type(c) == v:t_dict && get(c, 'type', '') == 'tool_result' && get(c, 'is_error', false)
      var body = get(c, 'content', '')
      var text = type(body) == v:t_string ? body : (type(body) == v:t_list && !empty(body) ? get(body[0], 'text', '') : '')
      if text !~ 'permission\|denied\|requested permissions'
        Info('  ⎿ ' .. strcharpart(substitute(text, '\n.*', '', ''), 0, 100))
        last_kind = 'tool'
      endif
    endif
  endfor
  status_text = 'thinking'
  UpdateLive()
enddef

def OnResult(ev: dict<any>)
  var secs = printf('%.1fs', reltimefloat(reltime(turn_start)))
  if get(ev, 'is_error', false) || get(ev, 'subtype', 'success') != 'success'
    var r = get(ev, 'result', '')
    Info('✖ ' .. (type(r) == v:t_string && r != '' ? r : get(ev, 'subtype', 'error')))
  endif
  var denials = get(ev, 'permission_denials', [])
  var footer = '── ' .. secs
  var cost = get(ev, 'total_cost_usd', 0.0)
  if Opt('show_cost', false) && type(cost) == v:t_float
    footer ..= printf(' · $%.4f', cost)
  endif
  if type(denials) == v:t_list && !empty(denials)
    var what = map(copy(denials), (_, d) => util.ToolSummary(get(d, 'tool_name', ''), get(d, 'tool_input', {})))
    Info('! Needs permission: ' .. join(uniq(sort(what)), ', '))
  endif
  Info(footer)
  FinishTurn()
  if type(denials) == v:t_list && !empty(denials)
    AskPermission(denials)
  endif
enddef

# ---------------------------------------------------------------- permissions

def AskPermission(denials: list<dict<any>>)
  var rules = uniq(sort(map(copy(denials), (_, d) => util.DenialRule(d))))
  var what = uniq(sort(map(copy(denials), (_, d) => util.ToolSummary(get(d, 'tool_name', ''), get(d, 'tool_input', {})))))
  var choices = ['Allow for this session', 'Allow all file edits (acceptEdits mode)', 'Deny']
  var opts = {
    title: ' Claude wants to: ' .. join(what, ', ') .. ' ',
    padding: [0, 1, 0, 1], border: [],
    callback: (_, choice) => {
      OnPermissionChoice(choice, rules)
    },
  }
  if exists('*popup_menu') && !Opt('no_popups', false)
    popup_menu(choices, opts)
  else
    OnPermissionChoice(inputlist(['Claude wants to: ' .. join(what, ', ')]
      + map(copy(choices), (i, c) => (i + 1) .. '. ' .. c)), rules)
  endif
enddef

def OnPermissionChoice(choice: number, rules: list<string>)
  if choice == 1
    session_allowed = uniq(sort(session_allowed + rules))
    Info('✓ Allowed for this session: ' .. join(rules, ', '))
  elseif choice == 2
    perm_mode = 'acceptEdits'
    Info('✓ Switched to acceptEdits mode')
  else
    Info('✗ Denied')
    return
  endif
  SendRaw('Permission granted. Please retry what was blocked and continue.')
enddef

# ---------------------------------------------------------------- sending

def EditorContext(): string
  if !Opt('include_context', true)
    return ''
  endif
  var ctx = get(g:, 'claude_last_ctx', {})
  if empty(ctx) || get(ctx, 'file', '') == ''
    return ''
  endif
  return "\n\n" .. util.CTX_MARKER .. 'The user is looking at ' .. util.RelPath(ctx.file)
    .. ' (cursor on line ' .. ctx.line .. ' of ' .. ctx.total .. ') in Vim.</editor-context>'
enddef

def MentionLines(path: string, l1: number, l2: number): list<string>
  var b = bufnr(path)
  if b > 0 && bufloaded(b)
    return getbufline(b, l1, l2)
  endif
  if filereadable(path)
    return readfile(path, '', l2)[l1 - 1 :]
  endif
  return []
enddef

export def Send(text: string, display: string = '')
  if trim(text) == ''
    return
  endif
  if busy
    Warn('Claude is still responding — press Ctrl-C in the panel to stop it')
    return
  endif
  EnsureChatBuf()
  if !IsOpen()
    Open(false)
  endif
  if empty(history) || history[-1] != text
    add(history, text)
  endif
  hist_idx = -1
  file_cache = []
  RenderUser(display != '' ? display : text)
  var mentions = util.FindRangeMentions(text)
  for m in mentions
    Info('↳ attached ' .. util.RangeLabel(m.path, m.l1, m.l2))
  endfor
  # Jump every chat window to the bottom when the user sends.
  for w in ChatWins()
    win_execute(w, 'normal! G')
  endfor
  if !SendRaw(util.ExpandMentions(text, MentionLines) .. EditorContext())
    Info('✖ Not sent')
  endif
enddef

export def SubmitInput()
  var text = join(getbufline(input_buf, 1, '$'), "\n")
  if trim(text) == ''
    return
  endif
  if busy
    Warn('Claude is still responding — Ctrl-C to stop')
    return
  endif
  deletebufline(input_buf, 1, '$')
  Send(trim(text, "\n"))
enddef

def History(dir: number)
  if empty(history)
    return
  endif
  hist_idx = hist_idx < 0 ? (dir < 0 ? len(history) - 1 : -1) : hist_idx + dir
  if hist_idx < 0 || hist_idx >= len(history)
    hist_idx = -1
    deletebufline(input_buf, 1, '$')
    return
  endif
  deletebufline(input_buf, 1, '$')
  setbufline(input_buf, 1, split(history[hist_idx], "\n", 1))
  normal! G$
enddef

export def Stop()
  if !busy
    return
  endif
  # StopProcess silences the process callbacks, so report it here.
  StopProcess()
  Info('■ Interrupted')
  FinishTurn()
enddef

# ---------------------------------------------------------------- commands

# :Claude [text] with an optional range.
export def Command(args: string, count: number, l1: number, l2: number)
  if count > 0
    if args == ''
      AddToInput(l1, l2)
    else
      SendSelection(l1, l2, args)
    endif
  elseif args != ''
    Send(args)
  else
    Open()
  endif
enddef

def SendSelection(l1: number, l2: number, question: string)
  var path = expand('%:p')
  var text = util.ExplainPrompt(path, &filetype, l1, l2, getline(l1, l2), question)
  Send(text)
enddef

export def Explain(l1: number, l2: number)
  SendSelection(l1, l2, '')
enddef

export def AddToInput(l1: number, l2: number)
  var path = expand('%:p')
  if path == ''
    # Unnamed buffer: there is no path to mention, so paste the code itself.
    var code = util.CodeBlock(getline(l1, l2), &filetype)
    Open()
    appendbufline(input_buf, '$', code)
    return
  endif
  var mention = util.Mention(path, l1, l2, line('$'))
  Open()
  var last = getbufline(input_buf, '$')[0]
  setbufline(input_buf, '$', last .. (last =~ '\S$' ? ' ' : '') .. mention .. ' ')
  normal! G$
  startinsert!
enddef

export def NewChat()
  StopProcess()
  SetBusy(false)
  session_id = ''
  model_name = ''
  session_allowed = []
  Clear()
  echo 'claude: new conversation'
enddef

export def SetModel(name: string)
  if name == ''
    var choices = ['default', 'opus', 'sonnet', 'haiku']
    popup_menu(choices, {title: ' Claude model ', padding: [0, 1, 0, 1], border: [],
      callback: (_, i) => {
        if i > 0
          SetModel(choices[i - 1])
        endif
      }})
    return
  endif
  model = name == 'default' ? '' : name
  model_name = ''
  if Running() && !busy
    StopProcess()
  endif
  echo 'claude: model ' .. (model == '' ? 'default' : model) .. ' (applies to the next message)'
  redrawstatus!
enddef

export def SetMode(name: string)
  if name == ''
    popup_menu(MODES, {title: ' Permission mode ', padding: [0, 1, 0, 1], border: [],
      callback: (_, i) => {
        if i > 0
          SetMode(MODES[i - 1])
        endif
      }})
    return
  endif
  if index(MODES, name) < 0
    Warn('unknown mode ' .. name .. ' (' .. join(MODES, ', ') .. ')')
    return
  endif
  perm_mode = name
  if Running() && !busy
    StopProcess()
  endif
  echo 'claude: permission mode ' .. name
  redrawstatus!
enddef

export def CompleteModes(..._): string
  return join(MODES, "\n")
enddef

export def CompleteModels(..._): string
  return join(['default', 'opus', 'sonnet', 'haiku'], "\n")
enddef

export def Resume()
  var dir = expand('~/.claude/projects/') .. util.ProjectKey(getcwd())
  var files = glob(dir .. '/*.jsonl', false, true)
  sort(files, (a, b) => getftime(b) - getftime(a))
  var items: list<dict<any>> = []
  for f in files[: 29]
    var title = util.TranscriptTitle(readfile(f, '', 400))
    if title != ''
      add(items, {file: f, title: strftime('%m-%d %H:%M', getftime(f)) .. '  ' .. title})
    endif
  endfor
  if empty(items)
    Warn('no previous conversations for ' .. getcwd())
    return
  endif
  popup_menu(mapnew(items, (_, it) => it.title), {
    title: ' Resume conversation ', padding: [0, 1, 0, 1], border: [], maxheight: 20,
    callback: (_, i) => {
      if i > 0
        LoadSession(items[i - 1].file)
      endif
    }})
enddef

def LoadSession(file: string)
  NewChat()
  session_id = fnamemodify(file, ':t:r')
  Open(false)
  for e in util.ParseTranscript(readfile(file))
    if e.role == 'user'
      RenderUser(e.text, '')
    elseif e.kind == 'tool'
      EnsureClaudeHeader('')
      Info('● ' .. e.text)
      last_kind = 'tool'
    else
      EnsureClaudeHeader('')
      AppendText(e.text)
      CloseText()
    endif
  endfor
  Info('── resumed session ' .. session_id)
  for w in ChatWins()
    win_execute(w, 'normal! G')
  endfor
enddef

def YankCodeBlock()
  var r = util.CodeBlockAt(getline(1, '$'), line('.'))
  if empty(r)
    Warn('cursor is not inside a code block')
    return
  endif
  var text = getline(r[0], r[1])
  setreg('"', text, 'l')
  if has('clipboard')
    silent! setreg('+', text, 'l')
  endif
  echo 'claude: yanked ' .. len(text) .. ' lines'
enddef

# ---------------------------------------------------------------- @mentions

def ProjectFiles(): list<string>
  if empty(file_cache)
    if executable('git')
      file_cache = systemlist('git ls-files --cached --others --exclude-standard 2>/dev/null')
      if v:shell_error != 0
        file_cache = []
      endif
    endif
    if empty(file_cache)
      file_cache = filter(glob('**/*', false, true), (_, f) => !isdirectory(f))
    endif
    file_cache = file_cache[: 20000]
  endif
  return file_cache
enddef

export def CompleteMention(findstart: number, base: string): any
  if findstart
    var before = strpart(getline('.'), 0, col('.') - 1)
    var at = match(before, '\%(^\|\s\)\zs@\S*$')
    if at < 0
      return -3
    endif
    return at + 1  # keep the '@' outside the completed text
  endif
  var files = ProjectFiles()
  var hits = base == '' ? files[: 199] : matchfuzzy(files, base)[: 199]
  return {words: hits, refresh: 'always'}
enddef

# Fuzzy @file menu, re-filtered on every keystroke. (Omni completion's
# refresh: 'always' does not re-query while typing, so drive complete().)
def MentionComplete()
  var before = strpart(getline('.'), 0, col('.') - 1)
  var m = matchstrpos(before, '\%(^\|\s\)\zs@\S*$')
  if m[1] < 0
    return
  endif
  var base = strpart(m[0], 1)
  var files = ProjectFiles()
  complete(m[1] + 2, base == '' ? files[: 199] : matchfuzzy(files, base)[: 199])
enddef

# ---------------------------------------------------------------- tests

export def Busy(): bool
  return busy
enddef

export def Debug(): dict<any>
  return {chat_buf: chat_buf, input_buf: input_buf, busy: busy, session_id: session_id,
    args: BuildArgs(), allowed: session_allowed, mode: Mode()}
enddef
