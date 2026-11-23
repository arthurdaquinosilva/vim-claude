vim9script
# claude.vim — chat panel backed by a long-running `claude -p` process that
# speaks stream-json on stdin/stdout.

import autoload 'claude/util.vim'

const SPIN = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
const HDR_USER = '❯ You:'
const HDR_CLAUDE = '✻ Claude:'
const HDR_PAT = '^\%(❯ You\|✻ Claude\):$'
const INDENT = '  '         # message bodies are indented under their label
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
var session_allowed: list<string> = []   # --allowedTools rules ('retry' prompts only)
var prompts: list<dict<any>> = []        # tool permission requests waiting for an answer
var prompt_popup = 0                     # popup showing prompts[0]
var known_commands: list<string> = []    # slash commands the CLI reported
var slash_descs: dict<string> = {}
var slash_descs_cwd = ''
var tool_calls: dict<dict<any>> = {}     # tool_use id -> {name, input}, until its result arrives
var mode_before_plan = 'default'
var mode_requests: dict<string> = {}     # set_permission_mode request id -> mode
var ctx_used = 0                         # tokens in the context window after the last reply
var ctx_window = 0
var session_cost = 0.0
var interrupting = false                 # an interrupt was sent, waiting for the turn to end
var interrupt_timer = 0

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

var fence_tags: dict<bool> = {}     # fence tags given a syntax region
var fence_fts: dict<bool> = {}      # filetypes whose syntax is included
var fence_pending: list<string> = []  # tags seen while the chat was hidden
var fence_n = 0

var history: list<string> = []
var hist_idx = -1
var hist_loaded = false
var hist_cwd = ''
var chat_cwd = ''                       # where the conversation runs; fixed until :ClaudeNew
var fork_next = false                   # start the next process with --fork-session
var shell_pending: list<dict<any>> = []  # "!cmd" results Claude has not been told about yet
var shell_job: job = null_job
var ext_keys = false                    # we asked the terminal for modified keys
var turns: list<dict<any>> = []         # sent messages: {text, time, uuid} for rewinding
var rewind_cbs: dict<func(dict<any>)> = {}
var queue: list<dict<string>> = []      # messages typed while Claude was busy
var file_cache: list<string> = []
var files_job: job = null_job
var files_gen = 0                       # bumps when the list is thrown away

# The directory the conversation works in. A :cd (or 'autochdir') after it
# started does not move Claude to another project in the middle of a chat.
def ChatDir(): string
  return chat_cwd != '' ? chat_cwd : getcwd()
enddef

def Opt(name: string, default: any): any
  return get(g:, 'claude_' .. name, default)
enddef

def Mode(): string
  return perm_mode != '' ? perm_mode : Opt('permission_mode', 'default')
enddef

def Model(): string
  return model != '' ? model : Opt('model', '')
enddef

# 'host' (default): the CLI asks us before each tool call and waits for the
# answer. 'retry': run without that, then re-send after a denial was allowed.
def HostPrompts(): bool
  return Opt('permission_prompt', 'host') != 'retry'
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
  for [kind, hl] in items({add: 'ClaudeDiffAdd', del: 'ClaudeDiffDel', ctx: 'ClaudeToolDim', out: 'ClaudeToolDim',
      todo: 'ClaudeToolDim', doing: 'ClaudeLive', done: 'ClaudeToolDone', err: 'ClaudeToolErr'})
    prop_type_add('claude_tool_' .. kind, {bufnr: chat_buf, highlight: hl})
  endfor

  nnoremap <buffer><silent> q <ScriptCmd>Close()<CR>
  nnoremap <buffer><silent> <C-c> <ScriptCmd>Stop()<CR>
  for key in ['i', 'a', 'I', 'A', 'o', 'O', '<CR>']
    execute 'nnoremap <buffer><silent> ' .. key .. ' <ScriptCmd>FocusInput(true)<CR>'
  endfor
  nnoremap <buffer><silent> ]] <ScriptCmd>search(HDR_PAT, 'W')<CR>
  nnoremap <buffer><silent> [[ <ScriptCmd>search(HDR_PAT, 'bW')<CR>
  nnoremap <buffer><silent> gy <ScriptCmd>YankCodeBlock()<CR>
  # Select part of a reply and press Enter to ask about it.
  xnoremap <buffer><silent> <CR> <Esc><ScriptCmd>QuoteSelection()<CR>

  augroup claude_chat
    autocmd! * <buffer>
    autocmd BufWinLeave <buffer> timer_start(0, (_) => CloseOrphanInput())
    # Syntax was (re)loaded: fence regions are gone, rebuild them.
    autocmd Syntax <buffer> ResetFenceSyntax()
  augroup END
enddef

def SetupChatWin()
  setlocal wrap linebreak breakindent nonumber norelativenumber nolist nospell
  # Wrapped list items line up with their text, not with the bullet.
  setlocal breakindentopt=list:-1
  &l:formatlistpat = '^\s*\%(\d\+[.)]\|[-*+]\)\s\+'
  setlocal signcolumn=no foldcolumn=0 colorcolumn= winfixwidth conceallevel=2
  setlocal foldmethod=expr foldlevel=99
  &l:foldexpr = "getline(v:lnum) =~# '" .. HDR_PAT .. "' ? '>1' : '1'"
  &l:statusline = '%!claude#StatusLine()'
  # No "@" filler when the last line doesn't fit (e.g. while the input grows).
  &l:fillchars = &g:fillchars .. ',lastline: '
  if !empty(fence_pending)
    var tags = fence_pending
    fence_pending = []
    AddFenceSyntax(tags)
  endif
enddef

# ---------------------------------------------------------------- code fences

# Highlight ```lang blocks with that language's own syntax, loading it on
# first use (no need to list languages in g:markdown_fenced_languages).
def AddFenceSyntax(tags: list<string>)
  var todo = filter(copy(tags), (_, t) => !has_key(fence_tags, t) && t =~ '^[A-Za-z0-9_+#.-]\+$')
  if empty(todo) || !Opt('fence_syntax', true)
    return
  endif
  var wins = ChatWins()
  if empty(wins)
    fence_pending = uniq(sort(fence_pending + todo))
    return
  endif
  for tag in todo
    fence_tags[tag] = true
    var ft = util.LangFiletype(tag)
    if ft == 'markdown' || ft !~ '^\w\+$' || empty(globpath(&runtimepath, 'syntax/' .. ft .. '.vim'))
      continue
    endif
    # (win_execute() runs these as Vim9 script, like the caller.)
    var cmds: list<string> = []
    if !has_key(fence_fts, ft)
      fence_fts[ft] = true
      cmds += ['unlet! b:current_syntax',
        'silent! syntax include @claudeLang_' .. ft .. ' syntax/' .. ft .. '.vim',
        'b:current_syntax = "claudechat"']
    endif
    fence_n += 1
    # containedin=ALL: some Markdown syntaxes (vim-polyglot) wrap paragraphs
    # in regions that only allow their own code block inside.
    add(cmds, printf('syntax region claudeFence%d matchgroup=claudeFenceDelim start=/%s/ end=/^\s*```\+\s*$/ keepend containedin=ALL contains=@claudeLang_%s',
      fence_n, util.FenceStart(tag), ft))
    win_execute(wins[0], cmds)
  endfor
enddef

def ResetFenceSyntax()
  fence_tags = {}
  fence_fts = {}
  if bufexists(chat_buf)
    AddFenceSyntax(util.FenceLangs(getbufline(chat_buf, 1, '$')))
  endif
enddef

def SetupInputBuf()
  DetachCompletion()
  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
  # A global 'textwidth' would hard-wrap your message while you type.
  setlocal textwidth=0 wrapmargin=0 formatoptions-=t formatoptions-=c
  setlocal filetype=claudeinput
  silent! file claude://input
  input_buf = bufnr()
  &l:omnifunc = 'claude#CompleteMention'

  setlocal completeopt=menuone,noinsert,popup
  # Enter picks the highlighted @file while the menu is open, otherwise sends.
  inoremap <buffer><silent><expr> <CR> pumvisible() ? "\<C-y> " : "\<Cmd>call claude#SubmitInput()\<CR>"
  inoremap <buffer><expr> <Tab> pumvisible() ? "\<C-n>" : "\<Tab>"
  inoremap <buffer><expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<Cmd>call claude#CycleMode()\<CR>"
  nnoremap <buffer><silent> <S-Tab> <ScriptCmd>CycleMode()<CR>
  # New lines: grow the window first, then insert (see MakeRoomForNewline).
  inoremap <buffer><silent> <S-CR> <ScriptCmd>MakeRoomForNewline()<CR><CR>
  inoremap <buffer><silent> <C-j> <ScriptCmd>MakeRoomForNewline()<CR><CR>
  nnoremap <buffer><silent><nowait> o <ScriptCmd>MakeRoomForNewline()<CR>o
  nnoremap <buffer><silent><nowait> O <ScriptCmd>MakeRoomForNewline()<CR>O
  nnoremap <buffer><silent> <CR> <ScriptCmd>SubmitInput()<CR>
  inoremap <buffer><silent> <C-c> <ScriptCmd>Stop()<CR>
  nnoremap <buffer><silent> <C-c> <ScriptCmd>Stop()<CR>
  nnoremap <buffer><silent> q <ScriptCmd>Close()<CR>
  var sk = Opt('history_search_key', '<C-r>')
  if sk != ''
    execute 'inoremap <buffer><silent> ' .. sk .. ' <ScriptCmd>SearchHistory()<CR>'
    execute 'nnoremap <buffer><silent> ' .. sk .. ' <ScriptCmd>SearchHistory()<CR>'
  endif
  inoremap <buffer><silent> <C-p> <ScriptCmd>History(-1)<CR>
  inoremap <buffer><silent> <C-n> <ScriptCmd>History(1)<CR>
  nnoremap <buffer><silent> <C-p> <ScriptCmd>History(-1)<CR>
  nnoremap <buffer><silent> <C-n> <ScriptCmd>History(1)<CR>

  prop_type_add('claude_placeholder', {bufnr: input_buf, highlight: 'ClaudePlaceholder'})
  prop_type_add('claude_border', {bufnr: input_buf, highlight: 'ClaudeRule'})

  augroup claude_input
    autocmd! * <buffer>
    # Shift-Enter: terminals only report it when asked, and only while typing here.
    autocmd BufEnter,WinEnter <buffer> ExtendedKeys(true)
    autocmd BufLeave,WinLeave <buffer> ExtendedKeys(false)
    # Refresh first: once the @file menu is open, refreshing is skipped.
    autocmd TextChanged,TextChangedI,BufWinEnter,CompleteDone <buffer> RefreshInput()
    autocmd TextChangedI,TextChangedP <buffer> MentionComplete()
    autocmd TextChangedI,TextChangedP <buffer> SlashComplete()
    autocmd WinResized * RefreshInput()
  augroup END
enddef

def SetupInputWin()
  # The "❯" lives in the sign column, so the cursor never lands on it.
  setlocal wrap linebreak nonumber norelativenumber nolist signcolumn=yes foldcolumn=0
  setlocal nocursorline nocursorcolumn colorcolumn= winfixheight winfixwidth
  &l:fillchars = &g:fillchars .. ',eob: '
  &l:wincolor = 'ClaudeInput'
  &l:statusline = '%!claude#InputStatusLine()'
  RefreshInput()
  ExtendedKeys(true)   # (BufEnter has already fired for this first entry)
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
  # Speakers: you in the prompt color, Claude in Claude's orange.
  highlight default ClaudeAssistant ctermfg=173 guifg=#d97757 cterm=bold gui=bold
  highlight default ClaudeLive ctermfg=173 guifg=#d97757
  highlight default link ClaudeTime Comment
  highlight default link ClaudeDiffAdd DiffAdd
  highlight default link ClaudeDiffDel DiffDelete
  highlight default link ClaudeToolDim Comment
  highlight default link ClaudeToolDone Comment
  highlight default link ClaudeToolErr WarningMsg
  highlight default link ClaudeUserText Comment
  var spc = hlget('Special', true)
  var sp0 = empty(spc) ? {} : spc[0]
  execute printf('highlight default ClaudeYou ctermfg=%s guifg=%s cterm=bold gui=bold',
    get(sp0, 'ctermfg', 'NONE'), get(sp0, 'guifg', 'NONE'))
  sign_define('ClaudePrompt', {text: '❯', texthl: 'ClaudePromptSign'})
  highlight default link ClaudeRule Comment
  LinkCodeHighlight()
  highlight default link ClaudeTitle Title
  highlight default link ClaudeBusy Special
  highlight default link ClaudeChip Comment
  highlight default link ClaudeKey Special
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
  sign_unplace('claude_input', {buffer: input_buf})
  sign_place(0, 'claude_input', 'ClaudePrompt', input_buf, {lnum: 1})
  if n == 1 && getbufline(input_buf, 1)[0] == ''
    var hint = busy ? 'Claude is working… (Enter queues your message)' : 'Ask Claude…'
    prop_add(1, 0, {bufnr: input_buf, type: 'claude_placeholder', text: hint, text_align: 'after'})
  endif
  # Bottom border: a rule drawn under the last line (after the sign column,
  # lined up with the top rule).
  var border = Opt('input_border', true)
  var wins = filter(InputWins(), (_, id) => win_id2tabwin(id)[0] == tabpagenr())
  if border
    prop_add(n, 0, {bufnr: input_buf, type: 'claude_border', text_align: 'below',
      text: repeat('─', (empty(wins) ? &columns : winwidth(wins[0])) - 2)})
  endif
  var lines = getbufline(input_buf, 1, '$')
  # Only resize an input box stacked right under the chat: in any other
  # layout (e.g. the chat was just :q'd) resizing would squash its neighbours.
  for w in filter(InputWins(), (_, id) => UnderChat(id))
    var rows = util.DisplayRows(lines, winwidth(w) - 2, 0) + (border ? 1 : 0)
    var h = min([max([rows + SpareRow(lines, border), Opt('input_height', 1) + (border ? 1 : 0)]), Opt('input_max_height', 12)])
    if winheight(w) != h
      win_execute(w, 'resize ' .. h)
    endif
    if rows <= h && line('w0', w) > 1
      # Everything fits: show it from the top instead of the scrolled view.
      win_execute(w, 'winrestview({topline: 1})')
    endif
  endfor
enddef

# With several lines and an empty last one (a fresh newline), Vim scrolls
# the lines above out of view unless the window has one row to spare, because
# of the border drawn under the last line. The row goes away once you type.
def SpareRow(lines: list<string>, border: bool): number
  return border && len(lines) > 1 && lines[-1] == '' ? 1 : 0
enddef

# Ask the terminal to tell Shift-Enter from Enter (modifyOtherKeys, the form
# tmux with extended-keys and xterm-like terminals understand) while the input
# box has the focus, and put things back when you leave it.
def ExtendedKeys(on: bool)
  if on == ext_keys
    return
  endif
  if on && (!Opt('extended_keys', true) || !util.WantsExtendedKeys(&term, &t_TI, has('gui_running')))
    return
  endif
  silent! echoraw(on ? "\<Esc>[>4;2m" : "\<Esc>[>4;m")
  ext_keys = on
enddef

augroup claude_extkeys
  autocmd!
  autocmd VimLeavePre,VimSuspend * ExtendedKeys(false)
  autocmd VimResume,FocusGained * if bufnr() == input_buf | ExtendedKeys(true) | endif
  autocmd FocusLost * ExtendedKeys(false)
augroup END

# A newline is inserted first and the window grows afterwards, so Vim scrolls
# the new line into view in the meantime and the lines above vanish until the
# next keystroke. Make room for the extra line before inserting it.
def MakeRoomForNewline()
  if !bufexists(input_buf) || pumvisible()
    return
  endif
  for w in filter(InputWins(), (_, id) => UnderChat(id))
    var lines = getbufline(input_buf, 1, '$') + ['']
    var border = Opt('input_border', true)
    var rows = util.DisplayRows(lines, winwidth(w) - 2, 0) + (border ? 1 : 0)
    var h = min([max([rows + SpareRow(lines, border), Opt('input_height', 1) + (border ? 1 : 0)]), Opt('input_max_height', 12)])
    if winheight(w) < h
      win_execute(w, 'resize ' .. h)
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

# Below the input: a quiet line with the file Claude is told about (or how
# to stop it while busy) on the left, and the model and mode on the right.
def ContextLabel(): string
  var pct = ctx_used * 100 / ctx_window
  return (pct >= 90 ? '⚠ ' : '') .. 'ctx ' .. (pct == 0 ? '<1' : string(pct)) .. '%'
    .. (Opt('show_cost', false) ? printf(' · $%.2f', session_cost) : '')
enddef

export def InputStatusLine(winid: number = 0): string
  # Left side, richest first. When busy: how to stop, and what is queued.
  var lefts: list<list<list<string>>> = []
  if busy
    var queued: list<list<string>> = empty(queue) ? [] : [[len(queue) .. ' queued', 'ClaudeChip']]
    lefts = [[['ctrl-c', 'ClaudeKey'], [' to stop', '']] + (empty(queued) ? [] : [[' · ', '']] + queued)]
    if !empty(queued)
      add(lefts, queued)
    endif
  else
    var ctx = get(g:, 'claude_last_ctx', {})
    if Opt('include_context', true) && !empty(ctx) && get(ctx, 'file', '') != ''
      lefts = [[[fnamemodify(ctx.file, ':t') .. ':' .. ctx.line, 'ClaudeChip']]]
    endif
  endif
  add(lefts, [])
  var width = winwidth(winid != 0 ? winid : g:statusline_winid)
  var m = substitute(model_name != '' ? model_name : Model(), '^claude-', '', '')
  var has_ctx = ctx_window > 0 && ctx_used > 0
  var mode_label = get(MODE_LABELS, Mode(), Mode())
  # From the most to the least informative; a narrow panel loses the model,
  # then the context, before the live status, and the hints go last.
  var variants = [
    (m == '' ? '' : m .. ' · ') .. (has_ctx ? ContextLabel() .. ' · ' : '') .. mode_label,
    (has_ctx ? ContextLabel() .. ' · ' : '') .. mode_label,
    mode_label,
  ]
  var live: list<list<string>> = busy
    ? [[SPIN[spin_i % len(SPIN)] .. ' ' .. get(LIVE_LABELS, status_text, status_text .. '…'), 'ClaudeBusy'], [' · ', '']]
    : []
  var W = (segs: list<list<string>>): number => reduce(segs, (acc, x) => acc + strwidth(x[0]), 0)
  var left: list<list<string>> = []
  var right: list<list<string>> = live + [[variants[-1], '']]
  var fits = false
  for l in lefts
    for v in variants
      var r = live + [[v, '']]
      if 2 + W(l) + (empty(l) ? 0 : 2) + W(r) + 1 <= width
        left = l
        right = r
        fits = true
        break
      endif
    endfor
    if fits
      break
    endif
  endfor
  return util.Bar(left, right, width, 'ClaudeRule', busy && fits && !empty(left))
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

# Speaker line ("❯ You:" / "✻ Claude:") with the time right-aligned,
# followed by a blank line.
def Header(name: string, time: string)
  CloseText()
  if bufexists(chat_buf) && !BufEmpty()
    EnsureBlank()
  endif
  Append([name, ''])
  if time != ''
    prop_add(LineCount() - 1, 0, {bufnr: chat_buf, type: 'claude_time', text: time, text_align: 'right'})
  endif
  last_kind = 'header'
enddef

def RenderUser(text: string, time: string = strftime('%H:%M'))
  Header(HDR_USER, time)
  turn_header = false
  var first = LineCount() + 1
  var lines = mapnew(split(text, "\n", 1), (_, l) => l == '' ? '' : INDENT .. l)
  Append(lines)
  AddFenceSyntax(util.FenceLangs(lines))
  # Your own message is dimmed, so Claude's replies stand out.
  for i in range(len(lines))
    if lines[i] != ''
      prop_add(first + i, len(INDENT) + 1, {bufnr: chat_buf, type: 'claude_user',
        length: strlen(lines[i]) - len(INDENT)})
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
    AddFenceSyntax(util.FenceLangs(getbufline(chat_buf, text_start, '$')))
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
    # Text starting on an empty line gets the body indent; blank lines stay empty.
    var last = getbufline(chat_buf, '$')[0]
    setbufline(chat_buf, '$', (last == '' && parts[0] != '' ? INDENT : last) .. parts[0])
    if len(parts) > 1
      appendbufline(chat_buf, '$', mapnew(parts[1 :], (_, p) => p == '' ? '' : INDENT .. p))
    endif
  })
  # A code fence opened: highlight it as it streams (complete lines only,
  # so a half-received tag like "```ja" is never used).
  if len(parts) > 1 && stridx(s, '`') >= 0
    AddFenceSyntax(util.FenceLangs(getbufline(chat_buf, text_start, LineCount() - 1)))
  endif
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
    live_lnum = LineCount() - 1
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

# Above the input: a plain rule, indented like the input text.
export def StatusLine(winid: number = 0): string
  var width = winwidth(winid != 0 ? winid : g:statusline_winid)
  return '%#ClaudeRule#  ' .. repeat('─', max([width - 2, 0]))
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
  if HostPrompts()
    args += ['--permission-prompt-tool', 'stdio']
  endif
  if Opt('checkpoints', true)
    # The CLI numbers every message and snapshots files before they change.
    args += ['--replay-user-messages']
  endif
  if session_id != ''
    args += ['--resume', session_id]
    if fork_next
      args += ['--fork-session']
    endif
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
  ClosePrompts()
  ClearInterrupt()
  var j = job
  job = null_job   # from now on it is gone as far as we are concerned
  job_stop(j, 'term')
  # Don't wait for it: its callbacks are silenced. Make sure it is gone soon.
  timer_start(1000, (_) => {
    if job_status(j) == 'run'
      job_stop(j, 'kill')
    endif
  })
enddef

# What the running process was started with; a change means a restart.
def Sig(): string
  return string([Model(), Mode(), session_allowed, Opt('extra_args', []), HostPrompts()])
enddef

def EnsureProcess(): bool
  var cmd = Opt('cmd', 'claude')
  var exe = type(cmd) == v:t_list ? cmd[0] : cmd
  if !executable(exe)
    Warn('`' .. exe .. '` not found. Install Claude Code or set g:claude_cmd.')
    return false
  endif
  var sig = Sig()
  if Running() && sig == proc_sig
    return true
  endif
  StopProcess()
  gen += 1
  var g = gen
  if chat_cwd == ''
    chat_cwd = getcwd()
  endif
  stderr_tail = []
  job = job_start(BuildArgs(), {
    out_mode: 'nl', err_mode: 'nl', noblock: true, cwd: ChatDir(),
    env: Opt('checkpoints', true) ? {CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING: '1'} : {},
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
      # Vim may report the exit before the last lines of output have been
      # delivered; let them arrive (a final "result" ends the turn quietly).
      timer_start(50, (_) => {
        if g == gen
          OnExit(code)
        endif
      })
    },
  })
  if job_status(job) != 'run'
    Warn('failed to start ' .. exe)
    return false
  endif
  proc_sig = sig
  fork_next = false
  return true
enddef

def AddStderr(msg: string)
  DebugLog('err', msg)
  add(stderr_tail, msg)
  if len(stderr_tail) > 20
    remove(stderr_tail, 0)
  endif
enddef

def OnExit(code: number)
  ClosePrompts()
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
  ClearInterrupt()
  tool_calls = {}
  SetBusy(false)
  if !empty(queue)
    timer_start(0, (_) => DrainQueue())
  endif
  if touched_files
    touched_files = false
    ReloadChanged()
  endif
enddef

# Reload files changed on disk; buffers with unsaved changes still prompt.
def ReloadChanged()
  var ar = &autoread
  set autoread
  silent! checktime
  &autoread = ar
enddef

def SendRaw(payload: any): bool
  if !EnsureProcess()
    return false
  endif
  var msg = {type: 'user', message: {role: 'user', content: payload}}
  # The process may have just died; start a fresh one once before giving up.
  if ch_status(job) != 'open'
    proc_sig = ''
    if !EnsureProcess() || ch_status(job) != 'open'
      Warn('could not reach the claude process')
      return false
    endif
  endif
  try
    ch_sendraw(job, json_encode(msg) .. "\n")
  catch
    Warn('could not reach the claude process: ' .. v:exception)
    return false
  endtry
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

def DebugLog(tag: string, line: string)
  var f = Opt('debug_log', '')
  if f != ''
    silent! writefile([strftime('%H:%M:%S ') .. tag .. ' ' .. line], expand(f), 'a')
  endif
enddef

def OnEvent(line: string)
  DebugLog('out', line)
  var ev: any
  try
    ev = json_decode(line)
  catch
    DebugLog('bad-json', line)
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
      var cmds = get(ev, 'slash_commands', [])
      if type(cmds) == v:t_list && !empty(cmds)
        known_commands = filter(copy(cmds), (_, n) => type(n) == v:t_string && n !~ '^__')
      endif
    elseif get(ev, 'subtype', '') == 'status'
      var st = get(ev, 'status', '')
      if type(st) == v:t_string && st != '' && busy
        status_text = st
        UpdateLive()
      endif
    elseif get(ev, 'subtype', '') == 'compact_boundary'
      var meta = get(ev, 'compact_metadata', {})
      var Tok = (n: any): string => type(n) == v:t_number ? printf('%.1fk', n / 1000.0) : '?'
      Info('── conversation compacted (' .. Tok(get(meta, 'pre_tokens', 0)) .. ' → '
        .. Tok(get(meta, 'post_tokens', 0)) .. ' tokens)')
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
    if get(ev, 'isReplay', false)
      NoteReplay(ev)
    else
      OnToolResults(ev)
    endif
  elseif t == 'result'
    OnResult(ev)
  elseif t == 'rate_limit_event'
    OnRateLimit(ev)
  elseif t == 'control_response'
    OnControlResponse(ev)
  elseif t == 'control_request'
    OnControlRequest(ev)
  elseif t == 'control_cancel_request'
    CancelPrompt(get(ev, 'request_id', ''))
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
      var tid = get(c, 'id', '')
      if tid != ''
        tool_calls[tid] = {name: name, input: get(c, 'input', {})}
        if name == 'TodoWrite' && Opt('tool_details', true)
          ToolDetail(util.ToolResult(name, get(c, 'input', {}), '', {}))
        endif
      endif
    elseif ct == 'text' && !streamed
      # CLI without partial messages: render the whole block at once.
      EnsureClaudeHeader()
      AppendText(get(c, 'text', ''))
      CloseText()
    endif
  endfor
enddef

# Lines under a tool call: "⎿ first line" and indented continuations, each
# highlighted by its kind (diff added/removed, dim output, errors...).
def ToolDetail(items: list<dict<any>>)
  if empty(items) || !bufexists(chat_buf)
    return
  endif
  CloseText()
  if last_kind == 'text' || last_kind == 'user'
    EnsureBlank()
  endif
  var first_prefix = '    ⎿ '
  var rest_prefix = '      '
  var start = LineCount() + (BufEmpty() ? 0 : 1)
  Append(mapnew(items, (i, it) => (i == 0 ? first_prefix : rest_prefix) .. it.text))
  for i in range(len(items))
    if items[i].text != ''
      prop_add(start + i, strlen(i == 0 ? first_prefix : rest_prefix) + 1,
        {bufnr: chat_buf, type: 'claude_tool_' .. items[i].kind, length: strlen(items[i].text)})
    endif
  endfor
  last_kind = 'tool'
enddef

def OnToolResults(ev: dict<any>)
  var content = get(get(ev, 'message', {}), 'content', [])
  if type(content) != v:t_list || IsSubagent(ev)
    return
  endif
  var top = get(ev, 'tool_use_result', {})
  for c in content
    if type(c) != v:t_dict || get(c, 'type', '') != 'tool_result'
      continue
    endif
    var tid = get(c, 'tool_use_id', '')
    var call = get(tool_calls, tid, {})
    if has_key(tool_calls, tid)
      remove(tool_calls, tid)
    endif
    var text = util.ResultText(get(c, 'content', ''))
    if get(c, 'is_error', false)
      if text !~ 'permission\|denied\|requested permissions\|Request interrupted'
        ToolDetail([{text: strcharpart(substitute(text, '\n.*', '', ''), 0, 100), kind: 'err'}])
      endif
    elseif !empty(call) && call.name != 'TodoWrite' && Opt('tool_details', true)
      ToolDetail(util.ToolResult(call.name, call.input, get(c, 'content', ''), top, Opt('tool_lines', 12)))
    endif
  endfor
  status_text = 'thinking'
  UpdateLive()
enddef

# The CLI reports how close you are to a usage limit; say so when a reply is
# held back, and (once) when a window is nearly used up.
var rate_warned: dict<bool> = {}
def OnRateLimit(ev: dict<any>)
  var info = get(ev, 'rate_limit_info', {})
  if type(info) != v:t_dict
    return
  endif
  var status = get(info, 'status', 'allowed')
  var kind = substitute(get(info, 'rateLimitType', 'usage'), '_', ' ', 'g')
  var resets = get(info, 'resetsAt', 0)
  var when = type(resets) == v:t_number && resets > 0 ? ', resets ' .. strftime('%H:%M', resets) : ''
  if status == 'rejected'
    Info('✖ Usage limit reached (' .. kind .. when .. ')')
  elseif status != 'allowed' && !has_key(rate_warned, kind .. status)
    rate_warned[kind .. status] = true
    Info('! Close to your ' .. kind .. ' limit' .. when)
  endif
enddef

# Context window fill after this reply, and the session cost so far.
def NoteUsage(ev: dict<any>)
  var u = get(ev, 'usage', {})
  if type(u) == v:t_dict
    # The last API call of the turn holds what the next one will start from.
    var its = get(u, 'iterations', [])
    var last = type(its) == v:t_list && !empty(its) && type(its[-1]) == v:t_dict ? its[-1] : u
    var used = get(last, 'input_tokens', 0) + get(last, 'cache_read_input_tokens', 0)
      + get(last, 'cache_creation_input_tokens', 0)
    if used > 0
      ctx_used = used
    endif
  endif
  var mu = get(ev, 'modelUsage', {})
  if type(mu) == v:t_dict
    for [_, m] in items(mu)
      if type(m) == v:t_dict && get(m, 'contextWindow', 0) > 0
        ctx_window = m.contextWindow
      endif
    endfor
  endif
  var cost = get(ev, 'total_cost_usd', v:null)
  if type(cost) == v:t_float || type(cost) == v:t_number
    session_cost = cost + 0.0
  endif
enddef

def OnResult(ev: dict<any>)
  var secs = printf('%.1fs', reltimefloat(reltime(turn_start)))
  if interrupting
    # The turn we interrupted has ended: that is not an error.
    Info('■ Interrupted')
    FinishTurn()
    return
  endif
  if get(ev, 'is_error', false) || get(ev, 'subtype', 'success') != 'success'
    var r = get(ev, 'result', '')
    Info('✖ ' .. (type(r) == v:t_string && r != '' ? r : get(ev, 'subtype', 'error')))
  endif
  NoteUsage(ev)
  var denials = get(ev, 'permission_denials', [])
  if HostPrompts()
    # Denials were already answered one by one, as they came up.
    denials = []
  endif
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
  if ctx_window > 0 && ctx_used * 100 / ctx_window >= 85
    Info('! Context is ' .. (ctx_used * 100 / ctx_window) .. '% full: /compact frees space, /clear starts over')
  endif
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

# ---- synchronous prompts: the CLI sends a request and waits for our answer

# Answers to what we asked: the model in effect, or a mode that could not be
# applied in place (then the process is restarted with it on the next message).
def OnControlResponse(ev: dict<any>)
  var r = get(ev, 'response', {})
  var id = get(r, 'request_id', '')
  if has_key(rewind_cbs, id)
    var Cb = remove(rewind_cbs, id)
    Cb(r)
    return
  endif
  if has_key(mode_requests, id)
    remove(mode_requests, id)
    if get(r, 'subtype', '') == 'error'
      proc_sig = ''
    endif
  endif
  var body = get(r, 'response', {})
  if type(body) == v:t_dict && type(get(body, 'model', 0)) == v:t_string
    model_name = body.model
    redrawstatus!
  endif
enddef

def OnControlRequest(ev: dict<any>)
  var req = get(ev, 'request', {})
  var id = get(ev, 'request_id', '')
  if id == ''
    return
  endif
  if get(req, 'subtype', '') != 'can_use_tool'
    # Unknown request: answer so the CLI is never left waiting.
    SendControl({type: 'control_response', response: {subtype: 'error', request_id: id,
      error: 'unsupported request: ' .. get(req, 'subtype', '')}})
    return
  endif
  add(prompts, {id: id, tool: get(req, 'tool_name', ''), input: get(req, 'input', {}),
    suggestions: get(req, 'permission_suggestions', [])})
  if len(prompts) == 1
    ShowPrompt()
  endif
enddef

def Answer(id: string, response: dict<any>)
  SendControl({type: 'control_response', response: {subtype: 'success', request_id: id, response: response}})
enddef

def ShowPrompt()
  if empty(prompts)
    return
  endif
  var pr = prompts[0]
  SetBusy(true, 'waiting for you')
  if pr.tool == 'AskUserQuestion' && type(get(pr.input, 'questions', 0)) == v:t_list && !empty(pr.input.questions)
    AskQuestion(pr, 0, {})
    return
  endif
  var plan = pr.tool == 'ExitPlanMode'
  var edit = util.IsEditTool(pr.tool)
  var summary = plan ? "Claude's plan" : util.ToolSummary(pr.tool, pr.input)
  var keys: list<list<string>>
  var lines: list<string>
  if plan
    keys = [['y', 'approve'], ['a', 'approve + auto-accept edits'], ['n', 'keep planning']]
    lines = split(get(pr.input, 'plan', ''), "\n", 1)
  else
    keys = [['y', 'allow'], ['a', 'always this session']]
    if edit
      add(keys, ['e', 'accept all edits'])
    endif
    add(keys, ['n', 'deny'])
    lines = util.PermissionPreview(pr.tool, pr.input)
  endif
  var more = len(prompts) > 1 ? '  (+' .. (len(prompts) - 1) .. ' more waiting)' : ''
  var footer = join(map(copy(keys), (_, k) => '[' .. k[0] .. '] ' .. k[1]), '   ') .. more
  if !exists('*popup_create') || Opt('no_popups', false)
    var pick = inputlist(['Claude wants to: ' .. summary] + map(copy(keys), (i, k) => (i + 1) .. '. ' .. k[1]))
    HandlePromptKey(pick >= 1 && pick <= len(keys) ? keys[pick - 1][0] : 'n')
    return
  endif
  var names = map(copy(keys), (_, kk) => kk[0])
  prompt_popup = popup_create(lines + (empty(lines) ? [] : ['']) + [footer], {
    title: ' ' .. summary .. ' ',
    padding: [0, 1, 0, 1], border: [], pos: 'center', zindex: 200,
    minwidth: 40, maxwidth: float2nr(&columns * 0.85), maxheight: &lines - 6,
    wrap: true, mapping: false, drag: false, scrollbar: true,
    filter: (id, key) => {
      if ScrollKey(id, key)
        return true
      endif
      var k = tolower(key)
      if k == "\<Esc>" || k == "\<C-c>"
        k = 'n'
      elseif str2nr(k) >= 1 && str2nr(k) <= len(names) && k =~ '^\d$'
        k = names[str2nr(k) - 1]
      endif
      if index(names, k) >= 0
        popup_close(id)
        HandlePromptKey(k)
      endif
      return true  # modal: swallow everything else
    },
  })
  win_execute(prompt_popup, ['call matchadd("DiffAdd", "^+ .*")', 'call matchadd("DiffDelete", "^- .*")',
    'call matchadd("Comment", "^#.*")', 'call matchadd("Title", "^\\[.\\] .*")'])
enddef

# j/k, arrows, Ctrl-D/U and the page keys scroll a long popup.
def ScrollKey(id: number, key: string): bool
  var delta = 0
  if key == 'j' || key == "\<Down>"
    delta = 1
  elseif key == 'k' || key == "\<Up>"
    delta = -1
  elseif key == "\<C-d>" || key == "\<PageDown>"
    delta = 8
  elseif key == "\<C-u>" || key == "\<PageUp>"
    delta = -8
  else
    return false
  endif
  var pos = popup_getpos(id)
  popup_setoptions(id, {firstline: max([1, pos.firstline + delta])})
  return true
enddef

# One question of an AskUserQuestion call: pick an option by number, "o" for
# your own answer; with multiSelect, numbers toggle and Enter confirms.
def AskQuestion(pr: dict<any>, qi: number, answers: dict<any>)
  var q = pr.input.questions[qi]
  var opts = get(q, 'options', [])
  var multi = get(q, 'multiSelect', false)
  var chosen: list<number> = []
  var nq = len(pr.input.questions)
  var Lines = (): list<string> => {
    var l: list<string> = []
    for i in range(len(opts))
      var o = opts[i]
      var mark = multi ? (index(chosen, i) >= 0 ? '[x] ' : '[ ] ') : ''
      add(l, (i + 1) .. '. ' .. mark .. get(o, 'label', ''))
      if get(o, 'description', '') != ''
        add(l, '     ' .. o.description)
      endif
    endfor
    add(l, '')
    add(l, (multi ? '[1-' .. len(opts) .. '] toggle  [Enter] done  ' : '[1-' .. len(opts) .. '] choose  ') .. '[o] other  [Esc] skip')
    return l
  }
  var title = ' ' .. get(q, 'header', 'Question') .. (nq > 1 ? ' (' .. (qi + 1) .. '/' .. nq .. ')' : '') .. ' '
  var Finish = (value: string) => {
    var a = copy(answers)
    a[q.question] = value
    if qi + 1 < nq
      AskQuestion(pr, qi + 1, a)
    else
      var pr0 = remove(prompts, 0)
      prompt_popup = 0
      Answer(pr0.id, {behavior: 'allow', updatedInput: {questions: pr.input.questions, answers: a}})
      Info('✓ Answered: ' .. join(mapnew(pr.input.questions, (_, qq) => get(a, qq.question, '')), ' · '))
      if empty(prompts)
        SetBusy(true, 'thinking')
      else
        ShowPrompt()
      endif
    endif
  }
  var Skip = () => {
    var pr0 = remove(prompts, 0)
    prompt_popup = 0
    Answer(pr0.id, {behavior: 'deny', message: 'The user chose not to answer.'})
    Info('✗ Skipped the question')
    if empty(prompts)
      SetBusy(true, 'thinking')
    else
      ShowPrompt()
    endif
  }
  if !exists('*popup_create') || Opt('no_popups', false)
    var pick = inputlist([q.question] + mapnew(opts, (i, o) => (i + 1) .. '. ' .. get(o, 'label', '')))
    if pick >= 1 && pick <= len(opts)
      Finish(opts[pick - 1].label)
    else
      Skip()
    endif
    return
  endif
  CloseSingle()
  prompt_popup = popup_create([q.question, ''] + Lines(), {
    title: title, padding: [0, 1, 0, 1], border: [], pos: 'center', zindex: 200,
    minwidth: 40, maxwidth: float2nr(&columns * 0.85), maxheight: &lines - 6,
    wrap: true, mapping: false, drag: false, scrollbar: true,
    filter: (id, key) => {
      if ScrollKey(id, key)
        return true
      endif
      if key == "\<Esc>" || key == "\<C-c>"
        popup_close(id)
        Skip()
      elseif key == 'o' || key == 'O'
        popup_close(id)
        var own = input(q.question .. ' ')
        redraw
        if trim(own) == ''
          Skip()
        else
          Finish(own)
        endif
      elseif key =~ '^[1-9]$' && str2nr(key) <= len(opts)
        var i = str2nr(key) - 1
        if multi
          var at = index(chosen, i)
          if at >= 0
            remove(chosen, at)
          else
            add(chosen, i)
          endif
          popup_settext(id, [q.question, ''] + Lines())
        else
          popup_close(id)
          Finish(opts[i].label)
        endif
      elseif multi && (key == "\<CR>" || key == "\<NL>") && !empty(chosen)
        popup_close(id)
        Finish(join(mapnew(sort(copy(chosen)), (_, i) => opts[i].label), ', '))
      endif
      return true
    },
  })
  win_execute(prompt_popup, ['call matchadd("Title", "^\\[.*\\] .*")', 'call matchadd("Comment", "^     .*")'])
enddef

def HandlePromptKey(key: string)
  if empty(prompts)
    return
  endif
  var pr = remove(prompts, 0)
  prompt_popup = 0
  var what = util.ToolSummary(pr.tool, pr.input)
  if pr.tool == 'ExitPlanMode'
    if key == 'n'
      Answer(pr.id, {behavior: 'deny', message: 'The user wants to keep planning. Revise the plan with their feedback.'})
      Info('✗ Plan not approved: keep planning')
    else
      var back = key == 'a' ? 'acceptEdits' : mode_before_plan
      perm_mode = back
      proc_sig = Sig()
      Answer(pr.id, {behavior: 'allow', updatedInput: pr.input,
        updatedPermissions: [{type: 'setMode', mode: back, destination: 'session'}]})
      Info('✓ Plan approved' .. (key == 'a' ? ' (auto-accepting edits)' : ''))
    endif
  elseif key == 'n'
    Answer(pr.id, {behavior: 'deny', message: 'The user denied this tool call.'})
    Info('✗ Denied: ' .. what)
  else
    var resp: dict<any> = {behavior: 'allow', updatedInput: pr.input}
    if key == 'a'
      resp.updatedPermissions = [{type: 'addRules', rules: [util.AllowRule(pr.tool, pr.input)],
        behavior: 'allow', destination: 'session'}]
      Info('✓ Allowed for this session: ' .. what)
    elseif key == 'e'
      resp.updatedPermissions = [{type: 'setMode', mode: 'acceptEdits', destination: 'session'}]
      perm_mode = 'acceptEdits'
      proc_sig = Sig()  # already applied in the running process: no restart
      Info('✓ Accepting all edits for this session')
    endif
    Answer(pr.id, resp)
  endif
  if empty(prompts)
    SetBusy(true, 'thinking')
  else
    ShowPrompt()
  endif
enddef

# The CLI withdrew a request (e.g. the tool call was aborted).
def CancelPrompt(id: string)
  var i = indexof(prompts, (_, p) => p.id == id)
  if i < 0
    return
  endif
  remove(prompts, i)
  if i == 0
    CloseSingle()
    if empty(prompts)
      SetBusy(true, 'thinking')
    else
      ShowPrompt()
    endif
  endif
enddef

def CloseSingle()
  if prompt_popup != 0
    popup_close(prompt_popup)
    prompt_popup = 0
  endif
enddef

# Drop every waiting request without answering (the process is going away).
def ClosePrompts()
  prompts = []
  CloseSingle()
enddef

# Answer every waiting request with a denial (we are interrupting).
def DenyPrompts(why: string)
  for pr in prompts
    Answer(pr.id, {behavior: 'deny', message: why, interrupt: true})
  endfor
  ClosePrompts()
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

def Remember(text: string)
  LoadHistory()
  if empty(history) || history[-1] != text
    add(history, text)
    SaveHistory(text)
  endif
  hist_idx = -1
enddef

def SlashNames(): list<string>
  return (empty(known_commands) ? util.BASIC_COMMANDS : known_commands) + util.LOCAL_COMMANDS
enddef

# Commands the CLI can't run without a terminal are done here; a command it
# doesn't know is refused before it reaches the model. True when handled.
def RunSlash(name: string, args: string, text: string): bool
  if index(util.LOCAL_COMMANDS, name) < 0
    if !empty(known_commands) && index(known_commands, name) < 0
      Warn('unknown command /' .. name .. ' (type / to list them; start with a space to send it as text)')
      if bufexists(input_buf)
        setbufline(input_buf, 1, split(text, "\n", 1))
        RefreshInput()
      endif
      return true
    endif
    return false
  endif
  Remember(text)
  if name == 'clear' || name == 'new'
    NewChat()
  elseif name == 'model'
    SetModel(args)
  elseif name == 'permissions' || name == 'mode'
    SetMode(args)
  elseif name == 'resume'
    Resume()
  elseif name == 'rewind'
    Rewind()
  elseif name == 'continue'
    Continue()
  elseif name == 'fork'
    Fork()
  elseif name == 'exit' || name == 'quit'
    Close()
  elseif name == 'help'
    ShowHelp()
  endif
  return true
enddef

def ShowHelp()
  EnsureChatBuf()
  if !IsOpen()
    Open(false)
  endif
  var descs = SlashDescs()
  var names = uniq(sort(copy(SlashNames())))
  var lines = ['Type / in the input to complete a command.']
  for n in names
    if has_key(descs, n)
      add(lines, printf('/%-16s %s', n, descs[n]))
    endif
  endfor
  var rest = len(filter(copy(names), (_, n) => !has_key(descs, n) && n !~ '^__'))
  if rest > 0
    add(lines, '… and ' .. rest .. ' more (custom commands and skills): type / to browse')
  endif
  for l in lines
    Info(l)
  endfor
enddef

export def Send(text: string, display: string = '')
  if trim(text) == ''
    return
  endif
  if text =~ '^!\s*\S' && Opt('shell_mode', true)
    RunShell(trim(text[1 :]), text)
    return
  endif
  var slash = util.ParseSlash(text)
  if !empty(slash) && RunSlash(slash[0], slash[1], text)
    return
  endif
  if busy || job_status(shell_job) == 'run'
    # (A running "!command" counts: Claude should hear what it printed.)
    Enqueue(text, display)
    return
  endif
  EnsureChatBuf()
  if !IsOpen()
    Open(false)
  endif
  Remember(text)
  InvalidateFiles()
  RenderUser(display != '' ? display : text)
  add(turns, {text: text, time: strftime('%H:%M'), uuid: ''})
  var mentions = util.FindRangeMentions(text)
  for m in mentions
    Info('↳ attached ' .. util.RangeLabel(m.path, m.l1, m.l2))
  endfor
  # Jump every chat window to the bottom when the user sends.
  for w in ChatWins()
    win_execute(w, 'normal! G')
  endfor
  var images = empty(slash) ? ImageBlocks(text) : []
  # A command's arguments must stay exactly as typed: no editor context.
  var body = (empty(slash) ? ShellContext() : '') .. util.ExpandMentions(text, MentionLines) .. (empty(slash) ? EditorContext() : '')
  if !SendRaw(empty(images) ? body : [{type: 'text', text: body}] + images)
    Info('✖ Not sent')
    queue = []
  endif
enddef

export def SubmitInput()
  var text = join(getbufline(input_buf, 1, '$'), "\n")
  if trim(text) == ''
    return
  endif
  deletebufline(input_buf, 1, '$')
  Send(trim(text, "\n"))
enddef

# Typed while Claude is working: sent, in order, as soon as it is done.
def Enqueue(text: string, display: string)
  if len(queue) >= Opt('queue_limit', 10)
    Warn('too many queued messages (:ClaudeUnqueue clears them)')
    return
  endif
  add(queue, {text: text, display: display})
  Remember(text)
  EnsureChatBuf()
  Info('⧗ Queued: ' .. strcharpart(substitute(split(text, "\n")[0], '\s\+', ' ', 'g'), 0, 60))
  RefreshInput()
  redrawstatus!
enddef

export def Unqueue()
  var n = len(queue)
  queue = []
  RefreshInput()
  redrawstatus!
  echo 'claude: dropped ' .. n .. ' queued message' .. (n == 1 ? '' : 's')
enddef

def DrainQueue()
  if busy || empty(queue) || job_status(shell_job) == 'run'
    return
  endif
  var next = remove(queue, 0)
  Send(next.text, next.display)
enddef

# ---- input history, kept per project between Vim sessions

def HistoryFile(): string
  if !Opt('history', true)
    return ''
  endif
  var dir = Opt('history_dir', '')
  if dir == ''
    dir = (empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME) .. '/vim-claude'
  endif
  return expand(dir) .. '/' .. util.ProjectKey(ChatDir()) .. '.jsonl'
enddef

def LoadHistory()
  # Another project (after :cd) has its own history.
  if hist_loaded && hist_cwd == ChatDir()
    return
  endif
  hist_loaded = true
  hist_cwd = ChatDir()
  hist_idx = -1
  history = []
  var f = HistoryFile()
  if f == '' || !filereadable(f)
    return
  endif
  var entries: list<string> = []
  for l in readfile(f)
    try
      var t = json_decode(l)
      if type(t) == v:t_string && t != ''
        add(entries, t)
      endif
    catch
    endtry
  endfor
  if len(entries) > 1000
    # Keep the file from growing for ever.
    entries = entries[-500 :]
    silent! writefile(mapnew(entries, (_, e) => json_encode(e)), f)
  endif
  history = entries
enddef

def SaveHistory(text: string)
  var f = HistoryFile()
  if f == ''
    return
  endif
  silent! mkdir(fnamemodify(f, ':h'), 'p', 0o700)
  silent! writefile([json_encode(text)], f, 'a')
enddef

# Ctrl-R in the input box: type to filter earlier messages, <C-r>/<C-n> and
# <C-p> (or the arrows) to move, <CR> to take one, <Esc> to cancel.
def SearchHistory()
  LoadHistory()
  if empty(history) || !exists('*popup_create')
    return
  endif
  var all = reverse(copy(history))
  var query = ''
  var hits: list<string> = []
  var sel = 0
  var popup = 0
  var Draw = () => {
    hits = query == '' ? all[: 9] : matchfuzzy(all, query, {limit: 10})
    sel = min([sel, max([len(hits) - 1, 0])])
    var rows = mapnew(hits, (_, h) => {
      var first = substitute(split(h, "\n", 1)[0], '\s\+', ' ', 'g')
      return strcharpart(first, 0, 90) .. (stridx(h, "\n") >= 0 ? ' ↵' : '')
    })
    popup_settext(popup, ['(search) ' .. query .. '█', ''] + (empty(rows) ? ['  no match'] : rows))
    win_execute(popup, 'call cursor(' .. (sel + 3) .. ', 1)')
  }
  popup = popup_create([''], {
    title: ' History ', padding: [0, 1, 0, 1], border: [], pos: 'center', zindex: 200,
    minwidth: 50, maxwidth: float2nr(&columns * 0.85), cursorline: true, mapping: false,
    filter: (id, key) => {
      if key == "\<Esc>" || key == "\<C-c>"
        popup_close(id)
      elseif key == "\<CR>" || key == "\<NL>"
        popup_close(id)
        if !empty(hits)
          SetInputText(hits[sel])
        endif
      elseif key == "\<C-r>" || key == "\<C-n>" || key == "\<Down>"
        sel = min([sel + 1, len(hits) - 1])
        Draw()
      elseif key == "\<C-p>" || key == "\<Up>"
        sel = max([sel - 1, 0])
        Draw()
      elseif key == "\<BS>" || key == "\<C-h>"
        query = strcharpart(query, 0, max([strchars(query) - 1, 0]))
        sel = 0
        Draw()
      elseif key == "\<C-u>"
        query = ''
        sel = 0
        Draw()
      elseif strlen(key) >= 1 && key !~ '^\%x80' && char2nr(key) >= 32
        query ..= key
        sel = 0
        Draw()
      endif
      return true
    },
  })
  Draw()
enddef

def SetInputText(text: string)
  deletebufline(input_buf, 1, '$')
  setbufline(input_buf, 1, split(text, "\n", 1))
  RefreshInput()
  if win_getid() != get(InputWins(), 0, -1) && !empty(InputWins())
    win_gotoid(InputWins()[0])
  endif
  normal! G$
  startinsert!
enddef

def History(dir: number)
  LoadHistory()
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

# Ask Claude to stop the turn (the process and its prompt cache survive). If
# it doesn't end the turn in a few seconds, kill the process instead.
export def Stop()
  if !busy
    return
  endif
  if interrupting
    return
  endif
  if !Running()
    HardStop()
    return
  endif
  DenyPrompts('Interrupted by the user')
  interrupting = true
  SendControl({type: 'control_request', request_id: NewId(), request: {subtype: 'interrupt'}})
  interrupt_timer = timer_start(3000, (_) => {
    interrupt_timer = 0
    if interrupting
      HardStop()
    endif
  })
  SetBusy(true, 'stopping')
enddef

# StopProcess silences the process callbacks, so report it here.
def HardStop()
  StopProcess()
  Info('■ Interrupted')
  FinishTurn()
enddef

def ClearInterrupt()
  interrupting = false
  if interrupt_timer != 0
    timer_stop(interrupt_timer)
    interrupt_timer = 0
  endif
enddef

var id_n = 0
def NewId(): string
  id_n += 1
  return 'vim-' .. getpid() .. '-' .. id_n
enddef

def SendControl(msg: dict<any>)
  if !Running() || ch_status(job) != 'open'
    return
  endif
  try
    ch_sendraw(job, json_encode(msg) .. "\n")
    DebugLog('in', json_encode(msg))
  catch
    DebugLog('send-failed', v:exception)
  endtry
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
  if bufnr() == chat_buf
    # From the transcript: quote the text instead of mentioning claude://chat.
    if l1 == line("'<") && l2 == line("'>")
      QuoteSelection()
    else
      QuoteText(getline(l1, l2), l1, l2)
    endif
    return
  endif
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

# Put the visual selection made in the transcript into the input box, as a
# quote (or a fenced block when it is code), ready for a question.
export def QuoteSelection()
  var p1 = getpos("'<")
  var p2 = getpos("'>")
  if p1[1] > p2[1] || (p1[1] == p2[1] && p1[2] > p2[2])
    [p1, p2] = [p2, p1]
  endif
  var lines = util.Region(getbufline(chat_buf, p1[1], p2[1]), p1[2], p2[2], visualmode())
  # Drop the transcript's body indent, except where the selection started
  # mid-line (that text has no indent to drop).
  for i in range(len(lines))
    if (i > 0 || p1[2] <= len(INDENT) + 1 || visualmode() == 'V') && lines[i][: len(INDENT) - 1] == INDENT
      lines[i] = lines[i][len(INDENT) :]
    endif
  endfor
  QuoteText(lines, p1[1], p2[1])
enddef

def QuoteText(lines: list<string>, l1: number, l2: number)
  var fence = util.FenceAround(getbufline(chat_buf, 1, '$'), l1, l2)
  var quote = util.QuoteText(lines, get(fence, 'lang', ''), !empty(fence))
  if empty(quote)
    return
  endif
  FocusInput(false)
  # Keep what is already typed, separated by one blank line.
  var cur = getbufline(input_buf, 1, '$')
  while !empty(cur) && cur[-1] =~ '^\s*$'
    remove(cur, -1)
  endwhile
  var text = (empty(cur) ? [] : cur + ['']) + quote
  deletebufline(input_buf, 1, '$')
  setbufline(input_buf, 1, text)
  RefreshInput()
  normal! G$
  startinsert!
enddef

export def NewChat()
  StopProcess()
  SetBusy(false)
  ctx_used = 0
  session_cost = 0.0
  queue = []
  turns = []
  chat_cwd = ''
  fork_next = false
  shell_pending = []
  InvalidateFiles()
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
  if Running()
    # Applied in place: no restart, the prompt cache survives.
    SendControl({type: 'control_request', request_id: NewId(),
      request: model == '' ? {subtype: 'set_model'} : {subtype: 'set_model', model: model}})
    proc_sig = Sig()
  endif
  echo 'claude: model ' .. (model == '' ? 'default' : model)
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
  if name == 'bypassPermissions' && Mode() != name && Opt('confirm_bypass', true)
      && confirm('Bypass ALL permission checks? Claude will edit files and run commands without asking.',
        "&Yes\n&No", 2) != 1
    return
  endif
  if name == 'plan' && Mode() != 'plan'
    mode_before_plan = Mode()
  endif
  perm_mode = name
  if Running()
    var id = NewId()
    mode_requests[id] = name
    SendControl({type: 'control_request', request_id: id, request: {subtype: 'set_permission_mode', mode: name}})
    proc_sig = Sig()
  endif
  echo 'claude: permission mode ' .. name
  redrawstatus!
enddef

# Shift-Tab: default -> acceptEdits -> plan -> default, like the CLI.
export def CycleMode()
  var order = ['default', 'acceptEdits', 'plan']
  var i = index(order, Mode())
  SetMode(order[i < 0 ? 0 : (i + 1) % len(order)])
enddef

export def CompleteModes(..._): string
  return join(MODES, "\n")
enddef

export def CompleteModels(..._): string
  return join(['default', 'opus', 'sonnet', 'haiku'], "\n")
enddef

# Earlier conversations in this directory, newest first.
def ProjectSessions(max: number): list<dict<any>>
  var dir = expand('~/.claude/projects/') .. util.ProjectKey(getcwd())
  var files = glob(dir .. '/*.jsonl', false, true)
  sort(files, (a, b) => getftime(b) - getftime(a))
  var items: list<dict<any>> = []
  for f in files
    var title = util.TranscriptTitle(readfile(f, '', 400))
    if title != ''
      add(items, {file: f, title: strftime('%m-%d %H:%M', getftime(f)) .. '  ' .. title})
      if len(items) >= max
        break
      endif
    endif
  endfor
  return items
enddef

export def Resume()
  var items = ProjectSessions(30)
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

# Pick up where you left off: the most recent conversation in this directory.
export def Continue()
  var items = ProjectSessions(1)
  if empty(items)
    Warn('no previous conversations for ' .. getcwd())
    return
  endif
  LoadSession(items[0].file)
enddef

# Branch the conversation: the next message continues in a new session that
# starts with everything said so far; the original stays as it was.
export def Fork()
  if session_id == ''
    Warn('nothing to fork yet: send a message first')
    return
  endif
  if busy
    Warn('wait for the reply to finish (or stop it) before forking')
    return
  endif
  fork_next = true
  StopProcess()
  proc_sig = ''
  Info('⑂ Forked: your next message continues in a new session; the original is untouched')
enddef

def LoadSession(file: string)
  NewChat()
  chat_cwd = getcwd()
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
  # Drop the transcript's body indent (that of the opening fence).
  var indent = matchstr(getline(r[0] - 1), '^\s*')
  var text = mapnew(getline(r[0], r[1]), (_, l) => l[: len(indent) - 1] == indent ? l[len(indent) :] : l)
  setreg('"', text, 'l')
  if has('clipboard')
    silent! setreg('+', text, 'l')
  endif
  echo 'claude: yanked ' .. len(text) .. ' lines'
enddef

# ---------------------------------------------------------------- @mentions

def InvalidateFiles()
  file_cache = []
  files_gen += 1
  if job_status(files_job) == 'run'
    job_stop(files_job)
  endif
enddef

# Project files for @ completion. Listed in the background (a big repository
# must not freeze Vim); the menu shows what is known and refreshes when the
# list arrives.
def ProjectFiles(): list<string>
  if empty(file_cache) && job_status(files_job) != 'run'
    var tools: list<list<string>> = []
    if executable('git')
      add(tools, ['git', '-C', ChatDir(), 'ls-files', '--cached', '--others', '--exclude-standard'])
    endif
    if executable('find')
      add(tools, ['find', '.', '-type', 'f', '-not', '-path', '*/.git/*', '-not', '-path', '*/node_modules/*'])
    endif
    ListFiles(tools, 0)
  endif
  return file_cache
enddef

# Try the listing tools in turn (git, find, then Vim's own glob).
def ListFiles(tools: list<list<string>>, n: number)
  var dir = ChatDir()
  if n >= len(tools)
    SetFileCache(filter(mapnew(globpath(dir, '**/*', false, true), (_, f) => f[len(dir) + 1 :]),
      (_, f) => !isdirectory(dir .. '/' .. f)))
    return
  endif
  var found: list<string> = []
  var started = files_gen
  files_job = job_start(tools[n], {
    in_io: 'null', err_io: 'null', out_mode: 'nl', cwd: dir, noblock: true,
    out_cb: (_, l) => {
      if len(found) < 20000
        add(found, substitute(l, '^\./', '', ''))
      endif
    },
    exit_cb: (_, code) => {
      timer_start(20, (_) => {
        if started != files_gen
          return
        endif
        if code == 0 && !empty(found)
          SetFileCache(found)
        else
          ListFiles(tools, n + 1)
        endif
      })
    },
  })
enddef

def SetFileCache(files: list<string>)
  var all = files[: 20000]
  # Directories can be mentioned too: Claude lists what is in them.
  var dirs: dict<bool> = {}
  for f in all
    var d = fnamemodify(f, ':h')
    while d != '.' && d != '/' && !has_key(dirs, d)
      dirs[d] = true
      d = fnamemodify(d, ':h')
    endwhile
  endfor
  file_cache = all + mapnew(sort(keys(dirs)), (_, d) => d .. '/')
  # Still typing an @mention in the input box: show the real list now.
  if mode() =~ '^i' && bufnr() == input_buf
    MentionComplete()
  endif
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

# ---------------------------------------------------------------- !shell, images

# "!cmd" runs in your shell, in the conversation's directory; the output is
# shown here and handed to Claude with your next message.
def RunShell(cmd: string, text: string)
  if busy
    Warn('wait for Claude to finish before running a shell command')
    return
  endif
  if job_status(shell_job) == 'run'
    Warn('a shell command is still running')
    return
  endif
  EnsureChatBuf()
  if !IsOpen()
    Open(false)
  endif
  Remember(text)
  RenderUser(text)
  for w in ChatWins()
    win_execute(w, 'normal! G')
  endfor
  var lines: list<string> = []
  var started = reltime()
  shell_job = job_start(['sh', '-c', 'exec 2>&1; ' .. cmd], {
    in_io: 'null', out_mode: 'nl', err_mode: 'nl', cwd: ChatDir(), noblock: true,
    out_cb: (_, l) => {
      if len(lines) < 5000
        add(lines, l)
      endif
    },
    exit_cb: (_, code) => {
      # Let the rest of the output arrive first.
      timer_start(50, (_) => FinishShell(cmd, lines, code, started))
    },
  })
  if job_status(shell_job) == 'fail'
    Info('✖ could not run: ' .. cmd)
    return
  endif
  var j = shell_job
  timer_start(Opt('shell_timeout', 120) * 1000, (_) => {
    if job_status(j) == 'run'
      job_stop(j, 'kill')
    endif
  })
enddef

def FinishShell(cmd: string, lines: list<string>, code: number, started: list<any>)
  var out = join(lines, "\n")
  var items = util.ToolResult('Bash', {command: cmd}, '', {stdout: out, stderr: ''}, Opt('shell_lines', 25))
  ToolDetail(items)
  if code != 0
    Info('✖ exit ' .. code)
  endif
  add(shell_pending, {cmd: cmd, out: out, code: code})
  if !empty(queue)
    timer_start(0, (_) => DrainQueue())
  endif
enddef

# What the shell commands you ran since your last message printed.
def ShellContext(): string
  if empty(shell_pending)
    return ''
  endif
  var parts: list<string> = []
  for p in shell_pending
    var out = p.out
    var ls = split(out, "\n", 1)
    if len(ls) > 200
      out = join(ls[: 99], "\n") .. "\n[... " .. (len(ls) - 200) .. " lines omitted ...]\n" .. join(ls[-100 :], "\n")
    endif
    add(parts, 'I ran `' .. p.cmd .. '` in my terminal' .. (p.code != 0 ? ' (exit code ' .. p.code .. ')' : '')
      .. ":\n" .. util.FenceFor([out]) .. "\n" .. out .. "\n" .. util.FenceFor([out]))
  endfor
  shell_pending = []
  return join(parts, "\n\n") .. "\n\n"
enddef

# @pic.png in a message attaches the image itself, not just its name.
def ImageBlocks(text: string): list<dict<any>>
  var blocks: list<dict<any>> = []
  for m in util.FindImageMentions(text)
    var path = m.path =~ '^[/~]' ? expand(m.path) : ChatDir() .. '/' .. m.path
    if !filereadable(path)
      continue
    endif
    if getfsize(path) > 5 * 1024 * 1024
      Info('✖ not attached (over 5 MB): ' .. m.path)
      continue
    endif
    var data = system('base64 < ' .. shellescape(path) .. " | tr -d '\\n'")
    if v:shell_error != 0 || data == ''
      Info('✖ could not read image ' .. m.path)
      continue
    endif
    add(blocks, {type: 'image', source: {type: 'base64', media_type: m.media, data: data}})
    Info('↳ attached image ' .. m.path)
  endfor
  return blocks
enddef

# ---------------------------------------------------------------- rewind

# The CLI echoes each message with an id; remember it for the matching turn.
def NoteReplay(ev: dict<any>)
  var c = get(get(ev, 'message', {}), 'content', '')
  var text = type(c) == v:t_string ? c : (type(c) == v:t_list ? join(mapnew(c, (_, b) => type(b) == v:t_dict ? get(b, 'text', '') : ''), "\n") : '')
  var uuid = get(ev, 'uuid', '')
  if text == '' || uuid == ''
    return
  endif
  for t in turns
    if t.uuid == '' && stridx(text, t.text) >= 0
      t.uuid = uuid
      return
    endif
  endfor
enddef

# Restore the files to how they were before one of your messages. (The
# conversation itself stays as it is: the CLI can only rewind files.)
export def Rewind()
  if !Opt('checkpoints', true)
    Warn('checkpoints are off (g:claude_checkpoints)')
    return
  endif
  var avail = filter(copy(turns), (_, t) => t.uuid != '')
  if busy
    Warn('wait for the reply to finish (or stop it) before rewinding')
    return
  endif
  if empty(avail) || !Running()
    Warn('nothing to rewind yet: checkpoints cover messages sent in this session')
    return
  endif
  reverse(avail)
  var rows = mapnew(avail, (_, t) => t.time .. '  ' .. strcharpart(substitute(split(t.text, "\n")[0], '\s\+', ' ', 'g'), 0, 70))
  popup_menu(rows, {title: ' Restore files to before… ', padding: [0, 1, 0, 1], border: [], maxheight: 15,
    callback: (_, i) => {
      if i > 0
        PreviewRewind(avail[i - 1])
      endif
    }})
enddef

def PreviewRewind(t: dict<any>)
  var id = NewId()
  rewind_cbs[id] = (r: dict<any>) => {
    var res = get(r, 'response', {})
    if get(r, 'subtype', '') == 'error' || type(res) != v:t_dict || !get(res, 'canRewind', false)
      Warn('cannot rewind: ' .. (type(res) == v:t_dict && get(res, 'error', '') != '' ? res.error : get(r, 'error', 'no checkpoint for that message')))
      return
    endif
    var files = get(res, 'filesChanged', [])
    if empty(files)
      echo 'claude: no files changed since then'
      return
    endif
    ConfirmRewind(t, files, get(res, 'insertions', 0), get(res, 'deletions', 0))
  }
  SendControl({type: 'control_request', request_id: id,
    request: {subtype: 'rewind_files', user_message_id: t.uuid, dry_run: true}})
enddef

def ConfirmRewind(t: dict<any>, files: list<string>, ins: number, del: number)
  var lines = mapnew(files[: 11], (_, f) => '  ' .. util.RelPath(f))
  if len(files) > 12
    add(lines, '  … and ' .. (len(files) - 12) .. ' more')
  endif
  var head = 'Restore ' .. len(files) .. ' file' .. (len(files) == 1 ? '' : 's') .. ' to before "'
    .. strcharpart(substitute(split(t.text, "\n")[0], '\s\+', ' ', 'g'), 0, 40) .. '"?  (+' .. ins .. ' -' .. del .. ')'
  var Do = () => {
    var id = NewId()
    rewind_cbs[id] = (r: dict<any>) => {
      var res = get(r, 'response', {})
      if get(r, 'subtype', '') == 'error' || type(res) != v:t_dict || !get(res, 'canRewind', false)
        Warn('rewind failed: ' .. get(r, 'error', ''))
        return
      endif
      ReloadChanged()
      Info('↺ Restored ' .. len(files) .. ' file' .. (len(files) == 1 ? '' : 's') .. ' to before: '
        .. strcharpart(substitute(split(t.text, "\n")[0], '\s\+', ' ', 'g'), 0, 50))
    }
    SendControl({type: 'control_request', request_id: id, request: {subtype: 'rewind_files', user_message_id: t.uuid}})
  }
  if !exists('*popup_create') || Opt('no_popups', false)
    if confirm(head .. "\n" .. join(lines, "\n"), "&Yes\n&No", 2) == 1
      Do()
    endif
    return
  endif
  popup_create([head, ''] + lines + ['', 'The conversation is kept; only files change.', '', '[y] restore   [n] cancel'], {
    title: ' Rewind ', padding: [0, 1, 0, 1], border: [], pos: 'center', zindex: 200,
    minwidth: 40, maxwidth: float2nr(&columns * 0.85), maxheight: &lines - 6, wrap: true, mapping: false,
    filter: (id, key) => {
      if ScrollKey(id, key)
        return true
      endif
      if key == 'y' || key == 'Y'
        popup_close(id)
        Do()
      elseif key == 'n' || key == 'N' || key == "\<Esc>" || key == "\<C-c>"
        popup_close(id)
      endif
      return true
    },
  })
enddef

# ---------------------------------------------------------------- /commands

# Names and one-line descriptions: built-ins, then custom commands and skills
# found in .claude/ (project) and ~/.claude/.
def SlashDescs(): dict<string>
  var cwd = getcwd()
  if slash_descs_cwd != cwd
    slash_descs_cwd = cwd
    slash_descs = copy(util.COMMAND_DESCRIPTIONS)
    for dir in [cwd .. '/.claude/commands', expand('~/.claude/commands')]
      for f in glob(dir .. '/**/*.md', false, true)
        var d = util.Frontmatter(readfile(f, '', 15), 'description')
        if d != ''
          slash_descs[fnamemodify(f, ':t:r')] = d
        endif
      endfor
    endfor
    for dir in [cwd .. '/.claude/skills', expand('~/.claude/skills')]
      for f in glob(dir .. '/*/SKILL.md', false, true)
        var lines = readfile(f, '', 20)
        var name = util.Frontmatter(lines, 'name')
        var d = util.Frontmatter(lines, 'description')
        if d != ''
          slash_descs[name != '' ? name : fnamemodify(f, ':h:t')] = d
        endif
      endfor
    endfor
  endif
  return slash_descs
enddef

export def SlashCandidates(base: string): list<dict<any>>
  return util.SlashMatches(SlashNames(), SlashDescs(), base)
enddef

# "/" at the start of the message: complete command names as you type.
def SlashComplete()
  if line('.') != 1
    return
  endif
  var before = strpart(getline('.'), 0, col('.') - 1)
  if before !~ '^/[^ ]*$'
    return
  endif
  var items = SlashCandidates(strpart(before, 1))
  if empty(items) || (len(items) == 1 && items[0].word ==# before)
    # Nothing left to complete: close the menu so <CR> sends.
    complete(1, [])
    return
  endif
  complete(1, items)
enddef

# ---------------------------------------------------------------- health

# :ClaudeHealth — check that the environment can run the plugin.
export def Health()
  var rows: list<list<string>> = []
  # Optional things only warn; what the plugin cannot work without fails.
  def Row(ok: bool, what: string, detail: string = '', critical: bool = true)
    add(rows, [ok ? 'OK  ' : (critical ? 'FAIL' : 'WARN'), what .. (detail != '' ? ': ' .. detail : '')])
  enddef
  Row(true, 'Vim', string(v:versionlong))
  for feat in ['job', 'channel', 'timers', 'popupwin', 'textprop']
    Row(has(feat) == 1, '+' .. feat)
  endfor
  var cmd = Opt('cmd', 'claude')
  var exe = type(cmd) == v:t_list ? cmd[0] : cmd
  if executable(exe)
    var ver = trim(system((type(cmd) == v:t_list ? join(map(copy(cmd), (_, c) => shellescape(c)), ' ') : shellescape(cmd)) .. ' --version 2>&1'))
    Row(v:shell_error == 0, exe, ver)
  else
    Row(false, exe, 'not on $PATH (set g:claude_cmd)')
  endif
  Row(true, 'directory', ChatDir() .. (ChatDir() != getcwd() ? ' (the conversation started here; :ClaudeNew to follow :cd)' : ''))
  Row(isdirectory(expand('~/.claude')) == 1, '~/.claude', 'created by `claude` on first login', false)
  Row(executable('git') == 1, 'git', 'optional, used for @file completion', false)
  Row(true, 'process', Running() ? 'running, session ' .. (session_id == '' ? '(none yet)' : session_id) : 'not started (starts on first message)')
  if Opt('debug_log', '') != ''
    Row(true, 'g:claude_debug_log', expand(Opt('debug_log', '')))
  endif
  for [mark, text] in rows
    echohl (mark == 'OK  ' ? 'None' : (mark == 'WARN' ? 'WarningMsg' : 'ErrorMsg'))
    echo mark .. ' ' .. text
    echohl None
  endfor
enddef

# ---------------------------------------------------------------- tests

export def Busy(): bool
  return busy
enddef

export def Debug(): dict<any>
  return {chat_buf: chat_buf, input_buf: input_buf, busy: busy, session_id: session_id,
    args: BuildArgs(), allowed: session_allowed, mode: Mode()}
enddef
