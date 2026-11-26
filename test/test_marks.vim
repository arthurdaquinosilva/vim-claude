vim9script
import autoload 'claude.vim'

# A chat with enough lines to put marks on.
def Chat(): number
  claude.NewChat()
  claude.Open()
  claude.Send('TABLE one')
  g:WaitFor('!claude#Busy()')
  var win = win_findbuf(claude.Debug().chat_buf)[0]
  win_gotoid(win)
  return win
enddef

def Signs(): list<list<any>>
  var s = sign_getplaced(claude.Debug().chat_buf, {group: 'claude_marks'})[0].signs
  return sort(mapnew(s, (_, x) => [x.lnum, x.name]), (a, b) => a[0] - b[0])
enddef

def SignText(name: string): string
  return trim(sign_getdefined(name)[0].text)
enddef

def Mark(lnum: number, letter: string)
  cursor(lnum, 1)
  feedkeys('m' .. letter, 'tx')
enddef

def g:Test_a_mark_shows_in_the_sign_column()
  Chat()
  assert_equal('yes', &l:signcolumn)
  assert_equal([], Signs())
  Mark(3, 'a')
  assert_equal([[3, 'ClaudeMark_a']], Signs())
  assert_equal('a', SignText('ClaudeMark_a'))
  # It is a plain mark: 'a jumps there.
  cursor(1, 1)
  feedkeys("'a", 'tx')
  assert_equal(3, line('.'))
  # Another mark elsewhere, and moving a mark moves its sign.
  Mark(6, 'b')
  assert_equal([[3, 'ClaudeMark_a'], [6, 'ClaudeMark_b']], Signs())
  Mark(5, 'a')
  assert_equal([[5, 'ClaudeMark_a'], [6, 'ClaudeMark_b']], Signs())
enddef

def g:Test_several_marks_on_one_line_share_a_sign()
  Chat()
  Mark(4, 'a')
  Mark(4, 'c')
  assert_equal([[4, 'ClaudeMark_ac']], Signs())
  assert_equal('ac', SignText('ClaudeMark_ac'))
  Mark(4, 'b')
  assert_equal([[4, 'ClaudeMark_abc']], Signs())
  assert_equal('a+', SignText('ClaudeMark_abc'))
  # Taking one away updates the sign.
  execute 'delmarks b'
  doautocmd CursorMoved
  assert_equal([[4, 'ClaudeMark_ac']], Signs())
enddef

def g:Test_uppercase_marks_show_only_when_they_point_here()
  Chat()
  Mark(3, 'A')
  assert_equal([[3, 'ClaudeMark_A']], Signs())
  # A file mark that points somewhere else is not this buffer's business.
  new
  setline(1, ['x', 'y'])
  cursor(2, 1)
  normal! mB
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  doautocmd CursorMoved
  assert_equal([[3, 'ClaudeMark_A']], Signs())
  bwipeout!
  execute 'delmarks A B'
enddef

def g:Test_deleting_marks_and_clearing_the_chat_removes_the_signs()
  Chat()
  Mark(3, 'a')
  Mark(5, 'b')
  execute 'delmarks a'
  doautocmd CursorMoved
  assert_equal([[5, 'ClaudeMark_b']], Signs())
  # New conversation: the lines (and their marks) are gone.
  claude.NewChat()
  assert_equal([], Signs())
enddef

def g:Test_other_keys_after_m_leave_no_mark_and_no_error()
  Chat()
  cursor(4, 1)
  feedkeys("m\<Esc>", 'tx')
  feedkeys('m1', 'tx')
  assert_equal([], Signs())
  assert_equal([], v:errors->filter((_, e) => e =~ 'E\d\+'))
enddef

def g:Test_jumping_between_marks_with_the_usual_keys()
  Chat()
  Mark(3, 'a')
  Mark(6, 'b')
  cursor(1, 1)
  feedkeys("]'", 'tx')
  assert_equal(3, line('.'))
  feedkeys("]'", 'tx')
  assert_equal(6, line('.'))
  feedkeys("['", 'tx')
  assert_equal(3, line('.'))
enddef

def g:Test_mark_sign_column_can_be_automatic_or_off()
  g:claude_mark_signs = false
  Chat()
  assert_equal('no', &l:signcolumn)
  Mark(3, 'a')
  assert_equal([], Signs())
  claude.Close()
  g:claude_mark_signs = 'auto'
  claude.Open()
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  assert_equal('auto', &l:signcolumn)
  unlet g:claude_mark_signs
  claude.Close()
  claude.Open()
  win_gotoid(win_findbuf(claude.Debug().chat_buf)[0])
  assert_equal('yes', &l:signcolumn)
enddef

def g:Test_tables_account_for_the_sign_column()
  g:claude_mark_signs = true
  Chat()
  var win = win_getid()
  var width = winwidth(win)
  var rows = filter(getbufline(claude.Debug().chat_buf, 1, '$'), (_, l) => l =~ '^\s*[┌├└│]')
  assert_true(!empty(rows))
  # Every row fits in what is left once the 2 sign columns are taken.
  assert_true(max(mapnew(rows, (_, l) => strdisplaywidth(l))) <= width - 2, string(rows))
  unlet g:claude_mark_signs
enddef
