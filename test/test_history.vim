vim9script
import autoload 'claude.vim'

# A fresh Vim: the history file written by an earlier session is loaded.
# Each test works in its own project directory, so each loads its own history.
def Project()
  var dir = tempname() .. '-proj'
  mkdir(dir, 'p')
  execute 'cd ' .. fnameescape(dir)
  g:claude_history_dir = tempname()
enddef

def Seed(entries: list<string>)
  Project()
  var key = substitute(getcwd(), '[^A-Za-z0-9]', '-', 'g')
  mkdir(g:claude_history_dir, 'p')
  writefile(mapnew(entries, (_, e) => json_encode(e)), g:claude_history_dir .. '/' .. key .. '.jsonl')
enddef

def Input(): list<string>
  return getbufline(claude.Debug().input_buf, 1, '$')
enddef

def g:Test_history_from_an_earlier_session_is_reachable_with_ctrl_p()
  Seed(['old one', "old two\nsecond line"])
  claude.Open()
  feedkeys("\<C-p>", 'tx')
  assert_equal(['old two', 'second line'], Input())
  feedkeys("\<C-p>", 'tx')
  assert_equal(['old one'], Input())
enddef

def g:Test_ctrl_r_searches_the_history()
  Seed(['fix the parser bug', 'write release notes', 'explain the parser'])
  claude.Open()
  feedkeys("\<C-r>rel\<CR>", 'tx')
  assert_equal(['write release notes'], Input())
  # Moving down picks the next match; Escape changes nothing.
  setbufline(claude.Debug().input_buf, 1, 'draft')
  feedkeys("\<C-r>pars\<C-n>\<CR>", 'tx')
  assert_equal(['fix the parser bug'], Input())
  setbufline(claude.Debug().input_buf, 1, 'draft')
  feedkeys("\<C-r>pars\<Esc>", 'tx')
  assert_equal(['draft'], Input())
enddef

def g:Test_corrupt_history_lines_are_skipped()
  Project()
  var key = substitute(getcwd(), '[^A-Za-z0-9]', '-', 'g')
  mkdir(g:claude_history_dir, 'p')
  writefile(['not json', '"good"', '123', '""'], g:claude_history_dir .. '/' .. key .. '.jsonl')
  claude.Open()
  feedkeys("\<C-p>", 'tx')
  assert_equal(['good'], Input())
enddef
