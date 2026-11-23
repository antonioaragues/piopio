# 42 · Voice: talk to Piopio

Status: draft 2026-11-23 from a request by the user; decisions in §9 are proposals to confirm; nothing here is built.
It develops backlog D5 ("voice input in the composers, dictation, push to talk") and AQ10's "voice", both parked until
now (09 § Parked), and shares its transcription with 40's narrated demonstrations.

**The request (the user, 2026-11-23):** "The ability to talk or dictate to Piopio. Working with voice. Write the spec."

**The idea in one line:** you can say anything you would type, in any composer, and it lands as text you can check
before it goes; when your hands are busy, a talk mode lets you hold a whole conversation out loud, with Piopio
answering aloud. Both run on the Mac by default, both are ordinary turns underneath, and voice never approves anything.

## 1. Why

- **Speaking is faster than typing for the long part of a prompt.** Context, the why, what you tried, what you don't
  want: the part people skip when they type is the part a model needs most. Speech is about three times faster.
- **Away from the keyboard.** Walking, cooking, looking at a second screen, holding a device you are testing.
- **The user writes in Spanish and works in English terms.** "Arregla el bug del OAuth en `sessions.ts`": dictation has
  to keep both languages and know the project's words.
- **Agents already get voice notes.** A Telegram voice note to an agent is dropped today (13's milestones list it as "later").

## 2. What exists

| Where | What it does | What it lacks |
|---|---|---|
| **macOS Dictation in Piopio today** | The composer is a `TextEditor` (an `NSTextView`), so pressing the dictation key (🎤 or Fn twice) already works, on device | No button in the composer, no push to talk that sends, no project vocabulary, no cleanup, nothing for agents, talk mode or files |
| **Claude Code `/voice`** (March 2026) | Push to talk in the terminal and VS Code: hold a key (space by default) while you speak, or tap to start and tap again to send; uses the response language setting | Needs a Claude.ai sign-in; text in only, it doesn't talk back |
| **Wispr Flow, Superwhisper** | System-wide dictation with cleanup: filler words removed, formatting per app, a personal dictionary. Flow runs in the cloud; Superwhisper runs on the Mac and cleans up through configured modes | Not aware of Piopio's projects, files or agents |
| **ChatGPT and Claude voice modes** | A spoken conversation: you talk, it answers aloud, you can interrupt | Separate from where the work is; tools and approvals don't fit a voice-only surface |
| **Apple's Speech framework** (macOS 26+) | `SpeechAnalyzer` with `SpeechTranscriber` (a newer on-device model, fast, good with long and distant audio) and `DictationTranscriber` (the same models as system dictation); live partial results; models installed per language through `AssetInventory` | Language coverage per Mac isn't published (read `supportedLocales`); quality in mixed Spanish and English is unknown (§13) |
| **`AVSpeechSynthesizer`** | On-device voices, including the Premium ones and Personal Voice, streaming per utterance | Quality below the best cloud voices |

What Piopio adds: dictation that knows the project (file names, agents, people), lands in the composer as editable
text, and becomes an ordinary turn; talk mode as a layer over pi's own loop rather than a separate voice model; voice
notes and recordings as text for agents; all of it on the Mac unless you add a cloud voice.

## 3. Dictation: the experience

1. **Start.** A microphone button at the right of every composer (conversation, Build session, agent chat, Quick Chat,
   side panels), left of Send. **Click** to start and click again to stop, or **hold** it to talk while held. The
   keyboard: **⌥⌘D** toggles; holding **Fn** stays the system's.
2. **Speak.** The button becomes a small level meter and a timer. Words appear in the composer as you speak, in grey
   while they may still change, in the normal colour once final. You can type at the same time; dictated text goes
   where the cursor is.
3. **Stop.** Stopping (click, release, ⌥⌘D, or Esc) finalizes the text and, if Tidy is on, replaces it with the tidied
   version in one step (§5). **⌘Z** returns the words exactly as heard. Nothing is sent: you read it and press Enter.
4. **Send when I let go** (Settings › Voice, off by default): releasing a hold sends at once, as Claude Code's tap mode
   does. With an agent running, a dictated message follows the composer's rules (Enter queues, ⌥Enter steers).
5. **From anywhere.** Holding the Quick Chat hotkey (⌥Space) opens Quick Chat already listening; releasing it stops.
   Tapping it opens Quick Chat as today.

The transcript marks a dictated message with a small microphone glyph after the time; nothing else changes.

## 4. Talk mode: the experience

For a conversation out loud, with the window behind other work or the Mac across the room.

1. **Start.** The waveform button beside the microphone (or `/talk`, or ⌥⌘T). A pill at the top of the screen:
   the conversation's name, the state (**Listening**, **Thinking**, **Speaking**), a level meter, **Mute**, **End**.
2. **You talk; it answers.** When you pause (about a second of silence, tunable), what you said is sent as a message.
   The answer is read aloud as it streams, sentence by sentence, so the first words come before the turn ends.
3. **Interrupt.** Speaking while Piopio speaks stops the voice at once. If the turn is still running, what you say
   steers it (as ⌥Enter); if it ended, it's the next message. "Stop" alone stops without a new message.
4. **What's read and what's shown.** Prose is read. Code blocks, tables, diffs, visuals and long lists are not; the
   voice says what's on screen instead ("I've put the diff in the Changes tab"). Tool work is summarized by the
   processing line it already has ("Ran the tests, 2 failed"), not read call by call.
5. **Questions.** When the model asks with options (the Questions card), it reads them and you can answer by voice
   ("the second one", or the option's words). An answer that doesn't clearly match one option is sent as your own
   words, as typing it would be.
6. **Approvals never by voice.** An approval is read aloud ("Piopio wants to run `npm install`; it's waiting for you")
   and the pill shows **Allow** and **Deny** buttons and the keys (⌘Enter, Esc). Saying "yes" does nothing (§8).
7. **End.** **End**, Esc while the pill is focused, or "that's all" ends talk mode; the conversation stays as a normal
   transcript you can read.

Talk mode is one conversation at a time. Starting it in another conversation ends the first.

## 5. Making speech into good text

- **Project vocabulary.** Before each dictation the app hands the transcriber the words this composer is likely to
  hear: the project's name and its top-level file and folder names, files mentioned in the conversation, your agents'
  names, people and places from About me and memory, the current model names. Apple's analyzer takes contextual
  strings for this (to confirm in VC0). You can add words in Settings › Voice › Words ("pi-durable", "Piopio").
- **Tidy** (on by default): after you stop, the on-device utility model (AQ7, `piopio-fm`) removes filler words and
  false starts, fixes punctuation and capitals, writes spoken file names and symbols as code (`sessions.ts`,
  `@Contable`), and turns a spoken list into a list. It never translates, never summarizes and never adds words; if
  the result differs by more than a set share of words, the raw text is kept. Without Apple Intelligence, Tidy is
  skipped and the transcriber's punctuation stands. A cloud model is never used for Tidy unless you choose one.
- **Spoken mentions.** "At Contable" or "arroba Contable" becomes the `@Contable` chip when it names an agent you have;
  "the file sessions dot ts" becomes `sessions.ts` when such a file exists in the project. Otherwise the words stay.
- **Language.** The transcriber runs in one language per dictation: your language in Settings › Voice (by default the
  system's), switchable from the pill or the meter's menu, remembered per conversation. Mixed speech (Spanish with
  English terms) relies on the vocabulary list; if VC0 shows that isn't enough, the fix is a transcriber that handles
  both (§7, a local Whisper-class model or a cloud one).

## 6. Voice beyond the composer

- **Voice notes to agents.** A Telegram voice note (and WhatsApp, when it exists) is transcribed on the Mac and given
  to the agent as your message, with the glyph; the agent's reply is text, as now. A cloud agent with the Mac off waits
  for the Mac or uses a cloud transcription provider if you added one (§7).
- **Audio and video files.** Dropping a recording on a composer (`.m4a`, `.mp3`, `.wav`, `.mov`, `.mp4`, a voice
  memo) attaches its transcript as a text file with timestamps, made on the Mac, with the audio itself not sent.
  Long recordings are what `SpeechTranscriber` is built for: a meeting becomes notes, an interview becomes quotes.
- **Show me how** (40) uses the same transcription for your narration.
- **Agents answering aloud** (a voice note back on Telegram, a spoken answer on the iPhone app of 30 K3): later (§10).

## 7. Where speech goes

| Piece | Default | Optional (Settings › Voice) |
|---|---|---|
| **Hearing** (speech to text) | Apple `SpeechTranscriber` on the Mac; the language model downloads once, with the system's progress | A cloud transcription provider you already have a key for (OpenAI, ElevenLabs, Groq, Deepgram); or a local Whisper-class model downloaded on request |
| **Tidy** | Apple's on-device model | A model you pick from your providers |
| **Speaking** (text to speech) | `AVSpeechSynthesizer` with a voice you pick (Premium voices download from System Settings; Personal Voice if you made one) | A cloud voice from a provider you have a key for (OpenAI, ElevenLabs) |

Every cloud option is off until you turn it on, and says so where it is used ("Heard by OpenAI"), as local by default
asks. Cloud hearing and speaking are counted in the usage ledger (34) and shown in Spend. A cloud provider gets only
the audio of one dictation or one answer, never the conversation.

**Not a speech-to-speech model.** Realtime voice models (OpenAI Realtime, Gemini Live) answer fastest, but they would
run the conversation outside pi: their own tools, no approvals, no memory, no provider order, one provider. Talk mode
keeps pi's turn and adds hearing and speaking around it (stay close to pi). The latency budget (§9 VO6) is what makes
this good enough.

## 8. Safety and privacy

- **Piopio listens only while it shows that it listens:** the composer's meter or the talk pill, plus macOS's own
  microphone indicator. No wake word, no listening in the background, nothing on while the screen is locked.
- **Audio isn't kept.** It's transcribed and dropped; the message keeps the text. A file you attach stays your file.
- **Voice never approves.** Approvals, Allow always, payments and sign-ins (22) need a click or a key. Speech can be
  misheard and can come from a television or someone else in the room. Questions by voice are fine because they only
  shape what you asked for; a question that would lead straight to a change is still followed by its approval.
- **Talk mode doesn't widen permissions.** It runs with the conversation's permission chip; Full auto in talk mode asks
  once, "Full auto is on: Piopio may change files while you talk. Keep it?"
- **Permissions:** Microphone (`NSMicrophoneUsageDescription`, the audio-input entitlement), and Speech Recognition if
  the system asks for it with the analyzer. Asked the first time you press the microphone, with one line on why.
- **Echo.** In talk mode the microphone uses the system's voice processing (echo cancellation) so Piopio doesn't hear
  its own voice through the speakers; with headphones it isn't needed.

## 9. Decisions (to confirm)

| # | Decision | Alternative considered |
|---|---|---|
| VO1 | **Dictation lands in the composer and waits.** You read it and send; Send when I let go is a setting, off by default. | Send on release, as Claude Code's tap mode: faster, but a misheard word goes straight to the model. |
| VO2 | **On the Mac by default:** Apple's transcriber, the on-device model for Tidy, system voices. Cloud hearing and voices are opt-in providers. | A cloud transcriber by default: better with mixed languages, but a new destination for everything you say. |
| VO3 | **Talk mode is ordinary turns** with hearing before and speaking after, on the conversation's model, through pi. | A realtime speech-to-speech model: lower latency, but outside pi's loop, tools and approvals. |
| VO4 | **Voice never approves.** Questions may be answered by voice; approvals, sign-ins and payments need a click or a key. | "Allow" by voice in Ask mode: hands-free, but unsafe with a room or a speaker playing. |
| VO5 | **Spoken answers are shaped per message, not per conversation.** A spoken message carries a short note in its turn context (38): "the user is listening; answer to be heard: short, no tables, say what you put on screen". Typing in the same conversation drops it. | A voice system prompt: breaks the prompt cache and sticks after you go back to typing. |
| VO6 | **Latency budget:** first spoken word within 1.5 s of you stopping on a fast model; end of speech detected in about 1 s; interrupting stops the voice within 200 ms. | No target. |
| VO7 | **Tidy never changes meaning:** fillers, punctuation, code formatting and lists only; no translating or summarizing; ⌘Z gives the raw words. | A rewrite into a better prompt: tempting, but you didn't say it. |
| VO8 | **No audio kept, no wake word.** | Keeping audio to re-transcribe later; "Hey Piopio". |
| VO9 | **One transcription helper for everything:** composers, talk mode, voice notes, files, Show me how. | One per feature. |

## 10. Phases

| Phase | What | Done when |
|---|---|---|
| **VC0** · spike | `SpeechTranscriber` and `DictationTranscriber` on the user's Mac: Spanish, English and mixed; contextual strings; partial results latency; a 1-hour recording; voice processing with the speakers on. Twenty sentences the user records (Build prompts with file names, a chat, an agent note), scored by words wrong | A note in `docs/research/voice.md` with the numbers, and which transcriber and settings VC1 uses (or that mixed speech needs §7's local or cloud model first) |
| **VC1** · dictation | The microphone button in every composer, click and hold, ⌥⌘D, live grey text, the vocabulary list, Tidy with ⌘Z, spoken mentions, the language menu, Settings › Voice, the glyph in the transcript, holding ⌥Space for Quick Chat | The user dictates a Build prompt in Spanish with two file names and an agent mention and sends it without fixing a word |
| **VC2** · files and voice notes | `piopio-speech` (a helper like `piopio-fm`) that turns an audio file into timestamped text for the engine; attachments of audio and video; Telegram voice notes on the Mac; Show me how's narration | A 30-minute meeting recording becomes a transcript attachment in under a minute; a Telegram voice note reaches the agent as text |
| **VC3** · talk mode | The talk pill, end of speech detection, streamed speech sentence by sentence, interrupting, read and not read, questions by voice, approvals on the pill, the per-message note (VO5), echo cancellation | A ten-minute spoken session in a Build project (ask, interrupt, answer a question, approve with a key) meets VO6 |
| **VC4** · cloud voices | Cloud transcription and voice providers, the "Heard by" and "Voice by" labels, the ledger rows, a cloud agent's voice notes with the Mac off; the local Whisper-class model if VC0 asked for it | A voice note to a cloud agent is answered with the Mac asleep, and Spend shows its cost |

**Later:** agents answering with voice notes; voice on the iPhone app (30 K3), which reuses the same pieces; a
realtime model for Chat-only talk if VC3's latency disappoints; voice for Show me how's steps.

**Order:** VC0 and VC1 are small and stand alone (a "small thing" for track H). VC2 helps agents, and channels come after agents
work well in the app, so it follows VC1. VC3 after a few weeks of VC1.

## 11. Under the hood

- **App, `Voice/`:** `Listener` (an `AVAudioEngine` input tap, voice processing on in talk mode, feeding a
  `SpeechAnalyzer` with the chosen transcriber; volatile and final results as an `AsyncStream`); `Vocabulary` (builds
  the contextual strings from the project, the conversation, agents and memory); `Speaker` (a sentence splitter over the
  streaming answer that skips code, tables and visuals, feeding `AVSpeechSynthesizer` or a cloud voice); `TalkSession`
  (a state machine: idle, listening, sending, thinking, speaking, interrupted, ended). The composer gets the button and
  the live text as an inserted, marked range in its `NSTextView`.
- **Tidy:** a `piopio-fm` request with fixed instructions and the raw text; the length check of VO7 in the app.
- **`piopio-speech`:** a small command, like `piopio-fm`, that reads an audio file and writes timestamped text; the
  engine calls it for voice notes and attachments, so it works with the app closed. Telegram's OGG Opus needs decoding
  first (§13).
- **Protocol:** `sessions.send` gains `input: "voice"` (and `"voice-talk"` in talk mode), stored on the message for the
  glyph and used by the engine to add VO5's note to that message's turn context (38). Cloud providers are reached by the
  engine (`voice.transcribe`, `voice.speak`), where the keys and the ledger already are.
- **Tests:** the sentence splitter and what it skips; vocabulary building; Tidy's length guard; the talk state machine
  with a scripted listener and speaker; the engine's turn-context note appearing only on voice messages (the prefix
  test of 38 stays green).

## 12. Questions for you

1. **The keys.** ⌥⌘D to dictate and ⌥⌘T for talk mode, and holding ⌥Space for Quick Chat: good, or do you want hold to
   talk on a single key (as Claude Code's space) while the composer has focus?
2. **Send when I let go:** off by default (VO1), or on?
3. **Mixed Spanish and English:** if VC0 shows Apple's transcriber misses English terms in Spanish speech, would you
   rather add a local Whisper-class model (a download of about 1 GB, on the Mac) or a cloud transcriber with your key?
4. **Talk mode's voice:** a system voice first, or is a cloud voice (better, paid, opt-in) worth it from VC3?

## 13. Not verified

- Which languages `SpeechTranscriber` supports on macOS 27 and how well it handles code-switching; whether its analysis
  context takes contextual strings as the old `SFSpeechRecognizer` did (`contextualStrings`).
- Whether the analyzer needs Speech Recognition authorization on top of the microphone.
- Whether AVFoundation decodes Telegram's OGG Opus voice notes directly or Piopio has to unwrap the Opus packets first.
- Claude Code's languages for `/voice` (a figure of 20 appears in one article, not in the docs).
- That the latency budget (VO6) is reachable with streamed speech on the user's default model; VC0 and VC3 measure it.

Sources: [Claude Code voice dictation](https://code.claude.com/docs/en/voice-dictation),
[TechCrunch on its launch](https://techcrunch.com/2026/03/03/claude-code-rolls-out-a-voice-mode-capability/),
[Apple `SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber),
[Apple `DictationTranscriber`](https://developer.apple.com/documentation/speech/dictationtranscriber),
[WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/),
[Wispr Flow vs Superwhisper (Flow's own comparison)](https://wisprflow.ai/post/wispr-flow-vs-superwhisper).
