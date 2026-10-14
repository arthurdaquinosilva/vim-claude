# claude.vim

A Claude Code side panel for Vim 9: a streaming chat, explain-selection,
inline edits reviewed as a diff, and permission prompts. It aims to work like
the VS Code extension, using Vim buffers and windows.

The plugin runs your installed `claude` CLI (`claude -p` with stream-json), so
it uses your existing login. Claude can read and edit files in your project,
run commands when you allow it, and keep context across messages.

## Features

- **Chat panel.** The transcript is a normal buffer, so scrolling, searching,
  yanking and `gf` all work. While a reply streams, a window at the bottom
  follows it and a window you scrolled back stays put.
- **Explain selection.** `<Leader>ce` sends the selected code with its path and
  line numbers.
- **Ask about or attach code.** `<Leader>ca` adds `@file#L10-24` to the input box.
  Unsaved buffer contents are attached. Typing `@` completes project files.
- **Inline edit.** `<Leader>ci` asks for an instruction, then shows a diff tab.
  `ga` accepts as one undo step, `gr` rejects, and `do`/`dp` take single hunks.
- **Permissions.** When Claude is blocked from editing or running a command, a
  popup lets you allow it for the session, switch to acceptEdits, or deny.
  After you allow, Claude retries and changed buffers are reloaded.
- **Tool activity.** Lines such as `● Read src/app.py` and `● Bash npm test`
  show what Claude did. The statusline has a spinner, the model and the
  permission mode.
- **Session management.** `:ClaudeNew`, `:ClaudeResume` (picks from earlier
  sessions in this directory), `:ClaudeStop`, `:ClaudeModel`, `:ClaudeMode`.
- **Input history.** `Ctrl-P` and `Ctrl-N` in the input box.

## Install

Requires Vim 9.0+ (`+job +channel +timers +popupwin`) and
[Claude Code](https://docs.claude.com/en/docs/claude-code) logged in.

```sh
# native packages
git clone https://github.com/arthurdaquinosilva/vim-claude ~/.vim/pack/claude/start/vim-claude
vim -c 'helptags ~/.vim/pack/claude/start/vim-claude/doc | q'
```

Or with [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'arthurdaquinosilva/vim-claude'
```

## Quick start

| Keys (default)       | Action                                    |
|----------------------|-------------------------------------------|
| `<Leader>cc`         | toggle panel (visual: add selection)      |
| `<Leader>ce`         | explain selection (normal mode: the file) |
| `<Leader>ca`         | add selection or file to the input box    |
| `<Leader>ci`         | inline edit selection or line             |
| `<Leader>cn` / `cr`  | new chat / resume chat                    |
| `<Leader>cm` / `cp`  | choose model / permission mode            |

In the input box, `Enter` sends, `Ctrl-J` inserts a newline and `Ctrl-C` stops.
In the transcript, `]]`/`[[` jump between messages, `gy` yanks a code block and
`q` closes the panel.

```vim
let g:claude_model = 'sonnet'               " default: the CLI default
let g:claude_permission_mode = 'default'    " or acceptEdits / plan
let g:claude_position = 'right'             " or left / bottom
let g:markdown_fenced_languages = ['python', 'javascript', 'vim', 'sh']
```

The full reference is in `:help claude`.

## Tests

```sh
test/run.sh            # all suites, headless Vim, uses a fake claude CLI
```
