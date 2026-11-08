# Current status — personal alpha

Updated 2026-11-08. This is a personal-use application. Implementation milestones describe available code;
they do not establish that every provider, OS permission flow or production service has been validated.

| Area | Implemented | Acceptance still pending |
|---|---|---|
| Build | Projects/CLI sessions, tools, approvals, plans, rewind, reviews, git/worktrees, terminal, MCP, subagents, sandboxed commands, `/goal`, auto review, Claude Code/Codex tasks | Daily real-model work on Piopio; large repositories; real OAuth MCP and project-skill combinations; installs and builds inside the sandbox; a real Claude Code/Codex task |
| Chat | Streaming, attachments, branches, export, Quick Chat, New project makes a folder in ~/Piopio (AGENTS.md, shared NOTES.md), global search | A week of daily use; provider/web-search compatibility; a real project with several conversations; long conversation usability |
| Local Agents | Definitions, conversations, memory, schedules/reminders, approvals, budgets, Mac-app abilities, peers | Real schedules across sleep/wake; permission prompts and real Mac apps; paid-model budgets and peer behavior |
| Reliability | Conservative command rules, private-address checks with DNS pinning, persistent drafts, input receipts, verified offline backup/restore | Extended failure/recovery soak and usability review with personal data |
| Distribution | Bundled engine/Node, release scripts, background engine and update infrastructure | Developer ID/notarization/Gatekeeper validation and public distribution |
| Cloud | Local workerd spikes with hibernation, alarms and the shared agent runtime | Production account deployment, authenticated gateway, deployment UI, channels, real billing and long runs |

## Automated checks

`.github/workflows/checks.yml` runs TypeScript builds, type checking and scripted tests on Linux.
Swift tests and the app build require an Apple-silicon runner with macOS 27, Xcode 27 and XcodeGen. Register a
self-hosted runner with `piopio-macos-27`, `macOS` and `ARM64` labels and set the repository variable
`PIOPIO_SWIFT_CI=true` to enable that job on pushes/manual runs. Pull requests run the hosted TypeScript job; unreviewed pull-request code never runs on the personal Mac runner. Until configured, Swift CI is explicitly skipped; local checks remain
`scripts/swift-test.sh` and `scripts/build-app.sh`.

The scripted suites don't need provider keys. Live-provider and fixture-recording tests are opt-in. App smoke
tests use temporary engine data, but launch a real native window and require a logged-in macOS GUI session.

## Latest local verification

The TypeScript suite passes (203 tests; opt-in tests skipped), as do Swift package tests (41 tests).
The native app builds, and `scripts/recovery-smoke.sh` verifies failed-send draft recovery, offline backup and
restore across all three areas, restored topic search, external project preservation, and duplicate-free Build
history discovery using a scripted model and scratch data. Compact Home/chat and dark agent layouts have also
been captured and inspected. This does not replace the real-provider, OS-permission or VoiceOver checks below.

## Personal acceptance checklist

- [ ] Build: complete one real change, approve/deny commands, inspect diffs, rewind chat and files, resume after restart.
- [ ] Chat: send images/text/PDFs, edit/regenerate, switch away with a draft, reconnect after a failed send and retry once.
- [ ] A New project folder: 3+ conversations; verify they follow AGENTS.md, keep NOTES.md and read what another one noted; Continue in from a loose chat.
- [ ] Agents: run a real schedule, sleep/wake the Mac, close the window, quit with and without background mode, and inspect the next run.
- [ ] Approvals: restart/reconnect while waiting and verify that the displayed decision matches the executed action.
- [ ] Costs: compare provider billing with its stated scope; verify web/utility requests and unavailable pricing.
- [ ] Backup: restore a scratch backup with chats, topics, agent memory/definitions and Build history; inspect the retained previous folder.
- [ ] Accessibility: use keyboard and VoiceOver through composer/search/approvals; inspect narrow layouts, increased contrast and Reduce Motion.

## Boundaries

- Build policy is an approval aid. In Ask and Auto-edit, `bash` also runs in macOS's sandbox (Settings › Approvals,
  default on): an approved command can read and use the network but only write in the project, temp folders and package
  caches; `outside_project` asks. Full auto, `edit`/`write` (path checks only), MCP servers and the terminal tab aren't
  sandboxed. File paths are judged where they really are (symlinks resolved), and subagents keep their parent's
  profile and tools turned off. Unknown shell syntax asks again.
- Search covers active conversation branches. It is not a source-code index or an index of every historical branch.
- Agents on this Mac cannot run while it is asleep/off. Mac-app tools need the native app and OS permissions.
- Additional request costs are recorded from this version onward. Unknown pricing is excluded, not treated as free.
  An agent's budget counts its web searches and learned-fact requests too; it's a soft cap that stops new turns
  and runs once reached.
- Background model work (titles, summaries, suggestions, commit messages, learned facts) uses the provider each
  conversation already uses (local stays local, OpenRouter uses its small model). Settings › Models can pin another
  model, Apple's on-device model, or Off. Web search sends the search words to OpenRouter. See 07-shared §1.3.
- Conversation first, phases 1–3 (spec 18): notebooks are gone; a project can have no folder; a conversation can
  become an agent (File › Turn Conversation into Agent…).
  Home is the one start, with the project and permissions in the box; Read only replaces the Chat lens (folders
  of documents start in it); a chat can continue in a project folder or move into a project without one.
- Agent definitions refuse fields that nothing runs yet (http_request, codemode, files, tools.mcp, channels) on save.
- Cloud and channels remain separate roadmap work. See [09-roadmap.md](spec/09-roadmap.md) for historical milestones.
