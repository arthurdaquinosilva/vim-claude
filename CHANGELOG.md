# Changelog

## Unreleased

- Choose where the panel opens per use: `:ClaudeOpen {pos}`, `:ClaudeToggle {pos}`
  (left, right, top, bottom, vertical, horizontal), the `:vertical`,
  `:horizontal`, `:topleft` and `:botright` modifiers, and `:ClaudeMove` to move
  an open panel. New `top` placement; each tab keeps its own.
- Marks set in the transcript (`ma`, `mB`, ...) are shown in its sign column,
  so you can see them and jump between them (`'a`, `]'`, `['`).
  `g:claude_mark_signs` controls it.
- Shift-Enter inserts a newline under tmux and similar terminals: the plugin now
  asks the terminal to report modified keys while the input box is focused
  (`g:claude_extended_keys`), instead of Shift-Enter arriving as a plain Enter
  and sending the message.
- Fix: starting a new line in the input box (`Ctrl-J`, Shift-Enter, `o`, `O`) no
  longer scrolls the lines above out of view until the next keystroke. The
  window now grows before the line is inserted and keeps a spare row while
  the last line is empty.
- The status bar in a narrow panel drops the model, then the context figure,
  and finally the `ctrl-c` hint, so what Claude is doing is never cut off.
- README: a text capture of the real UI.
- Robustness: the `@` file list is built in the background (git, then find,
  then glob) so a large repository no longer freezes Vim; a process exit is
  reported only after its last output was handled; a cancelled inline edit can
  no longer finish the next one; inline edits time out (`g:claude_edit_timeout`)
  and refuse huge selections (`g:claude_edit_max_lines`).
- Usage-limit events from the CLI are shown (once for warnings).
- No longer needs `getregion()`, so Vim 9.0 is enough. CI runs Vim 9.1.0016
  (Ubuntu 24.04 LTS) and the latest release.
- `!command` in the input runs in your shell and shows the output; Claude is
  told what you ran with your next message.
- `@image.png` mentions attach the image (png, jpg, gif, webp).
- `:ClaudeContinue` and `:ClaudeFork` (`/continue`, `/fork`). A conversation
  stays in the directory it started in; a `:cd` no longer moves it.
- `@` completion also offers directories.
- `:ClaudeRewind` (`<Leader>cu`, `/rewind`): restore files to before any
  message of the session, with a preview of what changes. Uses the CLI's own
  file checkpoints (`g:claude_checkpoints`).
- Type ahead: messages sent while Claude is busy are queued and sent in order
  (`:ClaudeUnqueue` clears them).
- Input history is saved per project between Vim sessions, and `Ctrl-R`
  searches it (`g:claude_history`, `g:claude_history_dir`).
- Model and permission-mode changes apply to the running session (no restart,
  no lost prompt cache). Shift-Tab cycles the mode; bypassPermissions asks
  for confirmation.
- Plan approval popup (approve, approve and auto-accept edits, keep planning)
  and a popup for the CLI's multiple-choice questions (AskUserQuestion).
- The statusline shows how full the context window is, with a warning near
  the limit; `g:claude_show_cost` adds the session cost.
- Sending to a process that just died restarts it once instead of failing.
- Slash commands: `/` completes the commands the CLI reports (built-ins,
  custom commands, skills) with descriptions. Commands are sent verbatim
  (no editor context), unknown ones are refused locally, and `/clear`,
  `/model`, `/permissions`, `/resume`, `/help`, `/exit` are handled in Vim.
  `/compact` shows its progress and a before/after token count.
- Tool results are shown under each call: numbered diffs (from the CLI's own
  patch) for Edit/MultiEdit/Write, the first lines of Bash output, line
  counts for Read/Grep/Glob and a checklist for TodoWrite. See
  `g:claude_tool_details` and `g:claude_tool_lines`.
- Permission prompts are now synchronous (`--permission-prompt-tool stdio`):
  Claude waits while a popup shows the diff or command, and the answer
  (allow, allow for the session, accept edits, deny) applies in place, with
  no retry turn and no restart. The previous flow remains available with
  `g:claude_permission_prompt = 'retry'`.
- `Ctrl-C` sends a control interrupt instead of killing the process, so the
  session and prompt cache survive; a stuck process is killed after 3s.
- Stopping a process no longer blocks Vim.
- Require the Vim features the plugin uses (`+job +channel +timers +popupwin
  +textprop`, `getregion()`) and say so clearly when they are missing.
- Add `:ClaudeHealth` to check the environment, and `g:claude_debug_log` to
  record the raw CLI event stream for bug reports.
- Add a LICENSE (MIT), CI, and ignore editor swap files.
