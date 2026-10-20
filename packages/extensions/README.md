# @piopio/pi-extensions

Pi extensions shipped with Piopio's Build mode ([docs/spec/05-build.md §4](../../docs/spec/05-build.md)). Each one takes an optional bridge: Piopio's engine passes one (prompt cards, per-project rules); without it, the extension falls back to pi's own dialogs, so it also works in the pi CLI.

| Extension | Status | What it does |
|---|---|---|
| `approvalsExtension` | ✅ 2.2 | Asks before tool calls the approval mode doesn't allow (`ask`, `auto_edit`, `full_auto`), with "always allow" rules (command prefix, tool, path glob) and a deny-list that always asks (sudo, force-push, `curl … \| sh`, keychain, `~/.ssh`/`~/.aws`, `rm -rf` outside the project). In the CLI the mode comes from `PIOPIO_APPROVAL_MODE`. |
| `notifyExtension` | ✅ 2.2 | `ask_user(question, options?)` waits for an answer; `notify_user(message)` tells you something. |
| `checkpointsExtension` | ✅ 2.3 | Before the first `edit`/`write`/`bash` of each agent run, asks the host to snapshot the working tree. Without a bridge (pi CLI) it does nothing. |
| `todosExtension` | ✅ 2.5 | `todo(items)`: the agent's checklist, replaced whole on each call. The list lives in the call's arguments, so it follows branches. |
| `planExtension` | ✅ 2.5 | Plan mode: read-only exploration (edits/writes and non-read-only commands are refused), a system-prompt note, and `propose_plan(summary, steps)`. Approving turns plan mode off. `/plan` toggles it; `PIOPIO_PLAN=1` in the CLI. |
| `subagentsExtension` | ✅ 2.5 | `task(description, prompt)`: a subagent with its own context. Piopio runs it as a child Build session (openable, same approval mode, cost counted in the parent, at most 3 at a time). Without a bridge it isn't registered. |

The policy (`decide`, `deniedCommand`, `suggestCommandRule`) is pure and tested in `test/policy.test.ts`.
