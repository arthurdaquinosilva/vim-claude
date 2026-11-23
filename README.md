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
  sessions in this directory), `:ClaudeContinue` (the latest one), `:ClaudeFork`
  (branch into a new session), `:ClaudeStop`, `:ClaudeModel`, `:ClaudeMode`. A
  conversation stays in the directory it started in, whatever you `:cd` to.
- **Rewind.** `:ClaudeRewind` (`<Leader>cu`, or `/rewind`) restores your files
  to how they were before any message of the session, after showing which
  files would change. The conversation is kept.
- **Shell and images.** `!git status` in the input box runs the command in
  your shell, shows the output, and tells Claude about it with your next
  message. `@screenshot.png` attaches the image itself.
- **Type ahead.** Messages sent while Claude is working are queued and go
  out in order when it finishes (`:ClaudeUnqueue` drops them).
- **Input history.** `Ctrl-P` and `Ctrl-N` step through earlier messages and
  `Ctrl-R` searches them. History is kept per project between Vim sessions.

## What it looks like

Claude wants to edit a file; the popup shows exactly what changes:

```text
  1 def greet(name):                               |❯ You:                                         18:54
  2     return "Hello, " + name                    |
  3                                                |  Add a type hint and a docstring to greet in @app.
  4                                                |  py#L1-2
  5 def main():                                    |
  6     print(greet("world"))                      |  ↳ attached `app.py` (lines 1-2)
  7                                                |
  8                                                |✻ Claude:  ⠴ waiting for you…                  18:54
  9 if __name__ == "__main__":                     |
 10     main()                                     |  ● Edit app.py
~              ╔ Edit app.py ══════════════════════════════════════════════════════════╗
~              ║ - def greet(name):                                                    ║
~              ║ -     return "Hello, " + name                                         ║
~              ║ + def greet(name: str) -> str:                                        ║
~              ║ +     """Return a greeting for the given name."""                     ║
~              ║ +     return "Hello, " + name                                         ║
~              ║                                                                       ║
~              ║ [y] allow   [a] always this session   [e] accept all edits   [n] deny ║
~              ╚═══════════════════════════════════════════════════════════════════════╝
~                                                  |  ──────────────────────────────────────────────────
~                                                  |❯ Claude is working… (Enter queues your message)
~                                                  |  ──────────────────────────────────────────────────
app.py                           1,1            All               ⠴ waiting for you… · ask before edits
```

After you allow it, the result is shown under the call, with a numbered diff:

```text
  1 def greet(name: str) -> str:                   |
  2     """Return a greeting for the given name."""|✻ Claude:                                      18:54
  3     return "Hello, " + name                    |
  4                                                |  ● Edit app.py
  5                                                |
  6 def main():                                    |    ⎿ Updated app.py with 2 additions and 1 removal
  7     print(greet("world"))                      |       1 - def greet(name):
  8                                                |       1 + def greet(name: str) -> str:
  9                                                |       2 +     """Return a greeting for the given
 10 if __name__ == "__main__":                     |       name."""
 11     main()                                     |       3       return "Hello, " + name
~                                                  |
~                                                  |  I updated `greet` in `app.py` with a type hint
~                                                  |  and a docstring:
~                                                  |
~                                                  |  ```python
~                                                  |  def greet(name: str) -> str:
~                                                  |      """Return a greeting for the given name."""
~                                                  |      return "Hello, " + name
~                                                  |  ```
~                                                  |
~                                                  |  I didn't run the file or any tests.
~                                                  |
~                                                  |  ── 9.9s
~                                                  |  ──────────────────────────────────────────────────
~                                                  |  ──────────────────────────────────────────────────
~                                                  |❯ Ask Claude…
~                                                  |  ──────────────────────────────────────────────────
app.py                           1,1            All   app.py:1   sonnet-5-5 · ctx 2% · ask before edits
```

## Install

Requires Vim 9.0+ with `+job +channel +timers +popupwin +textprop` (tested on
9.1.0016, the Vim in Ubuntu 24.04 LTS, and the latest release; Neovim and
Windows are not supported) and
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
| `<Leader>cu`         | rewind files to an earlier message        |

In the input box, `Enter` sends, `Ctrl-J` or `Shift-Enter` inserts a newline and
`Ctrl-C` stops.
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
