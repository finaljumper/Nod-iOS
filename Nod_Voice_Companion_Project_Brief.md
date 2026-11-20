# Nod Voice Companion
Product brief & implementation roadmap  •  19 November 2026
Status: planning document. This captures the agreed direction and separates unresolved engineering decisions from proposed implementation details.
## 1. Product vision
Build a native Apple-device voice companion for the existing Nod by n8n assistant running continuously on a Mac mini. The companion should let the user naturally speak to Nod from iPhone or iPad, hear its replies, interrupt it, and supervise real-world digital-life tasks. Nod remains the single source of reasoning, memory, tools, schedules and permissions.
### Primary use cases
- Ask Nod to summarize email, calendar and pending tasks while away from the desk.
- Research services, manage personal administration and initiate browser-driven workflows.
- Request updates on monitoring jobs and approve or reject sensitive actions.
- Carry on a multilingual conversation in English, Russian or Korean, including code-switching.
### Non-goals
- Rebuild Nod, its agent orchestration, memory or tools inside the mobile app.
- Create a second LLM/reasoning service for the voice layer.
- Move the MacBook development environment onto the Mac mini.
- Require cloud speech transcription or cloud voice synthesis for the initial design.
## 2. Agreed product decisions
Nod is already installed and used. It runs on the always-on Mac mini, which is separate from the MacBook development environment. The client will be native Swift/SwiftUI. Speech recognition should run on-device; Apple SpeechAnalyzer and WhisperKit will be benchmarked before selection. Voice output should also be on-device, but the TTS engine is not selected. Support English, Russian, Korean and mixed-language speech. Nod continues using its existing model/provider configuration; no additional reasoning model is needed.
## 3. System architecture
Microphone → local capture / voice activity detection → on-device STT → authenticated Nod transport → Nod agent, tools, memory and approvals → streamed text/events → on-device TTS → speaker.
- iOS/iPadOS client: SwiftUI screens, AVAudioSession, recording, transcription, playback, conversation state and approval UI.
- Nod on Mac mini: task execution, existing memory, app integrations, browser automation and permission enforcement.
- Transport: investigate Nod’s supported APIs and event semantics first. If inadequate, introduce a minimal authenticated adapter on Mac mini; do not assume a streaming API exists.
- Remote access: use a secure private network or authenticated TLS endpoint; do not expose an unauthenticated Nod service.
## 4. Interaction requirements
- Tap-to-talk is sufficient for MVP; hands-free and wake-word modes are later possibilities.
- Show live partial transcript, final transcript, assistant response and tool/approval status.
- Begin speaking a reply before the entire answer finishes when transport and TTS support it.
- Barge-in: user speech stops current playback immediately and starts a new turn; cancellation semantics must be verified against Nod.
- Make it obvious when Nod is thinking, using a tool, waiting for approval or disconnected.
- Provide a text fallback, retry controls and a visible history of actions and approvals.
## 5. Speech recognition benchmark
Implement one shared Swift recognition protocol and identical audio-replay harness for Apple SpeechAnalyzer and WhisperKit. Use a fixed evaluation corpus recorded on representative iPhone/iPad hardware.
| Dimension | Measurement |
| --- | --- |
| Accuracy | WER/CER by language; named entities; code-switching error analysis |
| Responsiveness | Time to first partial, stable partial and final transcript |
| Resources | Peak memory, CPU, battery/energy, model footprint |
| Robustness | Quiet/noisy rooms, accents, interruptions, short and long utterances |
| Product fit | Offline behavior, language availability, API stability, integration complexity |

Corpus: matched English, Russian, Korean and mixed-language clips, including commands, dates, names, addresses and conversational speech. Keep ground-truth transcripts and scoring rules versioned. Select the engine from measured results, not assumptions.
## 6. Voice synthesis
Use on-device TTS with English, Russian and Korean voice coverage. Engine selection remains open. Evaluate intelligibility, naturalness, first-audio latency, streaming/chunking, voice switching, interruption responsiveness, offline footprint and licensing. A prior example engine was discussed but not adopted.
## 7. Security and reliability
- Store tokens in Keychain; prefer short-lived scoped credentials and secure device enrollment.
- Require explicit approval for sending emails, purchases, cancellations, financial actions and official submissions.
- Never bypass Nod’s own permission checks; the mobile UI is an additional approval surface, not a replacement.
- Use encrypted transport, reconnect/backoff, clear error states and minimal sensitive logging.
- Support foreground operation first; background listening and always-on microphone behavior require separate platform/privacy review.
## 8. Delivery roadmap
### Phase 0 — Nod integration discovery
Inspect installed Nod version, documented API, auth, conversation/session IDs, streaming/event delivery, tool status, approvals and cancellation. Produce a tested integration contract.
### Phase 1 — STT benchmark
Build Swift project, shared recognition interface, replay harness, ground-truth corpus and metrics report. Select STT implementation.
### Phase 2 — Text client
Implement secure connection, conversation view, send/receive, streaming if available, status and approvals. Verify end-to-end with Nod before voice integration.
### Phase 3 — Voice MVP
Add microphone capture, chosen STT, on-device TTS, push-to-talk, playback interruption, error handling and basic observability.
### Phase 4 — Conversational polish
Optimize latency, partial-response speech, turn detection, barge-in, multilingual transitions and recovery after network interruption.
### Phase 5 — Optional enhancements
Hands-free mode, Siri/Shortcuts entry points, widgets, notifications and additional Apple-device support.
## 9. MVP acceptance criteria
- On an iPhone or iPad, the user can speak a request and have Nod execute it on Mac mini without opening a laptop.
- The user can read the transcript and hear a spoken response locally.
- English, Russian and Korean are evaluated and supported to a documented quality threshold; code-switching is explicitly tested.
- A user interruption promptly stops playback and does not silently trigger unwanted actions.
- Sensitive actions surface a clear approve/deny step.
- The client handles disconnect/reconnect without duplicating consequential requests.
## 10. Open decisions and risks
- Does the installed Nod version expose a supported streaming conversation API, and can it propagate cancellation and approval events?
- Which STT engine wins on mixed-language quality and latency on target devices?
- Which on-device TTS engine meets voice quality and interruption needs?
- What secure remote-access approach offers the best iPhone usability?
- How should turn detection work: push-to-talk initially, then VAD/hands-free?
- What are the latency and quality targets after baseline measurement?
- How do we avoid double execution after retries or reconnections?
## Immediate next action
Audit the running Nod integration surface and create the Swift STT benchmark project in parallel. Do not commit to a TTS engine or custom gateway until the integration and benchmark evidence is available.
