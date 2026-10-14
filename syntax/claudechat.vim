vim9script
# Chat transcript: Markdown plus speaker headers and tool/status lines.
if exists('b:current_syntax')
  finish
endif

runtime! syntax/markdown.vim
unlet! b:current_syntax
# Stray `_`/`*` in prose are common in replies; don't paint them as errors.
silent! syntax clear markdownError

syntax match claudeUser   /^▌ You$/
syntax match claudeClaude /^▌ Claude$/
syntax match claudeTool   /^  ● .*$/
syntax match claudeToolErr /^    ⎿ .*$/
syntax match claudeAttach /^  ↳ .*$/
syntax match claudeError  /^  [✖!] .*$/
syntax match claudeOk     /^  [✓✗■] .*$/
syntax match claudeFooter /^  ── .*$/

highlight default link claudeUser    Statement
highlight default link claudeClaude  Special
highlight default link claudeTool    Comment
highlight default link claudeToolErr WarningMsg
highlight default link claudeAttach  Directory
highlight default link claudeError   ErrorMsg
highlight default link claudeOk      MoreMsg
highlight default link claudeFooter  NonText

b:current_syntax = 'claudechat'
