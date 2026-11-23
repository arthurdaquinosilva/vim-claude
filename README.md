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
- **Permissions.** Like the CLI, Claude asks before it edits or runs
  something and waits. A popup shows the diff or command; `y` allows, `a`
  allows it for the session, `e` accepts all edits, `n` denies. Nothing
  restarts, and changed buffers are reloaded.
- **Plan mode and questions.** `Shift-Tab` cycles default, auto-accept and
  plan mode like the CLI. When Claude presents a plan you approve it (with
  or without auto-accepting edits) or ask it to keep planning, and its
  multiple-choice questions appear as a popup.
- **Interrupt.** `Ctrl-C` stops a reply in under a second and keeps the
  session (and its prompt cache) alive.
- **Tool activity.** `● Read src/app.py`, `● Edit …` and `● Bash npm test`
  show what Claude did, with the result under each: numbered diffs for edits,
  the first lines of command output, line counts for reads and todo
  checklists. The statusline has a spinner, the model, how full the context window is and
  the permission mode.
- **Slash commands.** Type `/` for a completion menu of everything the CLI
  supports: built-ins such as `/compact`, `/context` and `/init`, plus your
  custom commands and skills, with their descriptions. `/clear`, `/model`,
  `/permissions`, `/resume`, `/help` and `/exit` are handled by the plugin.
- **Session management.** `:ClaudeNew`, `:ClaudeResume` (picks from earlier
  sessions in this directory), `:ClaudeStop`, `:ClaudeModel`, `:ClaudeMode`.
- **Type ahead.** Messages sent while Claude is working are queued and go
  out in order when it finishes (`:ClaudeUnqueue` drops them).
- **Input history.** `Ctrl-P` and `Ctrl-N` step through earlier messages and
  `Ctrl-R` searches them. History is kept per project between Vim sessions.

## Install

Requires Vim 9.1.0120+ (`+job +channel +timers +popupwin +textprop`; Neovim
and Windows are not supported) and
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
In the transcript, `]]`/`[[` jump between messages, `gy` yanks a code block,
selecting part of a reply and pressing `Enter` quotes it into the input box so
you can ask about it, and `q` closes the panel.

```vim
let g:claude_model = 'sonnet'               " default: the CLI default
let g:claude_permission_mode = 'default'    " or acceptEdits / plan
let g:claude_position = 'right'             " or left / bottom
let g:claude_map_prefix = '<Leader>c'       " prefix for the mappings above
let g:markdown_fenced_languages = ['python', 'javascript', 'vim', 'sh']
```

Run `:ClaudeHealth` if something does not work, and set
`g:claude_debug_log = '/tmp/claude.log'` to capture the raw CLI events for a
bug report. The full reference is in `:help claude`.

## Tests

```sh
test/run.sh            # all suites, headless Vim, uses a fake claude CLI
```
