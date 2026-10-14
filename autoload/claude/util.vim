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

# Blend a #rrggbb color toward white (amount > 0) or black (amount < 0).
export def Shade(hex: string, amount: float): string
  if hex !~ '^#\x\{6}$'
    return hex
  endif
  var out = '#'
  for i in [1, 3, 5]
    var c = str2nr(hex[i : i + 1], 16)
    var t = amount > 0 ? c + (255 - c) * amount : c * (1.0 + amount)
    out ..= printf('%02x', float2nr(round(t)))
  endfor
  return out
enddef

# A slightly lighter (dark themes) or darker (light themes) cterm color than
# `bg`, using the 232-255 grayscale ramp; `bg` < 0 means unknown.
export def ShadeCterm(bg: number, dark: bool): number
  if bg >= 232 && bg <= 255
    return dark ? min([bg + 2, 255]) : max([bg - 2, 232])
  elseif bg == 0 || bg == 16
    return 234
  elseif bg == 15 || bg == 231
    return 254
  endif
  return dark ? 236 : 254
enddef

# Statusline drawn as a horizontal rule exactly `width` cells wide:
#   ── <left> ─────────── <right> ──
# `lefts` are alternatives from richest to plainest; the first that fits is
# used. The right side is dropped only when even the plainest left won't
# fit beside it. Segments are [text, highlight group]; '' = rule color.
export def Rule(lefts: list<list<list<string>>>, right: list<list<string>>, width: number, rule_hl: string): string
  var Len = (segs: list<list<string>>): number =>
    reduce(segs, (acc, s) => acc + strwidth(s[0]), 0)
  var Draw = (segs: list<list<string>>): string =>
    join(mapnew(segs, (_, s) => '%#' .. (s[1] == '' ? rule_hl : s[1]) .. '#'
      .. substitute(s[0], '%', '%%', 'g')), '')
  # Keep the right side as long as possible, shortening the left first,
  # but never drop the left entirely to make room for the right.
  for rr in [right, []]
    for left in lefts + (empty(rr) ? [[]] : [])
      # '── ' left ' ' fill [' ' right ' '] '──'
      var used = 3 + Len(left) + 1 + (empty(rr) ? 0 : Len(rr) + 2) + 2
      if used < width
        return Draw([['── ', '']] + left + [[' ' .. repeat('─', width - used), '']]
          + (empty(rr) ? [] : [[' ', '']] + rr + [[' ', '']]) + [['──', '']])
      endif
    endfor
  endfor
  return '%#' .. rule_hl .. '#' .. repeat('─', max([width, 0]))
enddef

# How many screen rows `lines` need in a window `width` cells wide, given a
# `prefix` cells-wide margin on every line.
export def DisplayRows(lines: list<string>, width: number, prefix: number): number
  var w = max([width - prefix, 1])
  return reduce(lines, (acc, l) => acc + max([1, (strwidth(l) + w - 1) / w]), 0)
enddef

# ---------------------------------------------------------------- tables
#
# Tables are aligned by counting characters, so their cells must not contain
# Markdown markup that a syntax file might conceal (`code`, **bold**, links).
# Cells are reduced to plain text; code spans are returned as highlight
# ranges for the caller to apply as text properties.

const TABLE_SEP = '^\s*|\=\s*:\=-\+:\=\s*\%(|\s*:\=-\+:\=\s*\)*|\=\s*$'

# Split a "| a | b |" row into trimmed raw cells (honours \| escapes).
export def TableCells(line: string): list<string>
  var s = trim(line)
  s = substitute(s, '^|', '', '')
  s = substitute(s, '\\\@<!|$', '', '')
  return mapnew(split(s, '\\\@<!|', 1), (_, c) => trim(substitute(c, '\\|', '|', 'g')))
enddef

# Raw cell -> [plain text, code mask (one bool per character)].
export def ParseCell(raw: string): list<any>
  var s = substitute(raw, '\[\([^]]*\)\](\([^)]*\))', '\1', 'g')   # [text](url)
  s = substitute(s, '\*\*\(.\{-1,}\)\*\*', '\1', 'g')                # **bold**
  s = substitute(s, '\<__\(.\{-1,}\)__\>', '\1', 'g')                # __bold__
  var ticks = count(s, '`')
  var plain = ''
  var mask: list<bool> = []
  var in_code = false
  var seen = 0
  for ch in split(s, '\zs')
    if ch == '`' && (in_code || seen < ticks - ticks % 2)
      seen += 1
      in_code = !in_code
      continue
    endif
    plain ..= ch
    add(mask, in_code)
  endfor
  return [plain, mask]
enddef

# Word-wrap `text` into [start, end) character ranges at most `width` display
# cells wide (long words are hard-broken).
export def WrapRanges(text: string, width: number): list<list<number>>
  var chars = split(text, '\zs')
  var n = len(chars)
  var out: list<list<number>> = []
  var i = 0
  while i < n
    while i < n && chars[i] == ' '
      i += 1
    endwhile
    if i >= n
      break
    endif
    var j = i
    var w = 0
    var last_space = -1
    while j < n && w + strwidth(chars[j]) <= width
      if chars[j] == ' '
        last_space = j
      endif
      w += strwidth(chars[j])
      j += 1
    endwhile
    if j >= n || chars[j] == ' '
      add(out, [i, j])
      i = j
    elseif last_space > i
      add(out, [i, last_space])
      i = last_space + 1
    else
      add(out, [i, max([j, i + 1])])
      i = max([j, i + 1])
    endif
  endwhile
  for r in out
    while r[1] > r[0] && chars[r[1] - 1] == ' '
      r[1] -= 1
    endwhile
  endfor
  return empty(out) ? [[0, 0]] : out
enddef

export def WrapText(text: string, width: number): list<string>
  return mapnew(WrapRanges(text, width), (_, r) => strcharpart(text, r[0], r[1] - r[0]))
enddef

def PadLeft(width: number, textw: number, align: string): number
  var gap = width - textw
  return align == 'right' ? gap : align == 'center' ? gap / 2 : 0
enddef

# Render markdown table lines (header, separator, rows) as a box-drawn table
# at most `maxwidth` cells wide. Returns {lines, code} where code is a list
# of [line index, byte column (1-based), byte length] ranges of inline code.
export def RenderTable(lines: list<string>, maxwidth: number): dict<any>
  var aligns = mapnew(TableCells(lines[1]), (_, c) =>
    c =~ '^:.*:$' ? 'center' : c =~ ':$' ? 'right' : 'left')
  var rows = mapnew(lines[0 : 0] + lines[2 :], (_, l) => mapnew(TableCells(l), (_, c) => ParseCell(c)))
  var ncol = max(mapnew(rows, (_, r) => len(r)))
  for r in rows
    while len(r) < ncol
      add(r, ['', []])
    endwhile
  endfor
  while len(aligns) < ncol
    add(aligns, 'left')
  endwhile

  var widths = mapnew(range(ncol), (_, c) =>
    max([1] + mapnew(rows, (_, r) => strwidth(r[c][0]))))
  # Borders take 3 cells per column plus 1; shrink the widest column until
  # the table fits (but keep every column at least 6 wide).
  var budget = maxwidth - (3 * ncol + 1)
  while reduce(widths, (a, w) => a + w, 0) > budget
    var widest = index(widths, max(widths))
    if widths[widest] <= 6
      break
    endif
    widths[widest] -= 1
  endwhile

  var Border = (l: string, m: string, r: string): string =>
    l .. join(mapnew(widths, (_, w) => repeat('─', w + 2)), m) .. r
  var out = [Border('┌', '┬', '┐')]
  var code: list<list<number>> = []
  var bodies: list<list<string>> = []
  var wrapped = false
  for row in rows
    var wraps = mapnew(range(ncol), (_, c) => WrapRanges(row[c][0], widths[c]))
    var height = max(mapnew(wraps, (_, w) => len(w)))
    wrapped = wrapped || height > 1
    var block: list<string> = []
    for i in range(height)
      var line = '│'
      for c in range(ncol)
        var rng = get(wraps[c], i, [0, 0])
        var text = strcharpart(row[c][0], rng[0], rng[1] - rng[0])
        var pad = PadLeft(widths[c], strwidth(text), aligns[c])
        var text_col = strlen(line) + 1 + pad + 1   # 1-based byte column
        # Code ranges within this piece of the cell.
        var k = rng[0]
        while k < rng[1]
          if row[c][1][k]
            var e = k
            while e < rng[1] && row[c][1][e]
              e += 1
            endwhile
            add(code, [len(out) + len(block),
              text_col + strlen(strcharpart(text, 0, k - rng[0])),
              strlen(strcharpart(text, k - rng[0], e - k))])
            k = e
          else
            k += 1
          endif
        endwhile
        line ..= ' ' .. repeat(' ', pad) .. text
          .. repeat(' ', widths[c] - pad - strwidth(text)) .. ' │'
      endfor
      add(block, line)
    endfor
    add(bodies, block)
    out += block
    if len(bodies) == 1 || (wrapped && len(bodies) < len(rows))
      add(out, Border('├', '┼', '┤'))
    endif
  endfor
  if out[-1] =~ '^├'
    remove(out, -1)
  endif
  add(out, Border('└', '┴', '┘'))
  return {lines: out, code: code}
enddef

export def FormatTable(lines: list<string>, maxwidth: number): list<string>
  return RenderTable(lines, maxwidth).lines
enddef

# Find markdown tables in `lines` (outside fenced code) and return
# replacements [[first, last, new_lines, code_ranges], ...] (0-based indexes).
export def FormatTables(lines: list<string>, maxwidth: number): list<list<any>>
  var out: list<list<any>> = []
  var fence = ''
  var i = 0
  while i < len(lines)
    var l = lines[i]
    var f = matchstr(l, '^\s*\zs```\+')
    if f != ''
      fence = fence == '' ? f : (l =~ '^\s*' .. fence .. '\s*$' ? '' : fence)
    elseif fence == '' && l =~ '^\s*|.*|\s*$' && i + 1 < len(lines) && lines[i + 1] =~ TABLE_SEP
      var j = i + 2
      while j < len(lines) && lines[j] =~ '^\s*|'
        j += 1
      endwhile
      var t = RenderTable(lines[i : j - 1], maxwidth)
      add(out, [i, j - 1, t.lines, t.code])
      i = j
      continue
    endif
    i += 1
  endwhile
  return out
enddef
