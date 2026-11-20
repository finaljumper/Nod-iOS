# NodCompanion

The iPhone and iPad app for talking to Nod: speak or type a request, hear and read the reply,
see what Nod is doing, and approve or refuse sensitive actions. It has a hands-free dialogue
mode in which the app listens all the time and talking over a reply stops it.

This is the app from the product brief (`../Nod_Voice_Companion_Project_Brief.md`) and the
implementation specification (`../Nod_Voice_Companion_Implementation.md`). It talks to a
self-hosted Nod over HTTPS once the connection is set up; the app starts with that setup
when there is none, and a stand-in inside the app answers until then. It is in use on one
iPhone 17 Pro against its owner's Nod; the automated tests run against a stand-in only.

## Status

| Part | State |
| --- | --- |
| Conversation and dialogue logic (`NodCore`) | Written and tested: 127 unit tests pass |
| Voice: Supertonic 3 through sherpa-onnx | Produces English and Korean audio on a Mac (0.3 to 0.7 s per sentence) and speaks in the iPhone simulator. On an iPhone 17 Pro it has been heard, in the dialogue and as the samples in Settings |
| Voice: Phonon through FluidAudio (English only) | On a Mac it renders about 17 to 20 times faster than real time, and Apple's recogniser transcribed its audio correctly. In the iPhone simulator the model downloads, loads and plays without an error. Not confirmed on a device |
| Speech recognition: Apple, Rumble-2-Flash | On a Mac, audio files fed through the app's listening code came back as the right text, one result per utterance, in English and Korean. On an iPhone 17 Pro the dialogue has been used with a real microphone; which recogniser was chosen then is not recorded, and Rumble-2-Flash is not confirmed on a device |
| Dialogue mode | Used on an iPhone 17 Pro. With the first build the app heard its own voice on the loudspeaker and cut itself off. The echo handling written since (see below) was tested with recorded audio on a Mac and is installed on that phone; **whether it cures the cut-off there is not confirmed** |
| Screens (`App/`) | Run in the iPhone simulator and on an iPhone 17 Pro, where its owner confirmed the conversation at launch and the Settings samples. Not run on an iPad, not checked on iPad layouts |
| Connection to Nod (`Sources/NodCore/Nod`) | Written from Nod's server source and tested against a stand-in server that answers in the same shapes; the network layer is tested against a local HTTP server. On the iPhone it connects to a real Nod and shows its conversation (83 entries at the time), and its owner reports the dialogue working as a proof of concept. **Approvals, attachments, Stop and recovering from lost events are not confirmed against a real Nod**, and no automated test runs against one, because a test would act on the real agent |
| Connection setup | In the simulator, against a stand-in for Nod on https://localhost: the three steps pass and the conversation appears; with live updates held back the check fails, says why, and nothing is saved. An http:// address is refused. **The three-step setup has not been run against a real Nod**; the iPhone was connected with the two-step setup that preceded it |

## Getting started

Requirements: Xcode 26.1 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), iOS 26 or
later. Speech recognition needs a real device.

Download the Supertonic voice model once (about 145 MB, kept out of the repository). The other
models are downloaded by the app itself when they are first chosen:

```bash
sh Scripts/fetch-supertonic.sh
```

Download the voice detector (under 1 MB) the same way. Without it the app still listens, but
tells speech from other noise by loudness alone:

```bash
sh Scripts/fetch-vad.sh
```

Run the tests:

```bash
swift test
```

Generate and open the Xcode project:

```bash
xcodegen generate
```

```bash
open NodCompanion.xcodeproj
```

Set your development team on the `NodCompanion` target to run on a device.

Settings is arranged like the system's: the connection on top, then *Voice*, *Listening*,
*Developer* and *About*, each with a page of its own.

Without a connection the app starts with its setup (it is also under Settings, top row). It
has three steps: the HTTPS address at which you open Nod, its authentication token
(`NOD_AUTH_TOKEN`), and a check of everything the app needs: Nod answers, the key is
accepted, the conversation can be read, and live updates arrive. The check only reads;
nothing is sent to the agent. The connection is saved only when all of it worked, and the
setup cannot be finished before that; what failed is named. From then on the app shows Nod's
existing conversation and what you say goes to the real agent. *Try the Demo Assistant
Instead* closes the setup without a connection.

The app opens with the conversation already there, at its end and without animation, as a
messaging app does. For that the conversation as it was last shown is kept in a file in the
app's own folder (`ConversationStore`: delivered messages and finished approvals, the newest
400, no attachment content; readable only after the device was unlocked once; removed with
the connection). Nod's record replaces it as soon as it has been read, and rows that were
there stay the same rows. On the very first launch after setup there is nothing kept yet:
then the conversation appears whole once Nod's record has arrived. Only a message or two
arriving at the end of a conversation already on screen slide in.

The list lays out every row it shows instead of using a lazy stack. A lazy stack guesses the
height of rows it has not drawn, and with long and short messages mixed that guess put the
end of an 83-entry conversation in empty space on an iPhone. The newest 150 entries are
shown; *Show Earlier Messages* adds more.

Things to try with the demo assistant (before a connection is set up):

- The **waveform button** in the message card opens the dialogue (it is the send button once
  you have typed something). The microphone next to it dictates one message. In the
  dialogue, speak; the language you speak is chosen top right. In the simulator, switch on *Simulated Microphone* under Settings, Developer first: it "hears" a
  fixed phrase every few seconds.
- *What is on my calendar today?* runs a tool and answers. Ask in Korean and it answers, and
  speaks, in Korean.
- *Send an email to Alex about Friday* stops at an approval card. Nothing is "sent" until you
  approve; denying or interrupting closes the card.
- Send a new message, press Stop, or talk over a reply: the voice stops at once. Only Stop
  tells the assistant to stop working.
- *Show me markdown* answers with headings, lists, a quote, a table and code, to see how
  formatted replies look.
- The plus button attaches photos or files. The stand-in only names what it received.
- *Please disconnect now* breaks the connection after the request was accepted. The message is
  marked as unknown and is not sent again unless you press Send Again.

## Layout

```
Package.swift                 Swift package: NodCore, NodSpeech, tests
project.yml                   XcodeGen specification of the app target
Scripts/fetch-supertonic.sh   downloads the voice model into App/Resources/Supertonic3
Scripts/fetch-vad.sh          downloads the voice detector into App/Resources/SileroVAD
Sources/NodCore/              no Apple UI or audio frameworks; everything here is unit-tested
  Models.swift                messages, tools, approvals, phases
  Transport.swift             NodTransport: the app's side of the contract with Nod
  ConversationModel.swift     the rules: sending, interrupting, approvals, dialogue, reconnecting
  ConversationStore.swift     keeps the conversation in a file, so the app opens with it
  DemoTransport.swift         the stand-in for Nod
  NodAddress.swift            turns the address the user typed into Nod's HTTPS origin
  Nod/NodAPI.swift            Nod's data shapes and the event-stream parser
  Nod/NodClient.swift         typed HTTP requests, error answers, the setup checks
  Nod/NodHTTPTransport.swift  follows a request: post, event stream, state, approvals
  Nod/NodConversation.swift   Nod's stored conversation as the app shows it
  Speech.swift                SpeechOutput and SpeechInput protocols, simulated microphone
  SpeechText.swift            sentence splitting, language splitting, Markdown removal
  UtteranceEndpointer.swift   finds the start and end of an utterance: loudness, voice, echo
  EchoFilter.swift            recognises the app's own words in what the microphone heard
  Markdown.swift              cuts a reply into blocks: paragraphs, lists, code, tables
Sources/NodSpeech/
  VoiceAudioEngine.swift      one audio engine for playback and the microphone
  SupertonicSynthesizer.swift text to audio with Supertonic 3 (sherpa-onnx C interface)
  PhononVoice.swift           text to audio with Phonon (FluidAudio, Core ML)
  RenderedSpeechOutput.swift  speaks with whichever neural voice knows the language
  SystemSpeechOutput.swift    the system's voices, the fallback
  UtteranceRecognizer.swift   the two recognisers as RecognitionEngine values
  RumbleRecognizer.swift      Rumble-2-Flash through sherpa-onnx
  ModelDownloader.swift       fetches model files from Hugging Face into Application Support
  VoiceDetector.swift         Silero voice detector (sherpa-onnx): is this sound a voice?
  LiveSpeechInput.swift       microphone to text as a SpeechInput
App/                          SwiftUI app: AppState, Keychain storage and the screens
Tests/NodCoreTests/           unit tests
VoiceComparison/              the voice comparison that preceded the choice of Supertonic 3
```

## How the dialogue works

1. One audio engine plays the voice and captures the microphone, with the system's voice
   processing switched on. That removes most of the app's own voice from the microphone
   signal, but on the loudspeaker not all of it.
2. Sound counts as you talking when it is loud enough **and** the Silero voice detector hears
   a voice in it. A door, typing, a tone or traffic does not start an utterance, however loud.
   0.2 s of speech starts an utterance, 0.8 s without ends it.
3. While the app speaks, "loud enough" is measured against the app's own playback. The engine
   reports the loudest 20 ms it played in the last 0.3 s, with the device's volume setting
   counted in. The listener learns how much of that arrives at the microphone and only takes
   what is 8 dB louder than that for you. Louder playback therefore needs a louder voice to
   interrupt it, quieter playback a quieter one.
4. When something is heard while the app speaks, the voice is **paused**, not stopped. Once the
   words are recognised they are compared with what the app was saying. Its own words, or no
   words at all, let the voice go on and nothing is sent; the listener then raises its measure
   of the echo. Your words end the voice for that reply and are sent.
5. Each utterance is recognised on its own. The reply is spoken sentence by sentence as it
   arrives.

*Interrupt by Talking* in Settings switches step 3 and 4 off: the app then does not listen
while it speaks, and Stop interrupts it.

In a simulation with recorded speech (`voice-check gate`, a scratch tool, not in this folder),
an echo 8 to 35 dB below the playback never started an utterance, where loudness alone started
up to three per reply. Talking over the app got through about 0.6 s after starting when the
voice was roughly 10 dB or more above the echo's loudest moments, and not when it was closer.

## How the app talks to Nod

Nod's HTTP interface is not a published one. The shapes used here were read from its server
source (github.com/n8n-io/nod, commit 79f194a of 2026-11-20); check them against the version
that is deployed. All of it sits in `Sources/NodCore/Nod`.

| What | How |
| --- | --- |
| Key | `Authorization: Bearer …` on every request, read from the Keychain. Never in an address, a log or the settings. No cookies, no `Origin` header. Redirects are not followed, so the key cannot be carried to another address |
| Connecting | `GET /api/session` for the account, `GET /api/state` for the conversation, then `GET /api/events?account=…` as an event stream |
| Sending | `POST /api/messages` with `text`, `threadId` and `clientMessageId`. Nod stores the message under that identifier, so the same message sent again is answered with the first result and not acted on twice |
| Reply | `delta` events carry pieces of text that are appended. A `refresh` event means "read the state again"; the state says when a turn is over. Text that was stored but never streamed (events were down) is taken from the state |
| Approvals | An approval hangs on an assistant message in the state. It is answered with `POST /api/messages`: `replyToMessageId`, `approvalAnswer` and a non-empty `text` (the app sends "Approve" or "Decline"). The answer names the turn that carries the action out, and the app follows that turn |
| Photos and files | Each is stored first with `POST /api/uploads` (a form with one `file`), and the identifiers Nod returns go into the message as `attachmentIds`. A message may be attachments alone. What was stored is remembered until the message is accepted, so trying again does not upload twice |
| Stop | `POST /api/thread/stop`. It ends all of the agent's work in the conversation, not one request |
| Lost events | The stream is reopened with growing pauses. Missed events cannot be replayed; the state read after reconnecting fills the gap. After three failed attempts the request in progress is marked "outcome unknown" |
| Refusals | 401 (key), 403 (wrong public address), a redirect (a sign-in in front of Nod) and answers that are not Nod's are told apart and not retried on their own |

After every turn, and whenever Nod reports a change, the conversation shown is replaced by Nod's
own record. That is how messages from the web app or another device appear here.

## Rules the conversation logic enforces

These hold whichever transport, recogniser and voice are attached, and each has a test.

- **A new message or your voice silences the reply, but does not stop Nod.** Playback stops at
  once and the app turns to the new request. Nod's stop ends everything it is doing in the
  conversation, so only the Stop button triggers it.
- **Approvals are given by tapping, never by voice.** Nod reads a message that arrives while an
  approval is open as a possible answer to it. So while an approval is open, spoken words are
  not sent at all. Typed messages are, as in the web app.
- **The app does not close approvals on its own.** They are Nod's. An approval that Nod no
  longer holds open is shown as expired when a decision is attempted.
- **A request Nod has accepted is never sent twice on its own.** Before Nod acknowledges a
  request, a lost connection is retried automatically. After that, the message is marked as
  "outcome unknown" and only the user can send it again; with Nod that repeat is safe because
  it carries the same identifier.
- **A refusal is not retried.** A key that is not accepted stops the connection attempts until
  the setup is changed or something is sent.
- **Replies are spoken sentence by sentence**, each part in its own language (Hangul as Korean,
  Cyrillic as Russian, Latin letters as English). What was said before the app connected is
  shown but not read out.

## The engines and how to change them

The voice and the recogniser are chosen in Settings.

**Voices**, all behind `SpeechOutput`:

| Voice | Languages | Runs on | Size |
| --- | --- | --- | --- |
| Supertonic 3 (default) | English, Korean and 29 more | sherpa-onnx 2.0.0 with `csukuangfj/onnxruntime-libs` 1.28.2, as in LangPal | 145 MB, bundled |
| Phonon 31m | English only | Core ML, through FluidAudio 0.18.3 | about 170 MB, downloaded on first use |
| System voices | whatever is installed | AVSpeechSynthesizer | none |

With Phonon chosen, English is read by Phonon and everything else by Supertonic, so a Korean
reply changes voice. A voice that fails hands the sentence to the next one, and last to the
system voice. A new voice is one type that conforms to `SpeechRendering`.

**Recognisers**, each one `RecognitionEngine` value in `UtteranceRecognizer.swift`:

| Recogniser | Languages in the app | Runs on | Download |
| --- | --- | --- | --- |
| Apple Speech (default) | English, Korean; one at a time | `SpeechTranscriber` through [AnySpeechRecognizer](https://github.com/mattt/AnySpeechRecognizer) 0.1.0 | the system's speech model |
| Rumble-2-Flash | English, Korean, and sentences that mix them | CPU, sherpa-onnx (`TypeWhisper/Rumble-2-Flash-sherpa-onnx-int8`) | about 620 MB |

Two things to know before changing this part:

- MLX builds of these models cannot be used here. mlx-audio-swift needs swift-huggingface below
  1.0.0 and AnySpeechRecognizer needs 1.0.0 or later. That is why Rumble runs through
  sherpa-onnx; the MLX route exists only in `../VoiceASRBenchmark`.
- Audio is converted to 16-bit integers before it is handed to AnySpeechRecognizer.
  `AnalyzerInput(buffer:)` traps on floating-point buffers on macOS 27.

- **Nod.** `App/AppState.swift` creates `NodHTTPTransport` when an address and a key are
  stored and `DemoTransport` otherwise. Both conform to `NodTransport`.

## Known gaps

- The dialogue ran on an iPhone 17 Pro as a proof of concept. On the loudspeaker the app heard
  its own voice and cut itself off. The playback-aware cutoff, the voice detector and the
  pause-then-decide step were written against that and tested with recorded audio on a Mac.
  They are installed on the phone, but **whether they cure the cut-off there is not
  confirmed**. How strong the echo is on a real device decides how loudly one has to speak
  to interrupt; `UtteranceEndpointer.Settings` holds the numbers.
- The app's own voice is recognised by its words. A short answer that mostly repeats what the
  app just said can be taken for an echo and ignored. Another person talking nearby is a voice
  and is taken for you.
- The system voices do not go through the app's audio engine, so none of the echo handling
  applies to them.
- Everything the neural voices say is played in one format (44.1 kHz), and the player is
  connected anew before every start of the audio engine. Before that, speech played after a
  dictation or dialogue had ended, such as the samples in Settings, could come out wrong, and
  a reply that switched between Phonon and Supertonic could be cut. The fix is checked in the
  simulator only; the case after a dialogue needs a real device.
- When the system resets the audio (a route change, say) it stops the engine and the player.
  The engine now gives the player everything not yet heard once more; the sentence that was
  being heard starts again. If the engine cannot start, the system voice says the sentence
  and Settings, Voice shows the reason. Neither case has been seen happening.
- On an iPhone 17 Pro the Settings samples were traced: the engine starts with the playback
  category on the loudspeaker, the sample reaches the mixer at about -18 dBFS and is played
  to its end. The phone's volume was at 20 to 30 % then, which is why the samples seemed
  silent: with the volume turned up they are heard. The dialogue uses the phone's separate
  call volume, so it can be loud while the samples are not. Settings, Voice says so when the
  volume is below 30 %.
- To trace the voice on a device, launch a debug build with `NOD_AUDIO_TRACE=1` and
  `NOD_PLAY_SAMPLE=en` in the environment:
  `xcrun devicectl device process launch --console --terminate-existing -e '{"NOD_AUDIO_TRACE":"1","NOD_PLAY_SAMPLE":"en"}' --device <id> Small-Problems-Software.NodCompanion`.
  The app speaks the sample by itself and writes what the audio engine does to the console.
- One spoken language at a time with Apple's recogniser: a Korean sentence with English words
  in it is recognised as Korean, and switching language restarts listening. Rumble-2-Flash
  followed a mixed sentence in the one file test that was made.
- Rumble was only run on a Mac. Its memory use and speed on an iPhone are not known; it
  decodes on the CPU after the utterance ends.
- The downloaded models (Rumble-2-Flash is about 620 MB, Phonon comes on top) stay in the
  app's Application Support folder; there is no button to remove them. The model of Parakeet
  v3, a recogniser the app no longer offers, is deleted at launch on iOS.
- AnySpeechRecognizer is early work; its own notes say it was not tested on an iPhone.
- Supertone has stopped developing the open-source Supertonic models. The weights are under
  the BigScience OpenRAIL-M licence.
- The Supertonic model adds about 145 MB to the app.
- With Nod, the conversation as it was last shown is kept on the device (see Getting
  started); the text of the messages is in that file. With the stand-in the conversation is
  gone when the app quits.
- **Only part of this has been seen working against a real Nod**: connecting and showing the
  conversation, traced on one iPhone, and the dialogue as its owner reports it. What is most likely to differ from
  the stand-in in the rest: which turn carries a reply after an approval or a question, the
  text Nod expects with an approval answer, what `activity` reports while tools run, and
  what Nod does with a message that arrives while a turn is running.
- Nod's questions with answer choices are shown as plain text; there are no choice buttons.
  Verification codes and payments are not handled.
- Attachments: photos are scaled to 2048 pixels and sent as JPEG, which also drops their
  location data. Files over 25 MB are refused by the app (Nod itself takes 90 MB). There is no
  camera button. Attachments that come from Nod's record, sent from elsewhere or by Nod, are
  shown by name and size only; their content is not downloaded. Sending to a real Nod is
  tested against the stand-in server only.
- Replies are rendered as Markdown block by block; nested quotes, images and footnotes are
  shown as plain text. What the user typed is shown as typed.
- Only the most recent messages Nod returns with its state (up to 150) are available; earlier
  ones are not fetched from Nod. *Show Earlier Messages* only reveals entries that are
  already loaded.
- While an approval is open, also an old one from before, spoken input is held back. It has to
  be decided or run out first.
- The tool lines shown during a turn are the app's own and disappear when Nod's record
  replaces the conversation; the Activity screen keeps them.
- A sign-in in front of Nod, such as Cloudflare Access, is recognised but not supported.
- Only HTTPS addresses are accepted, so a Nod that is reachable only as http:// on a local
  network cannot be used.
- Foreground only. No background audio, notifications, widgets or Siri.
- Latin text is always read as English, also when it is another language.
