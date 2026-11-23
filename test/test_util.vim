vim9script
import autoload 'claude/util.vim'

def g:Test_ProjectKey()
  assert_equal('-Users-me-my-proj--vim', util.ProjectKey('/Users/me/my_proj/.vim'))
enddef

def g:Test_FenceFor_avoids_inner_fences()
  assert_equal('```', util.FenceFor(['a', 'b']))
  assert_equal('````', util.FenceFor(['```python', 'x', '```']))
enddef

def g:Test_Mention()
  assert_equal('@a.vim', util.Mention('a.vim', 1, 10, 10))
  assert_equal('@a.vim#L3', util.Mention('a.vim', 3, 3, 10))
  assert_equal('@a.vim#L3-7', util.Mention('a.vim', 3, 7, 10))
enddef

def g:Test_FindRangeMentions()
  var m = util.FindRangeMentions('look @src/a.c#L3-9 and @b.py#L4 but not me@x.c#L1 or @whole.c')
  assert_equal([{path: 'src/a.c', l1: 3, l2: 9}, {path: 'b.py', l1: 4, l2: 4}], m)
  assert_equal([{path: 'x', l1: 2, l2: 5}], util.FindRangeMentions('@x#L5-2'))
enddef

def g:Test_ExpandMentions_attaches_code()
  var Get = (p: string, a: number, b: number): list<string> => ['l' .. a, 'l' .. b]
  var out = util.ExpandMentions('why @f.py#L2-3?', Get)
  assert_match('^why @f.py#L2-3?\n\n<attachments>', out)
  assert_match('```python\nl2\nl3\n```', out)
  assert_equal('plain', util.ExpandMentions('plain', Get))
  assert_equal('why @f.py#L2-3?', util.StripHidden(out))
enddef

def g:Test_StripHidden_cuts_at_first_marker()
  var s = "hi\n\n" .. util.CTX_MARKER .. 'x</editor-context>'
  assert_equal('hi', util.StripHidden(s))
  assert_equal('hi', util.StripHidden('hi'))
enddef

def g:Test_ExplainPrompt()
  var p = util.ExplainPrompt('/tmp/x.vim', 'vim', 2, 3, ['a', 'b'])
  assert_match('^Explain this code from `.*x.vim` (lines 2-3):\n\n```vim\na\nb\n```$', p)
  var q = util.ExplainPrompt('/tmp/x.vim', 'vim', 2, 2, ['a'], 'Is this safe?')
  assert_match('^Is this safe?\n\nCode from `.*x.vim` (line 2):', q)
enddef

def g:Test_ToolSummary()
  assert_equal('Read a/b.c', util.ToolSummary('Read', {file_path: 'a/b.c'}))
  assert_equal('Bash ls -la', util.ToolSummary('Bash', {command: "ls -la\necho hi"}))
  assert_equal('Grep foo', util.ToolSummary('Grep', {pattern: 'foo'}))
  assert_equal('Mystery', util.ToolSummary('Mystery', v:null))
  assert_equal(80, strcharlen(util.ToolSummary('Bash', {command: repeat('x', 200)})) - 5)
enddef

def g:Test_DenialRule()
  assert_equal('Bash(npm test)', util.DenialRule({tool_name: 'Bash', tool_input: {command: 'npm test'}}))
  assert_equal('Edit', util.DenialRule({tool_name: 'Edit', tool_input: {file_path: 'x'}}))
enddef

def g:Test_StripFences()
  assert_equal("a\nb", util.StripFences("```vim\na\nb\n```\n"))
  assert_equal("a\nb", util.StripFences("\na\nb\n"))
  assert_equal("```x\ny", util.StripFences("```x\ny"))
enddef

def g:Test_EditPrompt_marks_selection_and_handles_first_line()
  var p = util.EditPrompt('f.vim', 'vim', 1, 1, ['one', 'two', 'three'], 'shout')
  assert_match('Instruction: shout', p)
  assert_match("```vim\n<<<SELECTION START>>>\none\n<<<SELECTION END>>>\ntwo\nthree\n```", p)
enddef

def g:Test_MinimalReplace()
  assert_equal([2, 2, ['X']], util.MinimalReplace(['a', 'b', 'c'], ['a', 'X', 'c']))
  assert_equal([2, 1, ['new']], util.MinimalReplace(['a', 'c'], ['a', 'new', 'c']))
  assert_equal([2, 2, []], util.MinimalReplace(['a', 'b', 'c'], ['a', 'c']))
  assert_equal([1, 2, ['z']], util.MinimalReplace(['a', 'b'], ['z']))
enddef

def g:Test_CodeBlockAt()
  var lines = ['text', '```vim', 'x', 'y', '```', 'more', '````', '```', '````']
  assert_equal([3, 4], util.CodeBlockAt(lines, 3))
  assert_equal([3, 4], util.CodeBlockAt(lines, 2))
  assert_equal([], util.CodeBlockAt(lines, 6))
  assert_equal([8, 8], util.CodeBlockAt(lines, 8))
enddef

def g:Test_ParseTranscript_and_title()
  var lines = [
    json_encode({type: 'user', isMeta: true, message: {content: 'caveat'}}),
    json_encode({type: 'user', message: {content: '<command-name>/x</command-name>'}}),
    json_encode({type: 'user', message: {content: "Fix the bug\n\n" .. util.CTX_MARKER .. 'ctx'}}),
    json_encode({type: 'assistant', message: {content: [{type: 'text', text: 'Sure'},
      {type: 'tool_use', name: 'Read', input: {file_path: 'a.c'}}]}}),
    json_encode({type: 'user', message: {content: [{type: 'tool_result', content: 'ok'}]}}),
    'not json',
  ]
  assert_equal([
    {role: 'user', kind: 'text', text: 'Fix the bug'},
    {role: 'assistant', kind: 'text', text: 'Sure'},
    {role: 'assistant', kind: 'tool', text: 'Read a.c'},
  ], util.ParseTranscript(lines))
  assert_equal('Fix the bug', util.TranscriptTitle(lines))
  assert_equal('a b c', util.TranscriptTitle([json_encode({type: 'user', message: {content: "a\n\nb  c"}})]))
enddef

def g:Test_default_mappings_use_prefix()
  assert_match('ClaudeToggle', maparg('<Leader>cc', 'n'))
  assert_match('ClaudeEdit', maparg('<Leader>ci', 'x'))
enddef

def g:Test_Shade()
  assert_equal('#808080', util.Shade('#000000', 0.5 + 0.002))
  assert_equal('#808080', util.Shade('#ffffff', -0.5))
  assert_equal('NONE', util.Shade('NONE', 0.1))
  assert_equal(236, util.ShadeCterm(234, true))
  assert_equal(253, util.ShadeCterm(255, false))
  assert_equal(236, util.ShadeCterm(-1, true))
enddef

def g:Test_Rule_fills_exact_width_and_degrades()
  var Plain = (s: string): string => substitute(s, '%#[^#]*#', '', 'g')
  var s = Plain(util.Rule([[['Claude', 'T']]], [['haiku', '']], 30, 'R'))
  assert_equal(30, strwidth(s))
  assert_match('^── Claude ─\+ haiku ──$', s)
  # Too narrow for the long left: falls back to the short one.
  s = Plain(util.Rule([[['a very long hint text here', '']], [['short', '']]], [['x', '']], 20, 'R'))
  assert_match('^── short ─\+ x ──$', s)
  assert_equal(20, strwidth(s))
  # Too narrow for anything: right side dropped, then plain rule.
  assert_equal(12, strwidth(Plain(util.Rule([[['abc', '']]], [['wide right', '']], 12, 'R'))))
  assert_equal('───', Plain(util.Rule([[['abcdef', '']]], [], 3, 'R')))
  assert_match('100%%', util.Rule([[['100%', '']]], [], 20, 'R'))
  # Prefers shorter hints with the right side over long hints without it.
  s = Plain(util.Rule([[['long long long hints', '']], [['hints', '']]], [['file.py:3', '']], 30, 'R'))
  assert_match('^── hints ─\+ file.py:3 ──$', s)
enddef

def g:Test_DisplayRows()
  assert_equal(1, util.DisplayRows([''], 20, 2))
  assert_equal(2, util.DisplayRows([repeat('x', 19)], 20, 2))
  assert_equal(3, util.DisplayRows(['a', 'b', 'c'], 20, 2))
enddef

def g:Test_TableCells()
  assert_equal(['a', 'b c', 'x|y'], util.TableCells('| a | b c | x\|y |'))
  assert_equal(['a', 'b'], util.TableCells('a | b'))
enddef

def g:Test_WrapText()
  assert_equal(['hello', 'world'], util.WrapText('hello world', 7))
  assert_equal(['abcde', 'fgh'], util.WrapText('abcdefgh', 5))
  assert_equal([''], util.WrapText('', 5))
enddef

def g:Test_FormatTable_aligned()
  var t = util.FormatTable(['| Action | Effect |', '|---|--:|', '| `add(x)` | Adds one |', '| set | 2 |'], 80)
  assert_equal([
    '┌────────┬──────────┐',
    '│ Action │   Effect │',
    '├────────┼──────────┤',
    '│ add(x) │ Adds one │',
    '│ set    │        2 │',
    '└────────┴──────────┘'], t)
enddef

def g:Test_FormatTable_wraps_to_width()
  var t = util.FormatTable(['| Name | Description |', '|---|---|',
    '| setQuantity | Updates one item quantity at the given index |', '| a | b |'], 30)
  for l in t
    assert_true(strwidth(l) <= 30, l)
  endfor
  assert_equal(strwidth(t[0]), strwidth(t[-1]))
  assert_match('│ setQuantity │ Updates one  │\n│             │ item         │', join(t, "\n"))
  # Wrapped rows get a separator between them (plus the header one).
  assert_equal(2, len(filter(copy(t), (_, l) => l =~ '^├')))
enddef

def g:Test_FormatTables_skips_code_and_finds_ranges()
  var lines = ['intro', '| a | b |', '|---|---|', '| 1 | 2 |', 'after',
    '```', '| x | y |', '|---|---|', '```']
  var r = util.FormatTables(lines, 80)
  assert_equal(1, len(r))
  assert_equal([1, 3], r[0][0 : 1])
  assert_equal('┌───┬───┐', r[0][2][0])
enddef

def g:Test_FormatTable_strips_bold_markers()
  var t = util.FormatTable(['| **Name** | __Kind__ |', '|---|---|', '| **a** | b |'], 80)
  assert_equal('│ Name │ Kind │', t[1])
  assert_equal('│ a    │ b    │', t[3])
enddef

def g:Test_ParseCell_strips_markup_and_marks_code()
  var [plain, mask] = util.ParseCell('Uses `a b` and **c** [d](http://x)')
  assert_equal('Uses a b and c d', plain)
  assert_equal('00000111000000000', join(mapnew(mask, (_, m) => m ? '1' : '0'), '') .. '0')
  # An unmatched backtick stays literal.
  assert_equal(['x y', 'it`s'], [util.ParseCell('``x`` y')[0], util.ParseCell('it`s')[0]])
enddef

def g:Test_RenderTable_code_ranges_survive_wrapping()
  var t = util.RenderTable(['| A | B |', '|---|---|', '| `setQuantity({index, quantity})` | Updates `qty` now |'], 34)
  var got: list<string> = []
  for [li, col, len] in t.code
    add(got, strpart(t.lines[li], col - 1, len))
  endfor
  assert_equal(['setQuantity({', 'qty', 'index,', 'quantity})'], got)
  for l in t.lines
    assert_true(strwidth(l) <= 34, l)
    assert_equal(strwidth(t.lines[0]), strwidth(l))
  endfor
enddef

def g:Test_FenceLangs_and_filetypes()
  var lines = ['  ```js', 'x', '  ```', '```Python title="a"', 'y', '```', '```', 'z', '```', '```c++', '```']
  assert_equal(['c++', 'js', 'python'], util.FenceLangs(lines))
  assert_equal(['javascript', 'typescriptreact', 'python', 'sh', 'cpp', 'lua'],
    mapnew(['js', 'tsx', 'PY', 'bash', 'c++', 'lua'], (_, t) => util.LangFiletype(t)))
  assert_match(util.FenceStart('c++'), '  ```c++')
  assert_match(util.FenceStart('js'), '```JS {1,3}')
  assert_notmatch(util.FenceStart('js'), '```json')
enddef

def g:Test_Bar_fits_width_and_degrades()
  var Plain = (x: string): string => substitute(x, '%#[^#]*#', '', 'g')
  var b = Plain(util.Bar([['file.js:1', '']], [['opus · ask', '']], 40, 'R'))
  assert_equal(40, strwidth(b))
  assert_match('^  file.js:1 \+opus · ask $', b)
  # Narrow: the left side goes first, then the right is cut from the start.
  assert_equal('       opus · ask ', Plain(util.Bar([['file.js:1', '']], [['opus · ask', '']], 18, 'R')))
  b = Plain(util.Bar([], [['opus · ask before edits', '']], 12, 'R'))
  assert_equal(12, strwidth(b))
  assert_equal('  …re edits ', b)
enddef

def g:Test_Bar_keep_left_shortens_right_first()
  var Plain = (x: string): string => substitute(x, '%#[^#]*#', '', 'g')
  var b = Plain(util.Bar([['ctrl-c to stop', '']], [['⠋ writing… · opus · ask before edits', '']], 40, 'R', true))
  assert_equal(40, strwidth(b))
  assert_match('^  ctrl-c to stop  …', b)
  assert_match('ask before edits $', b)
enddef

def g:Test_QuoteText()
  assert_equal(['> Hello **x**', '>', '> next', ''],
    util.QuoteText(['', '  Hello **x**', '', '  next', '']))
  assert_equal(['```js', 'const a = 1;', '  if (a) {}', '```', ''],
    util.QuoteText(['  const a = 1;', '    if (a) {}'], 'js', true))
  assert_equal([], util.QuoteText(['', '  ']))
enddef

def g:Test_FenceAround()
  var lines = ['  text', '  ```py', '  a = 1', '  b = 2', '  ```', '  more']
  assert_equal({lang: 'py'}, util.FenceAround(lines, 3, 4))
  assert_equal({}, util.FenceAround(lines, 1, 3))
  assert_equal({}, util.FenceAround(lines, 6, 6))
enddef

def g:Test_PermissionPreview_shows_the_change()
  assert_equal(['- a', '- b', '+ c'],
    util.PermissionPreview('Edit', {file_path: 'x', old_string: "a\nb", new_string: 'c'}))
  assert_equal(['+ one', '+ two'], util.PermissionPreview('Write', {file_path: 'x', content: "one\ntwo"}))
  assert_equal(['# Run tests', 'npm test'],
    util.PermissionPreview('Bash', {command: 'npm test', description: 'Run tests'}))
  assert_equal(['url: https://x.dev'], util.PermissionPreview('WebFetch', {url: 'https://x.dev'}))
enddef

def g:Test_PermissionPreview_truncates_long_input()
  var big = join(map(range(30), (_, i) => 'l' .. i), "\n")
  var out = util.PermissionPreview('Write', {content: big}, 5)
  assert_equal(5, len(out))
  assert_equal('… 26 more lines', out[-1])
  var wide = util.PermissionPreview('Bash', {command: repeat('x', 300)})
  assert_equal(100, strcharlen(wide[0]))
enddef

def g:Test_AllowRule_scopes_bash_to_the_command()
  assert_equal({toolName: 'Bash', ruleContent: 'npm test'}, util.AllowRule('Bash', {command: 'npm test'}))
  assert_equal({toolName: 'Edit'}, util.AllowRule('Edit', {file_path: 'a'}))
  assert_true(util.IsEditTool('Write'))
  assert_false(util.IsEditTool('Bash'))
enddef

def g:Test_ToolResult_edit_uses_the_patch_with_numbered_lines()
  var patch = [{oldStart: 8, newStart: 8, lines: ['  keep', ' a', '-old1', '-old2', '+new', ' b', ' c', ' d']}]
  var r = util.ToolResult('Edit', {file_path: 'x.py'}, '', {structuredPatch: patch})
  assert_equal('Updated x.py with 1 addition and 2 removals', r[0].text)
  # One line of context around the change; the rest is dropped.
  assert_equal([' 9   a', '10 - old1', '11 - old2', '10 + new', '11   b'],
    mapnew(r[1 :], (_, i) => i.text)[0 : 4]->mapnew((_, t) => t))
  assert_equal(['ctx', 'del', 'del', 'add', 'ctx'], mapnew(r[1 :], (_, i) => i.kind))
enddef

def g:Test_ToolResult_edit_falls_back_to_the_input()
  var r = util.ToolResult('Edit', {file_path: 'x', old_string: "a\nb\nc", new_string: "a\nB\nc"}, '', {})
  assert_equal('Updated x with 1 addition and 1 removal', r[0].text)
  assert_equal(['del', 'add'], mapnew(r[1 :], (_, i) => i.kind))
enddef

def g:Test_ToolResult_caps_long_diffs_and_output()
  var lines = mapnew(range(40), (_, i) => '+l' .. i)
  var r = util.ToolResult('Edit', {file_path: 'x'}, '', {structuredPatch: [{oldStart: 1, newStart: 1, lines: lines}]}, 6)
  assert_equal(7, len(r))  # the summary and 6 diff lines, the last one a counter
  assert_equal('… +35 lines', r[-1].text)
  var out = util.ToolResult('Bash', {command: 'x'}, '', {stdout: join(range(30), "\n"), stderr: ''}, 12)
  assert_equal(['0', '1', '2', '3'], mapnew(out[: 3], (_, i) => i.text))
  assert_equal('… +26 lines', out[-1].text)
  assert_equal('(no output)', util.ToolResult('Bash', {command: 'x'}, '', {stdout: '', stderr: ''})[0].text)
enddef

def g:Test_ToolResult_write_read_grep_todo()
  var w = util.ToolResult('Write', {file_path: 'n.txt', content: "a\nb\n"}, '', {})
  assert_equal(['Wrote 2 lines to n.txt', '1 + a', '2 + b'], mapnew(w, (_, i) => i.text))
  assert_equal('Read 3 lines', util.ToolResult('Read', {file_path: 'x'}, "1\ta\n2\tb\n3\tc", {})[0].text)
  assert_equal('Found 2 lines', util.ToolResult('Grep', {pattern: 'p'}, "a:1\nb:2", {})[0].text)
  assert_equal('No matches', util.ToolResult('Grep', {pattern: 'p'}, '', {})[0].text)
  assert_equal([], util.ToolResult('WebSearch', {query: 'q'}, 'text', {}))
  var t = util.ToolResult('TodoWrite', {todos: [{content: 'A', status: 'completed'}, {content: 'B', activeForm: 'Doing B', status: 'in_progress'}, {content: 'C', status: 'pending'}]}, '', {})
  assert_equal(['☒ A', '◼ Doing B', '☐ C'], mapnew(t, (_, i) => i.text))
  assert_equal(['done', 'doing', 'todo'], mapnew(t, (_, i) => i.kind))
enddef

def g:Test_ParseSlash()
  assert_equal(['compact', ''], util.ParseSlash('/compact'))
  assert_equal(['hi', 'Bob and Ann'], util.ParseSlash('/hi  Bob and Ann '))
  assert_equal(['ns:cmd', 'x'], util.ParseSlash('/ns:cmd x'))
  assert_equal([], util.ParseSlash('/etc/hosts is broken'))
  assert_equal([], util.ParseSlash(' /compact'))
  assert_equal([], util.ParseSlash('hello /compact'))
  assert_equal([], util.ParseSlash('/'))
enddef

def g:Test_SlashMatches_orders_and_describes()
  var names = ['zeta', 'compact', 'cost', 'clear', '__hidden', 'model', 'code-review']
  var all = util.SlashMatches(names, {cost: 'Show cost'}, '')
  # Everyday commands first, internal ones never.
  assert_equal(['/clear', '/compact', '/cost', '/model', '/code-review', '/zeta'], mapnew(all, (_, i) => i.word))
  assert_equal('Show cost', all[2].menu)
  assert_equal('', all[0].menu)
  # Prefix matches before fuzzy ones.
  var co = util.SlashMatches(names, {}, 'co')
  assert_equal(['/code-review', '/compact', '/cost'], mapnew(co, (_, i) => i.word)[0 : 2])
  assert_equal([], util.SlashMatches(names, {}, 'qqq'))
enddef

def g:Test_Frontmatter_reads_a_key()
  var f = ['---', 'name: demo', 'description: "Say hello"', 'argument-hint: [name]', '---', 'body']
  assert_equal('Say hello', util.Frontmatter(f, 'description'))
  assert_equal('demo', util.Frontmatter(f, 'name'))
  assert_equal('', util.Frontmatter(f, 'missing'))
  assert_equal('', util.Frontmatter(['no front matter', 'description: x'], 'description'))
  assert_equal('', util.Frontmatter(['---', 'description: >', '  long', '---'], 'description'))
  assert_equal(60, strcharlen(util.Frontmatter(['---', 'description: ' .. repeat('x', 90), '---'], 'description')))
enddef

def g:Test_FindImageMentions()
  assert_equal([{path: 'a.png', media: 'image/png'}, {path: 'dir/b.JPG', media: 'image/jpeg'}],
    util.FindImageMentions('look at @a.png and @dir/b.JPG, plus @a.png again'))
  assert_equal([{path: '/tmp/x.webp', media: 'image/webp'}], util.FindImageMentions("@/tmp/x.webp\nthanks"))
  assert_equal([], util.FindImageMentions('mail me@x.png or @notes.txt or a.png'))
enddef
