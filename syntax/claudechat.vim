vim9script
# Chat transcript: Markdown plus speaker headers and tool/status lines.
if exists('b:current_syntax')
  finish
endif

runtime! syntax/markdown.vim
unlet! b:current_syntax
# Stray `_`/`*` in prose are common in replies; don't paint them as errors.
silent! syntax clear markdownError

syntax match claudeUser   /^❯ You$/
syntax match claudeClaude /^✻ Claude$/
syntax match claudeTool   /^  ● .*$/
syntax match claudeToolErr /^    ⎿ .*$/
syntax match claudeAttach /^  ↳ .*$/
syntax match claudeError  /^  [✖!] .*$/
syntax match claudeOk     /^  [✓✗■] .*$/
syntax match claudeFooter /^  ── .*$/
# Box tables are aligned by character count: their cells hold plain text
# only, and each row is a single item so no Markdown rule applies inside.
syntax match claudeTableRow /^[┌├└│].*[┐┤┘│]$/ contains=claudeTableBorder
syntax match claudeTableBorder /[┌┬┐├┼┤└┴┘─│]/ contained
# Inline code in tables is highlighted with text properties (claudeTableCode).

highlight default link claudeUser    ClaudeYou
highlight default link claudeClaude  ClaudeAssistant
highlight default link claudeTool    Comment
highlight default link claudeToolErr WarningMsg
highlight default link claudeAttach  Directory
highlight default link claudeError   ErrorMsg
highlight default link claudeOk      MoreMsg
highlight default link claudeFooter  NonText
highlight default link claudeTableBorder Comment

# Markdown is loaded now, so its code group's color can be picked up.
claude#LinkCodeHighlight()

b:current_syntax = 'claudechat'
