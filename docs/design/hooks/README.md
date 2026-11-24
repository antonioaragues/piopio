# Your hooks (PAR6)

`Hooks.html` (published as an artifact), 2026-11-24, two rounds:

1. Two ways to make a hook (a sentence, a table), how hooks show in the conversation, and a project's hooks, stored in
   Claude Code's format in a `.pi/hooks.json`.
2. After asking whether that fits pi: it didn't quite. In pi a hook *is* an extension (its docs list permission gates
   and path protection as extension examples), and pi reads no hooks file. **Decided:** each hook is a small pi
   extension file written from the sentence (design A); Claude Code's hooks come in by import, not as the format.

## As built (2026-11-24)

- **Engine** (`packages/engine/src/user-hooks.ts`): a hook spec (when, tools, files, command, run, stop) becomes a
  self-contained `hook-<name>.ts` in `~/.pi/agent/extensions/` or a project's `.pi/extensions/` (pi looks one level
  deep, so no `hooks/` folder). Its first line is the sentence, its second the spec as JSON; the file reads back as a
  hook only while its code is exactly what Piopio wrote, otherwise it's listed as code and never rewritten. Off is
  `.ts.off`. Three templates on pi's events: before (`tool_call`: stop with a message, or run a command that stops it by
  exiting 2), after (`tool_result`: a failure is appended to the result for the model), on finish
  (`agent_before_settle`: a failing check sends its output and asks for one more turn, three times per message, only
  when the answer changed matching files). Commands get `$FILE`, `$COMMAND` and the call as JSON on stdin, 60 s at most.
- **Methods:** `hooks.list` (with a project's Claude Code hooks to import), `hooks.save`, `hooks.toggle`,
  `hooks.delete` (to the Trash), `hooks.try` (once, on a file the glob matches), `hooks.importClaude`.
- **App:** Settings › Extensions › Your hooks, above Your skills; a project's hooks in its page under Settings ›
  Approvals, with the Claude Code import offer. The sheet builds the sentence (Before / After / When Piopio finishes,
  then edits or writes / runs a command / any tool) and has Try it.
- **Tests** (`test/user-hooks.test.ts`): sentence and round trip, files and toggling, the Claude Code mapping, and a
  real Build session where pi loads the generated files: a force push stopped, a write logged, a failing check sent
  back exactly three times. The three templates also type-check against pi's own types.

**Different from the mockup / not built yet:**
- No "formatted by your hook" line under a step when a hook runs fine: success is quiet; a stop shows on the tool's
  card and a failure in its result or as a note.
- Hook counts ("ran 14 times today") aren't kept.
- `/learn` proposing a hook, and hooks for agents' scheduled runs.
