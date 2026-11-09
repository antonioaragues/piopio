# Acceptance pass — real models, real days

The eight items in [status.md § Personal acceptance checklist](status.md#personal-acceptance-checklist) are the gate
before more features. Everything below is built and has scripted tests; what is missing is proof that it works on
this Mac, with a real provider and with real work. This file is the protocol: one scenario per session, 15–45
minutes, using the app the way you normally would.

**Rules**

- Use the model you actually use day to day, not the cheapest one. The point is the model you'd live with.
- Don't fix anything mid-scenario. Write it down in [Issues](#issues) and keep going; a fix turns one observation
  into an experiment about the fix.
- One scenario per sitting. A scenario passes only when every **Pass** line is true.
- When an item passes, tick it in [status.md](status.md) and add the date. If it fails, tick nothing and open an issue.

**Pre-flight** (once, and after any change to the app)

```bash
scripts/build-app.sh Release                                  # the shipped shape: bundled Node + engine
security find-generic-password -s Piopio -a provider.openrouter.apiKey >/dev/null \
  && echo "OpenRouter key: present" || echo "OpenRouter key: missing"   # may ask for the login keychain
tail -f ~/Library/Application\ Support/Piopio/logs/engine.log # second terminal, during every scenario
corepack pnpm test && scripts/swift-test.sh                   # baseline: the scripted suites are green
```

Settings panes, by name: **General**, **Models**, **Connectors**, **Chat**, **Memory**, **Approvals**,
**Backup & costs**, **MCP servers**, **Extensions**, **This Mac & cloud**.

**Evidence** lives outside the repo (it contains personal data): a scratch folder with one file per scenario,
`<date>-<item>.md`, plus screenshots. Paste into `docs/design/feedback/` only the ones that show a bug. On a
failure, keep the last ~50 lines of `engine.log` with the file.

---

## 1 · Build — one real change (30–45 min)

**Setup:** a project with git (Piopio itself is fine), session mode **Auto-edit** (the pill in the header).

1. New conversation in the project. Ask for a small, real change you actually want.
2. When the approval card appears, **Deny** once with a note ("no, use the existing helper"). The agent must read
   the note and change approach, and the tool card must read denied.
3. Approve the next command with **Allow once (⌘↩)** and compare the card's detail with what the tool card shows
   ran. Try **Always for this project** once and check the rule appears in Settings › Approvals.
4. Inspect the change: the tool card's diff, then the inspector's **Changes**. Compare with `git diff` (or
   `git status`) in a terminal — the displayed diff and the disk must agree.
5. Rewind: hover one of your messages → ↶ → choose **Chat and files** and check the file content goes back and
   your message returns to the composer. Do it again on another turn with **Chat only**: the files must stay.
6. Quit Piopio and reopen it. The session must be there, with its tool cards rebuilt, the right branch, and a sane
   context meter. Continue the same conversation one more turn.
7. Optional, if the session offers it: commit with the generated message and check the message describes the diff.

**Pass:** the change is real and on disk, the diff matches `git diff`, deny note reached the model, rewind is exact
in both modes, and the session resumes after a restart.
**Not a failure** (see [status.md § Boundaries](status.md#boundaries)): `edit`/`write`, the terminal tab and MCP
servers aren't sandboxed; unknown shell syntax asks again.
**Evidence:** the approval card, the rewind preview, the diff, the `git diff` output.

## 2 · Chat (20–30 min)

1. New conversation with your usual model. Send an **image**, a **PDF** and a **text file**, and ask one question
   about each.
2. Edit your message and change it: two versions must appear ("‹ 1 / 2 ›"), and the attachments must survive the
   edit. Switch versions.
3. Regenerate an answer; check the previous one is still reachable as a version.
4. Start typing in a second conversation and switch away without sending. Quit and reopen: the draft is still
   there, with its attachments.
5. Force a failed send: turn Wi-Fi off for a few seconds, send, then turn it back on and use **Retry** once. No
   duplicate user message and no lost draft.
6. Check the cost footer for the conversation, and export it (Markdown, HTML or JSONL) and open the file.

**Pass:** attachments survive edit, versions switch without losing anything, drafts survive a restart, a failed
send recovers with exactly one retry, export opens.
**Not a failure:** images need a vision model; web search goes through OpenRouter.
**Evidence:** the error card, the draft after restart, the cost footer.

## 3 · A New project folder (30 min)

1. **New project** (⇧⌘N): a name and one instruction ("answer in Spanish", or a code style rule). Confirm the
   folder in `~/Piopio` has `AGENTS.md` and `NOTES.md`.
2. Conversation A in the project: state a fact it should keep ("the kitchen is 3.4 m wide; note it"), and check
   `NOTES.md` on disk afterwards.
3. Conversation B in the same project: ask about the fact without repeating it. It must know it (NOTES.md is read
   every turn), and the instruction from step 1 must hold.
4. Conversation C: ask it to `read` `NOTES.md` and to list what the project's rules are.
5. Take a loose conversation and **Continue in** → the project. Check the sidebar grouping and that the next
   answer follows the project's `AGENTS.md`.

**Pass:** three conversations share notes and rules; what's in the app matches the files on disk.
**Evidence:** the three transcripts (short), `NOTES.md`, the sidebar.

## 4 · Agents (a day, mostly passive)

**Setup:** the Release build, so the engine can be a launchd agent. Settings › **This Mac & cloud** ›
**Keep running when Piopio quits**.

1. Create an agent with a schedule ~5 minutes out. **Run it now** once and read its run: what fired, what it did,
   what it cost.
2. Leave it due while the window is closed but the app running. Then quit the app with background mode **on** and
   wait for the run. Then do the same with background mode **off**: the run must not happen, and the app must say
   the agent can't run when it's not open.
3. Sleep the Mac across a due time. On wake, check whether the run happened then or was missed, and whether the app
   says which.
4. Check the **Inbox**: what needs you, and the toolbar/Dock badges.

**Pass:** runs happen as described in each of the four cases, with cost recorded per run, and nothing is silently
lost across sleep or quit.
**Not a failure:** agents can't run while the Mac is asleep or off; Mac-app tools need the native app and the OS
permission.
**Evidence:** the runs list with times and costs, the Inbox, the engine log around each wake.

## 5 · Approvals (15 min)

1. A Build session in **Ask**. Ask for a command and wait for the card.
2. With background mode **on** (the engine outlives the app): quit Piopio, reopen it, open the same session. The
   same pending request must be there, not a second one.
3. Deny it with a note. The tool must read denied, and the command must not have run (check the file or
   `git status`).
4. Do it once more with **Allow once** and verify the executed action matches exactly what the card said.
5. Repeat step 1 and quit with background mode **off**: the request is cancelled, the tool shows stopped, and the
   quit warning said so.

**Pass:** the decision shown after a restart is the decision that executes; nothing executes twice or unasked.
**Evidence:** the card before and after the restart, the tool card, `git status`.

## 6 · Costs (20 min, plus waiting for the dashboard)

1. Note the OpenRouter usage total for your key, run one short controlled session on a known model (three or four
   turns), note the thread's cost footer.
2. Compare: the same model and the same minutes, within ~2%. Note anything the footer adds (web search, background
   work) and whether Settings › **Backup & costs** explains the scope.
3. Use a model whose price the provider doesn't report, if you have one: its cost must show as unavailable, not $0.
4. Turn web search on for one turn and check the search is counted where the app says it is.

**Pass:** the controlled session matches the provider within ~2%, unknown prices are excluded rather than free, and
the scope of every number is stated.
**Not a failure:** OpenRouter totals cover the key (other apps included) and exclude other providers.
**Evidence:** the dashboard numbers, the footer, the settings screen.

## 7 · Backup (30 min)

1. Settings › **Backup & costs** › **Create backup…** into a private folder outside the data folder. Wait for
   "Backup verified and saved."
2. Add something identifiable (a chat, an agent fact, a Build session), then **Restore backup…** from that folder.
3. After the restart: the identifiable thing from step 2 is gone (as expected), chats, agent memory/definitions and
   Build history are back, and CLI sessions are not duplicated.
4. **Show in Finder** on `Piopio-before-restore-<id>`: the previous folder is there, complete.

**Pass:** backup and restore both verify, nothing is lost or duplicated, the previous folder is retained.
**Note:** `scripts/recovery-smoke.sh` already covers the mechanical half offline with scratch data; this scenario is
about your own data and the same-shaped folder on disk.
**Evidence:** the two folder listings, the chats and agent memory after restore.

## 8 · Accessibility (30 min)

1. **Keyboard only:** ⌘K palette, ⇧⌘F search, Tab/⇧Tab through the composer, search and an approval card, Esc to
   stop, ⌘↩ to allow. Nothing must need the mouse.
2. **VoiceOver:** read a whole conversation, a tool card, an approval card and the composer. Every control must be
   announced with a name, and the transcript must be navigable.
3. **Layouts:** narrow the window to ~700 px, then turn on Increase Contrast and Reduce Motion in System Settings ›
   Accessibility. Nothing clips, overlaps or animates against the setting.

**Pass:** every flow is reachable and announced; no clipping at narrow widths; the two system settings are honored.
**Evidence:** screenshots of the narrow layout and the VoiceOver cursor on an approval card.

---

## Suggested week

| Day | Scenarios |
|---|---|
| 1 | 1 · Build and 5 · Approvals (they share a session) |
| 2 | 2 · Chat |
| 3 | 3 · A New project folder |
| 4 | 4 · Agents (start it the day before, it needs a sleep/wake) |
| 5 | 6 · Costs and 7 · Backup |
| 6 | 8 · Accessibility |
| 7+ | Use it normally; only write down what annoys you |

## Results

| # | Item | Date | Model | Verdict | Evidence / notes |
|---|---|---|---|---|---|
| 1 | Build | | | | |
| 2 | Chat | | | | |
| 3 | New project folder | | | | |
| 4 | Agents | | | | |
| 5 | Approvals | | | | |
| 6 | Costs | | | | |
| 7 | Backup | | | | |
| 8 | Accessibility | | | | |

## Issues

One line each: date, scenario, what happened, what you expected, severity (blocks the pass / annoying / cosmetic),
and the commit that fixes it. Move it to [status.md](status.md) or the roadmap backlog once it's fixed or scheduled.

| Date | Scenario | What happened | Expected | Severity | Fixed in |
|---|---|---|---|---|---|
| | | | | | |
