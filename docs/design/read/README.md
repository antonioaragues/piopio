# Read: what the answer is based on

Decided 2026-11-25 from `read.html`: **option A, one list.** Built the same day in `ReadBlock.swift`, the one Read
block in a chat's Summary column and a project's.

**The model.** Read lists what the agent took in from outside the conversation, so you can open it and check. Chats
and projects use the same definition; a project just has more sources.

- **You gave**: files attached to a message, then the paths you @mentioned that exist. A file opens in the preview
  (an attachment in its viewer), a folder in Finder.
- **Files** (projects only): what it opened with its read tool, first read first. Opens in the preview beside the
  conversation; a path outside the project shows in Finder.
- **Pages**: pages it fetched (a fetch that failed doesn't count), and the sources its web searches returned, at most
  30. Opens in the browser.

**The block.** Folded: "2 you gave · 9 files · 4 pages". Open (remembered for every conversation, `readOpen`): a
subheading per group, six rows each. Files stop at six: the rest are behind "Show in Files ›" at the end, which opens
Files on Touched (2026-11-25: "and N more" there was a second way to the same list). Pages, which have no panel,
show six then "and N more".
A row click never goes to another panel; only that link does.

**Not in Read.** Commands are actions, not sources: the timeline, and Background while they run. What it changed is
Changes. AGENTS.md belongs to Setup; skills have their own block.

**One limit.** A file read through a command (`cat`, `grep`) doesn't show: a command doesn't say reliably what it read.

**Changed from before.** A project's Read was a count ("2 files · 144 commands ›") that jumped to Files; a chat's
listed attachments and pages with "4 pages · 1 file". The data now comes from one place, `SessionDigest.inputs`
(pages joined it, the commands count left it); `ChatResults` and `ChatReadBlock` are gone.

Captures (2026-11-25, faux model): `app/project.png` (two mentions, ten files read, Show in Files; taken before "and 4 more" left Files) and
`app/chat.png` (an attachment and the one page of three that loaded).
