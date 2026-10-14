vim9script
if exists('b:current_syntax')
  finish
endif
runtime! syntax/markdown.vim
unlet! b:current_syntax
silent! syntax clear markdownError
syntax match claudeMention /\%(^\|\s\)\zs@\S\+/
highlight default link claudeMention Directory
b:current_syntax = 'claudeinput'
