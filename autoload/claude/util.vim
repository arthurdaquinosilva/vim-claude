vim9script
# Pure helpers for claude.vim: no buffer/window/job side effects, so they are
# easy to unit test (see test/test_util.vim).

# Markers appended to messages we send. Everything from the first marker on
# is hidden when a transcript is rendered back into the chat panel.
export const CTX_MARKER = '<editor-context>'
export const ATTACH_MARKER = '<attachments>'

# Directory name Claude Code uses under ~/.claude/projects for a cwd.
export def ProjectKey(dir: string): string
  return substitute(dir, '[^A-Za-z0-9]', '-', 'g')
enddef

export def RelPath(path: string): string
  return path == '' ? '[No Name]' : fnamemodify(path, ':~:.')
enddef

# A fence that cannot be closed by anything inside `lines`.
export def FenceFor(lines: list<string>): string
  var fence = '```'
  while !empty(filter(copy(lines), (_, l) => l =~ '^\s*' .. fence))
    fence ..= '`'
  endwhile
  return fence
enddef

export def CodeBlock(lines: list<string>, ft: string): list<string>
  var fence = FenceFor(lines)
  return [fence .. ft] + lines + [fence]
enddef

# "`foo.vim` (lines 3-9)" / "`foo.vim` (line 3)"
export def RangeLabel(path: string, l1: number, l2: number): string
  var where = l1 == l2 ? 'line ' .. l1 : 'lines ' .. l1 .. '-' .. l2
  return '`' .. RelPath(path) .. '` (' .. where .. ')'
enddef

# Message for "explain this selection".
export def ExplainPrompt(path: string, ft: string, l1: number, l2: number, lines: list<string>, question: string = ''): string
  var ask = question == '' ? 'Explain this code from ' .. RangeLabel(path, l1, l2) .. ':'
                           : question .. "\n\nCode from " .. RangeLabel(path, l1, l2) .. ':'
  return join([ask, ''] + CodeBlock(lines, ft), "\n")
enddef

# Mention token for a range: @path#L3-9, @path#L3, or @path for a whole file.
export def Mention(path: string, l1: number, l2: number, total: number): string
  var rel = fnamemodify(path, ':.')
  if l1 <= 1 && l2 >= total
    return '@' .. rel
  endif
  return '@' .. rel .. '#L' .. l1 .. (l1 == l2 ? '' : '-' .. l2)
enddef

# Find @path#Lx[-y] mentions in `text`. Returns [{path, l1, l2}].
export def FindRangeMentions(text: string): list<dict<any>>
  var found: list<dict<any>> = []
  var start = 0
  while true
    var m = matchlist(text, '\v%(^|\s)\@(\S+)#L(\d+)%(-(\d+))?', start)
    if empty(m)
      break
    endif
    var l1 = str2nr(m[2])
    var l2 = m[3] == '' ? l1 : str2nr(m[3])
    add(found, {path: m[1], l1: min([l1, l2]), l2: max([l1, l2])})
    start = matchend(text, '\v%(^|\s)\@(\S+)#L(\d+)%(-(\d+))?', start)
  endwhile
  return found
enddef

# Append the contents of every @path#Lx-y mention to `text`.
# GetLines(path, l1, l2) returns the lines (lets callers read unsaved buffers).
export def ExpandMentions(text: string, GetLines: func(string, number, number): list<string>): string
  var blocks: list<string> = []
  for m in FindRangeMentions(text)
    var lines = GetLines(m.path, m.l1, m.l2)
    if empty(lines)
      continue
    endif
    var ft = Filetype(m.path)
    blocks += ['', '@' .. m.path .. '#L' .. m.l1 .. '-' .. m.l2 .. ':'] + CodeBlock(lines, ft)
  endfor
  if empty(blocks)
    return text
  endif
  return text .. "\n\n" .. ATTACH_MARKER .. join(blocks, "\n") .. "\n</attachments>"
enddef

export def Filetype(path: string): string
  var ext = fnamemodify(path, ':e')
  return get({vim: 'vim', py: 'python', js: 'javascript', ts: 'typescript', rb: 'ruby',
    rs: 'rust', go: 'go', sh: 'sh', c: 'c', h: 'c', cpp: 'cpp', java: 'java',
    lua: 'lua', md: 'markdown', json: 'json', html: 'html', css: 'css'}, ext, ext)
enddef

# Remove the hidden context/attachments we appended to a sent message.
export def StripHidden(text: string): string
  var cut = -1
  for marker in ["\n\n" .. CTX_MARKER, "\n\n" .. ATTACH_MARKER]
    var i = stridx(text, marker)
    if i >= 0 && (cut < 0 || i < cut)
      cut = i
    endif
  endfor
  return cut < 0 ? text : strpart(text, 0, cut)
enddef

# One-line, human summary of a tool call for the chat transcript.
export def ToolSummary(name: string, input: any): string
  var inp = type(input) == v:t_dict ? input : {}
  var Short = (s: string): string => strcharlen(s) > 80 ? strcharpart(s, 0, 77) .. '...' : s
  if index(['Read', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit'], name) >= 0
    var p = get(inp, 'file_path', get(inp, 'notebook_path', ''))
    return name .. ' ' .. RelPath(p)
  elseif name == 'Bash'
    return 'Bash ' .. Short(split(get(inp, 'command', '') .. ' ', "\n")[0]->trim())
  elseif name == 'Grep' || name == 'Glob'
    return name .. ' ' .. Short(get(inp, 'pattern', ''))
  elseif name == 'WebFetch'
    return 'WebFetch ' .. Short(get(inp, 'url', ''))
  elseif name == 'WebSearch'
    return 'WebSearch ' .. Short(get(inp, 'query', ''))
  elseif name == 'Task' || name == 'Agent'
    return name .. ' ' .. Short(get(inp, 'description', ''))
  elseif name == 'TodoWrite'
    return 'Update todo list'
  endif
  return name
enddef

# --allowedTools rule that would have permitted a denied call.
export def DenialRule(denial: dict<any>): string
  var name = get(denial, 'tool_name', '')
  var inp = get(denial, 'tool_input', {})
  if name == 'Bash' && type(inp) == v:t_dict && get(inp, 'command', '') != ''
    return 'Bash(' .. inp.command .. ')'
  endif
  return name
enddef

# Strip one surrounding markdown fence from a model reply, if present.
export def StripFences(text: string): string
  var lines = split(text, "\n", 1)
  while !empty(lines) && lines[0] =~ '^\s*$'
    remove(lines, 0)
  endwhile
  while !empty(lines) && lines[-1] =~ '^\s*$'
    remove(lines, -1)
  endwhile
  if len(lines) >= 2 && lines[0] =~ '^\s*```' && lines[-1] =~ '^\s*```\s*$'
    lines = lines[1 : -2]
  endif
  return join(lines, "\n")
enddef

# l[s : e] without Vim's negative-index wraparound.
export def Slice(l: list<string>, s: number, e: number): list<string>
  return e < s || s >= len(l) ? [] : l[s : e]
enddef

# Prompt for an inline edit of lines l1..l2 of `all`.
export def EditPrompt(path: string, ft: string, l1: number, l2: number, all: list<string>, instruction: string): string
  # Give surrounding context, but cap it for huge files.
  var c1 = max([1, l1 - 150])
  var c2 = min([len(all), l2 + 150])
  var ctx = Slice(all, c1 - 1, l1 - 2) + ['<<<SELECTION START>>>'] + Slice(all, l1 - 1, l2 - 1)
    + ['<<<SELECTION END>>>'] + Slice(all, l2, c2 - 1)
  return join([
    'You are editing code inside the Vim editor.',
    'Rewrite ONLY the selected lines according to the instruction.',
    'Reply with the replacement code for the selection and nothing else:',
    'no explanation, no markdown fences, no selection markers.',
    'Keep the original indentation style.',
    '',
    'Instruction: ' .. instruction,
    '',
    'File: ' .. RelPath(path) .. ' (filetype: ' .. (ft == '' ? 'unknown' : ft) .. '), selection is lines ' .. l1 .. '-' .. l2,
    ''] + CodeBlock(ctx, ft), "\n")
enddef

# Smallest single hunk turning `a` into `b`: [first, last, replacement] with
# 1-based lines of `a` (last < first means pure insertion before `first`).
export def MinimalReplace(a: list<string>, b: list<string>): list<any>
  var pre = 0
  while pre < len(a) && pre < len(b) && a[pre] ==# b[pre]
    pre += 1
  endwhile
  var suf = 0
  while suf < len(a) - pre && suf < len(b) - pre && a[-1 - suf] ==# b[-1 - suf]
    suf += 1
  endwhile
  return [pre + 1, len(a) - suf, Slice(b, pre, len(b) - suf - 1)]
enddef

# [start, end] (1-based, inclusive, fences excluded) of the fenced code block
# containing line `lnum`, or [] when not inside one.
export def CodeBlockAt(lines: list<string>, lnum: number): list<number>
  var open = 0
  var fence = ''
  for i in range(len(lines))
    var l = lines[i]
    if open == 0
      var m = matchstr(l, '^\s*\zs```\+')
      if m != ''
        open = i + 1
        fence = m
      endif
    elseif l =~ '^\s*' .. fence .. '\s*$'
      if lnum >= open && lnum <= i + 1
        return open + 1 <= i ? [open + 1, i] : []
      endif
      open = 0
    endif
  endfor
  return []
enddef

def BlockText(content: any): list<dict<any>>
  if type(content) == v:t_string
    return [{kind: 'text', text: content}]
  endif
  var out: list<dict<any>> = []
  if type(content) != v:t_list
    return out
  endif
  for c in content
    if type(c) != v:t_dict
      continue
    endif
    var t = get(c, 'type', '')
    if t == 'text'
      add(out, {kind: 'text', text: get(c, 'text', '')})
    elseif t == 'tool_use'
      add(out, {kind: 'tool', text: ToolSummary(get(c, 'name', ''), get(c, 'input', {}))})
    endif
  endfor
  return out
enddef

# Turn Claude Code session .jsonl lines into [{role, kind, text}] entries.
export def ParseTranscript(jsonl: list<string>): list<dict<any>>
  var out: list<dict<any>> = []
  for line in jsonl
    var ev: any
    try
      ev = json_decode(line)
    catch
      continue
    endtry
    if type(ev) != v:t_dict || get(ev, 'isMeta', false) || get(ev, 'isSidechain', false)
      continue
    endif
    var role = get(ev, 'type', '')
    if role != 'user' && role != 'assistant'
      continue
    endif
    for b in BlockText(get(get(ev, 'message', {}), 'content', ''))
      var text = b.text
      if role == 'user'
        if text =~ '^\s*<' || text =~ '^\s*$'
          continue   # command wrappers, caveats, tool results
        endif
        text = StripHidden(text)
      endif
      add(out, {role: role, kind: b.kind, text: text})
    endfor
  endfor
  return out
enddef

# First real user prompt of a transcript, for the resume picker.
export def TranscriptTitle(jsonl: list<string>): string
  for e in ParseTranscript(jsonl)
    if e.role == 'user'
      var t = substitute(trim(e.text), '\_s\+', ' ', 'g')
      return strcharlen(t) > 70 ? strcharpart(t, 0, 67) .. '...' : t
    endif
  endfor
  return ''
enddef
