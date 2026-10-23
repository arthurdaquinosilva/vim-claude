vim9script

# vim-plug sources plugin/ files again after :PlugUpdate. The early finish of
# the loaded guard must not leave autocmds and commands pointing at deleted
# functions and imports.
def g:Test_resourcing_plugin_keeps_autocmds_and_commands()
  execute 'source ' .. fnameescape(globpath(&rtp, 'plugin/claude.vim', 0, 1)[0])
  split
  wincmd p
  wincmd p
  close
  assert_equal(2, exists(':ClaudeToggle'))
  assert_equal(1, exists('#claude_track#WinLeave'))
enddef
