vim9script
# claude.vim — Claude Code chat panel, explain and inline edit for Vim 9.
# See :help claude

if exists('g:loaded_claude') || v:version < 900
  finish
endif
g:loaded_claude = 1

import autoload 'claude.vim'
import autoload 'claude/edit.vim'

command! -nargs=* -range Claude claude.Command(<q-args>, <range>, <line1>, <line2>)
command! -nargs=0 ClaudeToggle claude.Toggle()
command! -nargs=0 ClaudeOpen claude.Open()
command! -nargs=0 ClaudeClose claude.Close()
command! -nargs=0 -range=% ClaudeExplain claude.Explain(<line1>, <line2>)
command! -nargs=0 -range=% ClaudeAdd claude.AddToInput(<line1>, <line2>)
command! -nargs=* -range ClaudeEdit edit.Start(<line1>, <line2>, <q-args>)
command! -nargs=0 ClaudeEditCancel edit.Cancel()
command! -nargs=0 ClaudeAccept edit.Accept()
command! -nargs=0 ClaudeReject edit.Reject()
command! -nargs=0 ClaudeNew claude.NewChat()
command! -nargs=0 ClaudeStop claude.Stop()
command! -nargs=0 ClaudeResume claude.Resume()
command! -nargs=? -complete=custom,claude#CompleteModels ClaudeModel claude.SetModel(<q-args>)
command! -nargs=? -complete=custom,claude#CompleteModes ClaudeMode claude.SetMode(<q-args>)

# Remember where the user was, so messages can mention the file in focus.
def Track()
  if &buftype == '' && bufname() != ''
    g:claude_last_ctx = {file: expand('%:p'), line: line('.'), total: line('$')}
  endif
enddef

augroup claude_track
  autocmd!
  autocmd WinLeave,BufLeave * Track()
augroup END

if !get(g:, 'claude_no_mappings', false)
  var p = get(g:, 'claude_map_prefix', '<Leader>c')
  for [key, cmd] in [['c', 'ClaudeToggle'], ['n', 'ClaudeNew'], ['r', 'ClaudeResume'],
      ['m', 'ClaudeModel'], ['p', 'ClaudeMode'], ['e', 'ClaudeExplain'], ['a', 'ClaudeAdd']]
    execute 'nnoremap <silent> ' .. p .. key .. ' <Cmd>' .. cmd .. '<CR>'
  endfor
  execute 'nnoremap <silent> ' .. p .. 'i :ClaudeEdit<CR>'
  for [key, cmd] in [['c', 'Claude'], ['e', 'ClaudeExplain'], ['a', 'ClaudeAdd'], ['i', 'ClaudeEdit']]
    execute 'xnoremap <silent> ' .. p .. key .. ' :' .. cmd .. '<CR>'
  endfor
endif
