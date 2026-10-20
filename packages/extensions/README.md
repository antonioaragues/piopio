# @piopio/pi-extensions

Pi extensions shipped with Piopio's Build mode ([docs/spec/05-build.md §4](../../docs/spec/05-build.md)). Each one takes an optional bridge: Piopio's engine passes one (prompt cards, per-project rules); without it, the extension falls back to pi's own dialogs, so it also works in the pi CLI.

| Extension | Status | What it does |
|---|---|---|
| `approvalsExtension` | ✅ 2.2 | Asks before tool calls the approval mode doesn't allow (`ask`, `auto_edit`, `full_auto`), with "always allow" rules (command prefix, tool, path glob) and a deny-list that always asks (sudo, force-push, `curl … \| sh`, keychain, `~/.ssh`/`~/.aws`, `rm -rf` outside the project). In the CLI the mode comes from `PIOPIO_APPROVAL_MODE`. |
| `notifyExtension` | ✅ 2.2 | `ask_user(question, options?)` waits for an answer; `notify_user(message)` tells you something. |
| checkpoints, todos, subagents, plan | Planned (2.3, 2.5) | |

The policy (`decide`, `deniedCommand`, `suggestCommandRule`) is pure and tested in `test/policy.test.ts`.
