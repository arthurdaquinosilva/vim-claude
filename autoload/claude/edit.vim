vim9script
# Inline edit: ask Claude to rewrite a range, then review the proposal in a
# diff tab (left: your buffer, right: proposal) and accept or reject it.

import autoload 'claude/util.vim'

var pending: dict<any> = {}   # the request in flight, if any
var notice = 0

def Opt(name: string, default: any): any
  return get(g:, 'claude_' .. name, default)
enddef

def Warn(msg: string)
  echohl WarningMsg | echomsg 'claude: ' .. msg | echohl None
enddef

def Notify(text: string)
  if notice != 0
    popup_close(notice)
  endif
  notice = popup_create(' ' .. text .. ' ', {line: 1, col: &columns, pos: 'topright',
    highlight: 'PmenuSel', zindex: 300})
enddef

def Unnotify()
  if notice != 0
    popup_close(notice)
    notice = 0
  endif
enddef

export def Start(l1: number, l2: number, instruction: string)
  if !empty(pending)
    Warn('an edit is already in progress (:ClaudeEditCancel to cancel)')
    return
  endif
  var instr = instruction
  if instr == ''
    instr = input('Claude, edit lines ' .. l1 .. '-' .. l2 .. ': ')
    redraw
    if trim(instr) == ''
      return
    endif
  endif
  var cmd = Opt('cmd', 'claude')
  var args = type(cmd) == v:t_list ? copy(cmd) : [cmd]
  if !executable(args[0])
    Warn('`' .. args[0] .. '` not found. Install Claude Code or set g:claude_cmd.')
    return
  endif
  args += ['-p', '--output-format', 'json', '--tools', '', '--no-session-persistence']
  var model = Opt('edit_model', Opt('model', ''))
  if model != ''
    args += ['--model', model]
  endif

  var all = getline(1, '$')
  var prompt = util.EditPrompt(expand('%:p'), &filetype, l1, l2, all, instr)
  var out: list<string> = []
  pending = {buf: bufnr(), l1: l1, l2: l2, orig: getline(l1, l2), ft: &filetype, instr: instr,
    tick: b:changedtick}
  pending.job = job_start(args, {
    in_mode: 'raw', out_mode: 'raw', err_mode: 'raw', noblock: true, cwd: getcwd(),
    out_cb: (_, chunk) => {
      add(out, chunk)
    },
    exit_cb: (_, code) => {
      # Let any buffered stdout arrive before reading it.
      timer_start(50, (_) => Finish(join(out, ''), code))
    },
  })
  if job_status(pending.job) != 'run'
    pending = {}
    Warn('failed to start ' .. args[0])
    return
  endif
  ch_sendraw(pending.job, prompt)
  ch_close_in(pending.job)
  Notify('Claude is editing lines ' .. l1 .. '-' .. l2 .. '…  (:ClaudeEditCancel)')
enddef

export def Cancel()
  if !empty(pending)
    var j = pending.job
    pending = {}
    job_stop(j)
    Unnotify()
    echo 'claude: edit cancelled'
  endif
enddef

def Finish(raw: string, code: number)
  Unnotify()
  if empty(pending)
    return  # cancelled
  endif
  var req = pending
  pending = {}
  var res: any
  try
    res = json_decode(raw)
  catch
    res = {}
  endtry
  if type(res) != v:t_dict || get(res, 'is_error', true) || type(get(res, 'result', 0)) != v:t_string
    var why = type(res) == v:t_dict && type(get(res, 'result', 0)) == v:t_string ? res.result : 'exit code ' .. code
    Warn('edit failed: ' .. why)
    return
  endif
  if !bufexists(req.buf) || getbufline(req.buf, req.l1, req.l2) != req.orig
    Warn('the buffer changed while Claude was working; edit discarded')
    return
  endif
  var proposal = split(util.StripFences(res.result), "\n", 1)
  if proposal == req.orig
    echo 'claude: no changes suggested'
    return
  endif
  ShowDiff(req, proposal)
enddef

def ShowDiff(req: dict<any>, proposal: list<string>)
  var all = getbufline(req.buf, 1, '$')
  var proposed = util.Slice(all, 0, req.l1 - 2) + proposal + util.Slice(all, req.l2, len(all) - 1)

  execute 'tab sbuffer ' .. req.buf
  diffthis
  var src_win = win_getid()
  rightbelow vnew
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setline(1, proposed)
  &l:filetype = req.ft
  silent! execute 'file ' .. fnameescape('claude://proposal/' .. fnamemodify(bufname(req.buf), ':t'))
  setlocal nomodified
  diffthis
  b:claude_edit = {buf: req.buf, src_win: src_win}
  &l:statusline = ' Claude proposal: ' .. substitute(req.instr, '%', '%%', 'g') .. '%=ga accept · gr reject · do/dp per hunk '
  nnoremap <buffer><silent> ga <ScriptCmd>Accept()<CR>
  nnoremap <buffer><silent> gr <ScriptCmd>Reject()<CR>
  nnoremap <buffer><silent> q <ScriptCmd>Reject()<CR>
  cursor(req.l1, 1)
  normal! zz
enddef

def Session(): dict<any>
  for w in gettabinfo(tabpagenr())[0].windows
    var s = getbufvar(winbufnr(w), 'claude_edit', {})
    if !empty(s)
      return extend({win: w}, s)
    endif
  endfor
  return {}
enddef

# Replace the source buffer with the proposal (as one undoable change).
export def Accept()
  var s = Session()
  if empty(s)
    Warn('no Claude proposal in this tab')
    return
  endif
  var target = getbufline(winbufnr(s.win), 1, '$')
  var r = util.MinimalReplace(getbufline(s.buf, 1, '$'), target)
  var first = r[0]
  var last = r[1]
  var repl: list<string> = r[2]
  var whole = first == 1 && last >= getbufinfo(s.buf)[0].linecount
  if last >= first
    deletebufline(s.buf, first, last)
  endif
  if whole
    setbufline(s.buf, 1, repl)  # buffer is now a single empty line
  elseif !empty(repl)
    appendbufline(s.buf, first - 1, repl)
  endif
  CloseDiff(s)
  echo 'claude: edit applied (u to undo)'
enddef

export def Reject()
  var s = Session()
  if empty(s)
    Warn('no Claude proposal in this tab')
    return
  endif
  CloseDiff(s)
  echo 'claude: edit rejected'
enddef

def CloseDiff(s: dict<any>)
  diffoff!
  if tabpagenr('$') > 1
    tabclose
  else
    win_execute(s.win, 'close')
  endif
enddef
