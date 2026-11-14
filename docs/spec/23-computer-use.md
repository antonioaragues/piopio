# 23 — Computer use

Status: draft, 2026-11-12; nothing here is built. It turns the spike in [11-computer-use.md](11-computer-use.md)
(models, open-source projects, the accessibility-first recommendation) into a design. Companion to
[22-browser.md](22-browser.md): websites go through the built-in browser, Mac apps through this. The shared plumbing
(`app.tool`, images in tool results, the timeline, Stop) is in 22 §8 and isn't repeated here.

## 1. The experience

Piopio can see an app on your Mac and use it for you, one app at a time, with your say.

1. **Ask it to look.** "What's wrong with this export dialog in Numbers?" A card asks **Let Piopio see Numbers?**
   You allow it; it reads the window and answers. It saw Numbers and nothing else.
2. **Ask it to do.** "Rename these 40 layers in Sketch to match the spec." It asks **Let Piopio use Sketch?** — This
   time · In this conversation · Always · No. Then it works **beside you**: your pointer doesn't move, Sketch doesn't
   have to be in front, and you keep typing in another window. A small pill at the top of the screen says **Piopio is
   using Sketch · Stop**.
3. **Some things need the pointer.** Dragging on a canvas has no button to press. Piopio says so and asks for **full
   control**: for that stretch it brings the app forward and moves the real pointer. The pill turns into a border
   around the screen, and touching the mouse or pressing Esc stops it at once.
4. **It stops where you'd want it to.** A password field, a system prompt, a "Delete 212 items?" sheet: it pauses and
   shows you the screen with what it was about to do.
5. **Agents can, while you're there.** A "Monthly invoices" agent exports a report from an app with no API. If the
   Mac is locked or you're away, the run waits in Needs you instead of working on a desktop nobody is watching.

The whole model: **one app at a time, with a grant; beside you when it can, the pointer only when you say; it never
touches secrets, system prompts or Piopio itself.**

## 2. Decisions this takes (to confirm)

| # | Decision | Alternative considered |
|---|---|---|
| CU1 | **Attended only on your real desktop.** Conversations always qualify; an agent's run uses the computer only while the Mac is unlocked and Piopio is open, and waits otherwise. (Answers spike question 1.) | Unattended on the real desktop: nobody sees the pill. Unattended belongs in a virtual Mac (§9). |
| CU2 | **Conversations first, then agents.** (Answers spike question 2.) | Agents first: they're where an app without an API hurts most, but they're harder to supervise. |
| CU3 | **Accessibility first** (from the spike): the model reads a map of the window's controls and acts on them by ref; a screenshot comes along when it helps; pixel coordinates are the fallback. | Screenshots and coordinates only. |
| CU4 | **Every call names one app, and a grant is per app.** The model sees only that app's windows, never the whole screen. | Whole-screen control, as provider reference implementations do: simpler, and shows the model everything on your screen. |
| CU5 | **Two ways of acting:** *beside you* (accessibility actions and events sent to the app; no focus, no pointer) by default, and *full control* (the real pointer and keyboard) on request, per stretch of work. | Full control always. |
| CU6 | **Websites go to the built-in browser.** In Safari, Chrome and other browsers the model can look but not act, unless you allow acting for that browser in Settings with a warning. | Acting in your real browser by default: it holds every sign-in you have. |
| CU7 | **Ordinary function tools through pi,** for every provider (from the spike). Providers' native computer-use tool types wait until pi supports them. | Calling Anthropic's or OpenAI's computer tools directly, outside pi. |
| CU8 | **Off until you turn it on,** with a first-run sheet that says what it sees, where the images go (the model provider this conversation already uses) and what it won't do. | On by default. |

## 3. What the model gets

One tool group, `computer`. (`mac_*` stays reserved for the Mac Bridge, 06-agents §10.)

| Tool | Does | Kind |
|---|---|---|
| `computer_apps()` | Running apps and their windows (names and titles only), and which ones you've granted. | reads |
| `computer_see({app, window?, image?})` | A map of the window: `[b4] button "Export…"`, `[t7] text field "Name" value="Q3"`, `[m2] menu "File"`, with roles, labels, values, enabled/focused. `image: true` adds a picture of that window with the refs' frames known. | reads |
| `computer_find({app, text})` | Refs matching a label or value, across the app's windows and menus. | reads |
| `computer_press({app, ref})` | Presses a control (the accessibility action). | acts |
| `computer_set({app, ref, value})` | Sets a field's text, a checkbox, a slider, a pop-up's choice. | acts |
| `computer_menu({app, path})` | Chooses a menu item by path: `["File", "Export To", "PDF…"]`. | acts |
| `computer_type({app, text})` / `computer_key({app, keys})` | Types into the focused field; sends a shortcut. | acts |
| `computer_scroll({app, ref?, by})` | Scrolls a view. | reads |
| `computer_click({app, x, y, button?, count?})` / `computer_drag({app, from, to})` | Pointer actions at a point in the window's image. **Full control** when the app can't take them in the background. | acts |
| `computer_open({app})` | Launches or reveals a granted app. | acts |
| `computer_wait({app, for, timeout?})` | Waits for a window, a control or some text to appear. | reads |

- Acting tools return the part of the map that changed, so one call usually shows its own result.
- Refs last while the window's structure does; a stale ref answers "that control is gone; look again".
- Without a vision model, `image` isn't offered and the accessibility tools still work. Apps that expose almost
  nothing to accessibility (some games, some cross-platform toolkits, canvases) need a vision model and coordinates.
- Images are the window only, scaled to at most 1280 px wide; the app maps the model's coordinates back to screen
  points (Retina and several displays included).
- A step budget per turn (default 50 actions, a setting), as in the browser.

## 4. Permissions and safety

### 4.1 Two macOS permissions, asked once
Piopio.app needs **Accessibility** (to read and press controls) and **Screen Recording** (to take a window's
picture). The first-run sheet (CU8) explains each and opens the right pane of System Settings; you grant them there.
Seeing works with Accessibility alone, without pictures, if you'd rather not grant Screen Recording. macOS may ask
again from time to time; Piopio says so plainly when a grant has lapsed.

### 4.2 What's enforced by Piopio (not left to the model)
- **No grant, no access.** An app the model hasn't been granted isn't in a map, isn't in a picture and can't be
  acted on. Grants are **See** or **Use**, and This time · In this conversation · Always; Settings › Computer use
  lists them.
- **Only the granted app is captured.** A picture is of that app's windows, composed without anything in front of
  them. A notification banner or another app overlapping it isn't in the image.
- **Never, with no setting to change it:**
  - **Piopio itself.** Its windows are left out of every map and picture and refuse every action, so the model can't
    press its own Allow button or change its own permissions.
  - **System security UI:** password and Touch ID prompts, permission dialogs, the login window, the lock screen.
  - **Keychain Access, Passwords and other password managers** (a built-in list by bundle id).
  - **System Settings › Privacy & Security** and Users & Groups.
- **Asks every time, whatever the grant:** terminals and code editors' terminals (a shell is `bash` with extra steps,
  and Build's own command approvals and sandbox would be bypassed). The model is pointed to its `bash` tool instead.
- **Secure fields are closed:** `AXSecureTextField` values aren't read, their area is blurred in pictures, and
  typing while one has focus is refused and becomes a hand-off.
- **Browsers are see-only** (CU6).
- **Locked or asleep means stop.** If the screen locks, the display sleeps or the user switches away (fast user
  switching), tools answer "the Mac is locked" and the run pauses. Piopio never unlocks the Mac and never keeps it
  awake to work.
- **Full control ends on your input.** Any real mouse movement or key press from you stops the action in flight and
  pauses the run ("You took over"). Esc and a global shortcut stop it too.
- **The clipboard is yours.** The model can't read it. Pasting what it wrote goes through `computer_type`, which
  doesn't touch your clipboard.

### 4.3 What the model is told to do (and may get wrong)
As in the browser (22 §4.2), the prompt asks it to stop before anything that sends, buys, deletes, overwrites,
publishes or accepts terms, and Piopio can't tell every such button apart. What Piopio adds:
- **Destructive-looking controls ask.** A press on a control whose label matches a short list (Delete, Erase, Send,
  Pay, Buy, Empty, Format, Reset, Sign Out, and their equivalents in the system languages), or on the default button
  of a sheet that appeared after the model's own action, shows you the window with the control outlined and waits.
  It's a net with holes (icons without labels, custom controls), not a guarantee.
- **An "Ask before each action" level per app** for apps where any mistake is expensive.
- **Undo, when the app has it:** the result card for a stretch of work offers **Undo in Sketch** (Edit › Undo, as
  many times as the model acted) while the app's undo stack still starts with those actions. Many changes can't be
  undone this way, and the card says so instead of offering it.

### 4.4 Levels, per app
| Level | Seeing | Acting |
|---|---|---|
| Not allowed (default) | asks | asks |
| See | runs | asks |
| Ask before each action | runs | asks every time |
| Use | runs | runs (the §4.3 net still asks) |
| Full control allowed | runs | runs, and may take the pointer without asking again |
| Blocked | refused | refused |

For agents, computer use is one row in Setup › What it can use (Off · Asks · Allowed, AD6) plus its list of apps.
Asks means the grants above, raised in the agent's chat and Needs you. Allowed covers its listed apps only. An
agent's full control always asks, since it takes your Mac from you at a time it chose.

### 4.5 What the screen says is not what you say
Everything read from an app (labels, document text, an email on screen, a file name) reaches the model marked as
untrusted content. It never counts as an instruction from you and can't grant a permission.

## 5. What you see

- **The pill** (beside you): at the top centre of the screen, in every Space: the app's icon, "Piopio is using
  Sketch", the step count, **Stop**. Clicking it opens the conversation.
- **The border** (full control): the whole screen gets a thin border and the pill adds "has the pointer — move the
  mouse to stop". Before each pointer action the target is ringed for a moment.
- **In the conversation:** one folded line per stretch, "Used Sketch · 42 steps · 1m 10s". Opened, each step is a
  sentence ("Set Name to 'Header / Dark'") with the window's picture when one was taken. Agents' chats show the same.
- **Hand-offs** as in the browser: a card with the window's picture and what it needs ("Type your password in the
  dialog, then Hand back"), also in Needs you for agents.
- **Settings › Computer use:** the on/off switch with the first-run explanation, macOS permission status, the apps
  and their levels, the never list (read-only), the step budget, and whether pictures are kept.

## 6. What's kept, what's sent

- **Sent:** the window maps and pictures go to the model provider the conversation already uses, like any attachment.
  No other service is involved (the local-by-default rule: no new destination). With a local model, nothing leaves
  the Mac.
- **Kept:** pictures are files with the conversation (22 §8), deleted with it. Settings offers **Keep pictures:
  with the conversation · for 7 days · don't keep** (the default is with the conversation; "don't keep" leaves the
  sentences without thumbnails).
- Memory never learns from screen content on its own; learned facts come only from what you and the model say.

## 7. Under the hood

- **Built into the app**, reached through `app.tool` with the `computer` group (22 §8).
- **The map** comes from the accessibility tree (`AXUIElement`): roles, titles, values, frames, actions, pruned to
  what's visible and useful, with a ref per element. **Pictures** come from ScreenCaptureKit with a filter for one
  app's windows.
- **Acting beside you:** accessibility actions (`AXPress`, setting `AXValue`, `AXShowMenu`, menu items by path) need
  neither focus nor pointer. Keys and clicks an app won't take that way are posted to that app's process.
  **Full control:** events posted at the system level, with the app brought to the front first.
- **Library:** the spike's pick, Peekaboo's `PeekabooAutomationKit` (MIT, Swift), embedded, against a thin layer of
  our own over the same Apple APIs. U0 decides: the kit if it gives us per-app capture, background actions and the
  secure-field checks without pulling its agent and CLI along; otherwise our own layer, borrowing its approach.
- **The engine decides, the app executes** (22 §8): grants, levels and the never list live in the engine and travel
  with each call; the app enforces what only it can see (the frontmost app, secure fields, a system dialog
  appearing, your input) and can refuse.
- **One user of the computer at a time.** Calls from different conversations queue per app; full control is exclusive
  across the Mac.
- **Cloud agents** don't get these tools. Reaching a Mac from the cloud is the Mac Bridge's job (06-agents §10),
  later, and still attended.
- **Tests:** a small fixture app with known controls (a secure field, a destructive sheet, a canvas) driven in CI on
  the self-hosted Mac; the engine's grant logic with a fake app service.

## 8. Milestones

| | Scope | You can | Size |
|---|---|---|---|
| **U0 · Try it** | The spike's step 1, still not done: Peekaboo as an MCP server in a Build session on 10 real tasks. Then a harness for our own questions: per-app capture, background presses and keys in 10 apps, secure fields, stopping on user input. | Read which tasks worked beside you, which needed the pointer, which failed; and the kit-or-own-layer answer. | S |
| **U1 · See** | Settings › Computer use and the first-run sheet; macOS permissions; `computer_apps`, `_see`, `_find`, `_wait`; See grants; the never list; folded steps with pictures. Conversations only. Uses 22's protocol changes. | Ask about what's on screen in an app you allowed, and check it saw nothing else. | M |
| **U2 · Use, beside you** | `_press`, `_set`, `_menu`, `_type`, `_key`, `_scroll`, `_open`; Use grants and levels; the pill and Stop; secure fields and hand-offs; the destructive net; pause when locked. | Have it do a repetitive job in one app while you work in another, and stop it mid-way. | L |
| **U3 · Full control** | `_click`, `_drag`; the border; stop on your input; exclusivity. | Have it do something that needs dragging, and take the Mac back by moving the mouse. | M |
| **U4 · Agents** | The `computer` row in agent setup with its apps; attended-only runs that wait in Needs you; grants raised from a routine. | Give an agent a monthly export from an app without an API. | M |

If 22 hasn't shipped its W1 by then, U1 carries the shared protocol work.

## 9. Later
- **A second desktop for unattended work:** a macOS virtual machine on Apple silicon (Lume from the spike, or
  Apple's Virtualization framework directly) that an agent owns, with the same tools pointed at the guest. It lifts
  CU1 without anyone's real desktop being driven unseen. Costs: tens of GB of disk, a macOS install, and apps and
  sign-ins set up again inside it.
- **Native provider tool types** (Anthropic's computer toolset, OpenAI's `computer`) when pi supports them, kept
  behind the same grants. To re-check against the providers' docs then; the spike's notes are from 2026-10-22.
- **Teach by showing:** you do a task once while Piopio watches one app, and it becomes a routine's instructions.
- Cross-app drags; several displays in full control; acting in your browsers through an extension instead of pixels.

## 10. Questions for you
1. **CU1:** attended only (proposed), or may an agent you trust use the real desktop while you're away?
2. **CU6:** browsers see-only by default (proposed), or treated like any other app?
3. **Full control:** keep it as a separate, later milestone (proposed), or is beside-you alone not worth shipping?
4. **Pictures:** kept with the conversation by default (proposed), or not kept?

## 11. Not verified
- Nothing was installed or run, as in the spike. In particular: how many everyday apps can be driven beside you
  (background accessibility actions and per-process events) and how many need the pointer; U0 measures it.
- That ScreenCaptureKit returns a clean picture of one app's windows when they're covered, minimised or on another
  Space.
- How often macOS 27 re-asks for Screen Recording, and whether an update of the app (Sparkle) resets either grant.
- `PeekabooAutomationKit`'s current API and whether it can be embedded without its agent (spike §6).
- That pi passes images in tool results to every provider (also open in 22 §12).
- The model and API facts in spike §1 were not re-checked for this draft.
