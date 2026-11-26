# 39 · A filtered network for projects you haven't trusted

Status: built 2026-11-23, from the security audit (its "step 2", after the sandbox hid credentials and the Keychain tool in 8137fa8).
Decided: NF1 (who's filtered), NF2 (a new site asks in the tray), NF3 (no Full auto while filtered).
**2026-11-26:** a third choice, the network **off** (§8, roadmap PAR12).

## 1. Why

Build's commands run in macOS's sandbox (docs/research/deepseek-harness.md §1.1), which keeps their writes in the
project and hides Piopio's data, sign-ins, credential files, SSH private keys and the Keychain tool. The network stays
open, so a repository you just cloned can send anything it *can* read (its own `.env`, files outside the hidden list)
anywhere, from a `postinstall` script or a test, without asking. For your own projects that's fine; for one you got
from someone else it's the most likely way to lose a secret.

Seatbelt can allow or deny the network only by address (`localhost` or `*`), not by name, so a filter by site needs a
proxy.

## 2. Who's filtered (NF1)

- **A project you add or clone from now on**, until you trust it: Open folder, Add project and GitHub's clone start
  it filtered, unless the folder (or one above it) is trusted already, in pi (`~/.pi/agent/trust.json`) or in Claude
  Code (`~/.claude.json`).
- **Not filtered:** projects from before this (no field: open), New project (you made it), chats (their folder isn't
  a project), and the sandbox switched off (no sandbox at all).
- **No Full auto while filtered** (NF3, 2026-11-23): Full auto has no sandbox and asks only for the deny-list (05 AP3),
  so it would go around the filter. In a filtered project it's Auto-edit: setting it is refused with the reason, every
  mode picker shows it unavailable ("Needs a trusted project"), a project's default, sessions, subagents, Board helpers
  and coding agents read it as Auto-edit, and filtering a project that started in Full auto moves it to Auto-edit.
- **Trusting the project opens it** (the trust banner's Trust Project, or Settings › Approvals › the project). The
  banner shows for a filtered project as it does for one with its own setup. Settings › Approvals › the project has
  a picker, "Commands' network": Open, Filtered or Off (§8), to set it by hand.

Stored as `network: "filtered"` (or `"off"`) on the project (`projects.json`); `ProjectInfo.network` tells the app.

## 3. What a filtered command can reach

- **This Mac** (`localhost`, any port): dev servers, tests that start one, the proxy itself.
- **The built-in sites**, without asking (`BUILT_IN_HOSTS`, engine/network-filter.ts): npm's registry (npm, Yarn,
  pnpm, Bun), JSR and deno.land, nodejs.org (native modules' headers), PyPI and its files, crates.io, the Go module
  proxy and checksum DB, RubyGems, Maven Central and Gradle, and GitHub (github.com, api.github.com, codeload,
  `*.githubusercontent.com`). Commands are signed out of GitHub in the sandbox, so GitHub gives reads, not pushes.
- **The project's sites**: its "host" rules (`example.com`, `*.example.com`), listed in Settings › Approvals with its
  other rules.
- **Ports 80 and 443 only.**

## 4. A new site (NF2)

The connection waits while the tray asks: "Let this project's commands reach example.com", with **Allow** (this
session), **Always allow example.com** (a rule of the project) and **Deny** (refused for the session). Several
connections to the same site wait on one question. Stopping the run refuses what was waiting without deciding: the next
command that wants the site asks again.

When the filter refused something during a command, the agent's result ends with a note naming the sites, saying the
user said no (or the run stopped), not to look for another way, and to tell the user if the work needs them.

## 5. How

- **Proxy** (engine/network-filter.ts): one per Build session that needs it, on `127.0.0.1:<random>`, started when the
  session opens filtered (or on the first command), closed with the session. HTTPS is a `CONNECT` tunnel: nothing is
  decrypted, the site's name is all it sees. Plain HTTP is forwarded.
- **Sandbox** (extensions/sandbox.ts): `seatbeltProfile(…, filtered)` adds `(deny network-outbound (remote ip "*:*"))`
  and `(allow network-outbound (remote ip "localhost:*"))`. Unix sockets (DNS, ssh-agent) aren't addresses and stay
  allowed, the hidden ones refused. `confine(…, env)` sets `HTTP(S)_PROXY`, `ALL_PROXY` (and lower case), `NO_PROXY`
  for this Mac, and `NODE_USE_ENV_PROXY=1` (Node's `fetch` reads the proxy only with it). Background commands and the
  check after edits get the same; a proxy that can't start leaves nothing outside this Mac reachable, rather than
  everything.
- **Protocol:** `ApprovalRule.kind` and the prompt's `rule.kind` gain `"host"`; `ProjectInfo.network`;
  `projects.configure` `network`. Host rules aren't pi's approval rules (they're left out of what the approvals
  extension sees).

## 6. Limits

- **DNS lookups still go out** (through the system's resolver), a slow channel for a little data.
- **Tools that ignore proxy variables fail closed**: Swift Package Manager and `xcodebuild` resolving packages, some
  native binaries. They fail to connect; rerun outside the sandbox (which asks), or trust the project.
- **Git over SSH fails** in a filtered project (port 22, and no proxy for it): use HTTPS, or rerun outside.
- **Coding agents** (Claude Code, Codex, Antigravity) don't run their commands in Piopio's sandbox, so they aren't
  filtered (docs/spec/31).
- **An allowed site can still receive data** (an upload to an allowed host). The list is for getting packages, not a
  promise about where data can't go.
- Any process of yours can use a session's proxy while it runs; it only reaches what that session may.

## 7. Verified

- engine `network-filter.test.ts`, `project-network.test.ts`, `network-build.test.ts` (a Build session in a project
  just added: the tray asks, Deny reaches the agent as a note, trusting opens it); extensions sandbox tests; Swift
  `ProtocolTests` (a filtered project and a host rule decode).
- Real tools in a filtered profile through the proxy: `npm view left-pad version`, `git ls-remote` on GitHub over HTTPS
  and Node's `fetch` to the npm registry work without asking; `curl https://example.com` asks once and is refused on
  Deny; `curl` around the proxy and to a bare IP can't connect.

## 8. The network off (2026-11-26, roadmap PAR12)

For work that shouldn't touch the internet at all: a project with secrets in it, a repository you only want to read
and build, or a check that the build works offline.

- **Where:** Settings › Approvals › the project › **Commands' network**: Open, Filtered or **Off**. Per project, like
  Filtered, and read on every command, so it applies to running sessions at once. Off is chosen by hand only: no project
  starts off.
- **What a command reaches:** this Mac only (`localhost`, any port: dev servers, tests that start one). Not the
  built-in sites, not the project's host rules, and nobody is asked.
- **How:** the same sandbox profile as Filtered (no address but this Mac's) and the same proxy, which refuses every
  site without asking (`NetworkFilter`'s `off`). The proxy is kept so the agent hears what happened: a command that
  tried a site ends with a note that the user turned the project's network off, to work offline, and not to look for
  another way. Background commands and the check after edits get the same.
- **Trust doesn't turn it on.** Trusting a filtered project opens it; a project that's off stays off until you choose
  Open or Filtered.
- **No Full auto while off,** as while filtered (NF3): Full auto has no sandbox. Setting it is refused ("Full access
  has no sandbox, so it can't keep the network off"), mode pickers show it unavailable ("Needs the project's network
  on"), and turning the network off moves a project in Full auto to Auto-edit.
- **Limits:** the same as §6. DNS lookups still go out. Running a command again outside the sandbox
  (`outside_project`) asks, as it does for any write outside, and runs with the network open. Coding agents (Claude
  Code, Codex, Antigravity) and the terminal tab aren't covered. With the sandbox switched off in Settings there's
  nothing to turn off.
- **Not done:** `edit`/`write` under the sandbox's confinement (PAR12's other half). They only check paths.
- **Verified:** `network-filter.test.ts` (off refuses built-in, rule and other sites without asking, and is read per
  connection), `project-network.test.ts` (off survives trust and a restart, keeps Full auto away),
  `network-build.test.ts` (in a Build session `curl https://registry.npmjs.org/` is refused without a question and the
  agent gets the note), extensions `sandbox.test.ts` (the note), and the Swift contract test decoding `"off"`.
