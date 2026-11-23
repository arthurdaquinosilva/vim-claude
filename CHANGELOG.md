# Changelog

## Unreleased

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
