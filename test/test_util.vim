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
  assert_equal(30, strdisplaywidth(s))
  assert_match('^── Claude ─\+ haiku ──$', s)
  # Too narrow for the long left: falls back to the short one.
  s = Plain(util.Rule([[['a very long hint text here', '']], [['short', '']]], [['x', '']], 20, 'R'))
  assert_match('^── short ─\+ x ──$', s)
  assert_equal(20, strdisplaywidth(s))
  # Too narrow for anything: right side dropped, then plain rule.
  assert_equal(12, strdisplaywidth(Plain(util.Rule([[['abc', '']]], [['wide right', '']], 12, 'R'))))
  assert_equal('───', Plain(util.Rule([[['abcdef', '']]], [], 3, 'R')))
  assert_match('100%%', util.Rule([[['100%', '']]], [], 20, 'R'))
enddef

def g:Test_DisplayRows()
  assert_equal(1, util.DisplayRows([''], 20, 2))
  assert_equal(2, util.DisplayRows([repeat('x', 19)], 20, 2))
  assert_equal(3, util.DisplayRows(['a', 'b', 'c'], 20, 2))
enddef
