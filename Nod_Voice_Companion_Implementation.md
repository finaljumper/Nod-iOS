# Nod Voice Companion — Implementation Specification

**Updated:** 2026-11-20  
**Status:** Implementation planning; source-inspected Nod API, not a stable public SDK  
**Target:** Native SwiftUI iPhone/iPad voice client for an existing self-hosted Nod instance on a Mac mini, reachable over an HTTPS Cloudflare Tunnel.

## 1. Goal and scope

Build a lightweight native voice interface to **the user's existing Nod agent**, preserving its conversation, memory, tools, tasks, and approval flow. The client does on-device speech recognition and synthesis; **Nod remains the only reasoning/agent backend**. The MacBook development environment is unrelated to the Mac mini server.

### MVP

- Connect to an existing Cloudflare-hosted Nod HTTPS URL using Nod's bearer token.
- Fetch the existing session, active thread, recent messages, status and pending approvals.
- Send transcribed text to the existing conversation.
- Receive incremental assistant text and activity over Server-Sent Events (SSE).
- Play assistant text with local TTS, with immediate playback interruption.
- Surface approvals and explicit agent-stop controls.
- Handle reconnects and retries without duplicate consequential commands.
- Support English, Russian and Korean, including mixed-language utterances.

### Non-goals

- A new agent, second reasoning LLM, or duplicate memory.
- Moving the MacBook coding environment to the Mac mini.
- Requiring server-side/cloud speech recognition for the initial voice workflow.
- An always-listening background microphone in the MVP.

## 2. Architecture

```text
iPhone / iPad (SwiftUI)
  ├─ AVAudioSession + microphone capture
  ├─ Local STT (benchmark Apple SpeechAnalyzer vs WhisperKit)
  ├─ Conversation / approval UI
  ├─ NodTransport (URLSession HTTP + SSE)
  ├─ Keychain (Nod token)
  └─ Local TTS (engine TBD)
              │
              │ HTTPS + Authorization: Bearer …
              ▼
      Cloudflare Tunnel (existing)
              │
              ▼
      Self-hosted Nod on Mac mini
        ├─ Single existing conversation/thread
        ├─ LLM and persistent memory
        ├─ Tools/browser/integrations
        └─ Permissions/approvals
```

**Recommendation:** Connect directly to Nod's existing HTTP/SSE interface first. Add a thin gateway only if internal-protocol churn, authentication, or event processing proves problematic. A custom WebSocket server is unnecessary for the verified text-streaming path.

## 3. Source-inspected Nod HTTP API

Inspected upstream source in `n8n-io/nod` on 2026-11-20. These routes are **implemented in source**, but not promised as a versioned public API. Check the deployed Nod version before shipping the client.

| Method | Path | Use |
| --- | --- | --- |
| `GET` | `/api/health` | Health status (`{ "ok": true }`) |
| `GET` | `/api/session` | Session/account identity; retrieve user ID for event subscription |
| `GET` | `/api/state` | Active `threadId`, recent `messages`, `turns`, pending approval/verification state, activity, configuration |
| `GET` | `/api/messages` | Paginated message history; query accepts optional `before`, `beforeId`, `threadId` |
| `POST` | `/api/messages` | Send user text or submit answers/approvals |
| `GET` | `/api/events` | SSE stream: `refresh`, `activity`, `delta` |
| `POST` | `/api/thread/stop` | Stop active Nod agent work |
| `POST` | `/api/messages/audio` | Nod's audio submission path; not needed for local-STT MVP |
| `POST` | `/api/conversation/reset` | Reset conversation; not an MVP feature; destructive |

### Source references

- [Server routes and SSE implementation (`src/server/app.ts`)](https://github.com/n8n-io/nod/blob/main/src/server/app.ts)
- [Text-message input validation (`src/server/audio-messages.ts`)](https://github.com/n8n-io/nod/blob/main/src/server/audio-messages.ts)
- [Authentication and request protection (`src/server/access.ts`)](https://github.com/n8n-io/nod/blob/main/src/server/access.ts)
- [Frontend event subscription (`src/web/lib/app-events.ts`)](https://github.com/n8n-io/nod/blob/main/src/web/lib/app-events.ts)
- [Frontend API request handling (`src/web/lib/api.ts`)](https://github.com/n8n-io/nod/blob/main/src/web/lib/api.ts)
- [Network/public origin checks (`src/server/network.ts`)](https://github.com/n8n-io/nod/blob/main/src/server/network.ts)
- [Existing desktop bearer authentication example (`desktop/main/main.mjs`)](https://github.com/n8n-io/nod/blob/main/desktop/main/main.mjs)

For reproducibility, the inspected GitHub search pointed to source revision `7473a45d3beaf49697b7e7a05190b5b819b1c2a2`; pin and inspect the user's deployed version before finalizing data models.

## 4. Authentication and Cloudflare

Nod self-hosted supports:

```http
Authorization: Bearer <NOD_AUTH_TOKEN>
```

The browser client may use a session cookie exchanged through `/api/access`; **the iOS client should use bearer auth directly**. Nod enforces allowed host/public-origin checks. In requests made by native `URLSession`, don't invent a browser `Origin` header. Check `NOD_PUBLIC_URL` corresponds to the actual public HTTPS origin.

**Token protection:** provision token manually at setup, store only in iOS Keychain (`kSecClassGenericPassword` with an appropriate accessibility setting); do not embed in source, print in logs, include in analytics, or send it to an LLM. The Nod token grants broad access, so use device lock and consider an additional Cloudflare Access layer if needed. Cloudflare Access, when enabled, requires separate client authentication; it is not equivalent to the Nod bearer token.

**Read-only connectivity test** (run locally with the token in an environment variable):

```bash
export NOD_URL='https://your-nod-host.example'
# Set NOD_AUTH_TOKEN securely in your own shell; do not paste it in chat.
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${NOD_AUTH_TOKEN}" \
  "${NOD_URL}/api/session"

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${NOD_AUTH_TOKEN}" \
  "${NOD_URL}/api/state"
```

Never send a request without HTTPS on the public internet. A failure can reflect Cloudflare Access, an incorrect Host/public-origin setting, or the Nod token; distinguish them in error diagnostics.

## 5. Conversation state and sending a message

Call `GET /api/state` on initial connect. Parse at least:

- `threadId` (UUID): use for subsequent messages.
- `messages`: canonical persisted conversation content.
- `turns`: agent execution lifecycle.
- `activity`: currently running work.
- `verificationRequests` and approval data embedded in messages: actions requiring a user response.

Send text to the current thread:

```http
POST /api/messages
Authorization: Bearer <NOD_AUTH_TOKEN>
Content-Type: application/json
```

```json
{
  "text": "What's on my calendar tomorrow?",
  "threadId": "CURRENT_THREAD_UUID",
  "clientMessageId": "NEW_UUID_GENERATED_ONCE_FOR_THIS_INTENT"
}
```

The server also accepts `attachmentIds` (defaults to `[]`), `replyToMessageId`, `questionAnswer`, `approvalAnswer`, `seenMessageId`, `displayText`, `replyQuote`, `chatClearedAt`, and some verification-specific fields. Do not send fields that the workflow does not need. The input schema is strict.

**Important retry rule:** Create a `clientMessageId` once per user intent and retain it across reconnect/retry attempts. The presence of this field does not by itself prove server-side exactly-once semantics: after an uncertain send, refresh `/api/state` and reconcile before reissuing any action, especially consequential requests.

The POST response is not the entire assistant stream; listen to SSE in parallel.

## 6. Live event transport: SSE

Subscribe using:

```http
GET /api/events?account=<SESSION_USER_ID>
Authorization: Bearer <NOD_AUTH_TOKEN>
Accept: text/event-stream
```

The upstream web client supplies `account=<user.id>` in its subscription URL. The server's SSE handler emits JSON `data:` frames (with blank-line separators) and periodic `: keepalive` comments. The currently inspected server translates events to these shapes:

```json
{ "type": "refresh" }
```

```json
{
  "type": "activity",
  "items": []
}
```

```json
{
  "type": "delta",
  "threadId": "UUID",
  "turnId": "UUID",
  "text": "partial text",
  "streamId": "ID",
  "done": false
}
```

Notes:

- `delta.text` should be treated according to the deployed protocol semantics; verify whether a particular stream emits incremental chunks versus replacement text before appending blindly.
- Filter events for the active `threadId` and track `turnId`/`streamId` to avoid mixing outputs.
- On `refresh`, fetch `GET /api/state` and reconcile persisted messages, turns, status, and approvals.
- On `activity`, update a concise progress indicator.
- Handle `done` and interrupted streams by finalizing or discarding TTS buffers appropriately.
- SSE headers include `Content-Type: text/event-stream`, `Cache-Control: no-store`, `X-Accel-Buffering: no`; the server sends keepalive comments roughly every 15 seconds.
- Implement exponential reconnect backoff and a state refresh after every reconnect. Do not assume missed events can be replayed.

**Swift implementation direction:** `URLSession.bytes(for:)` with an `AsyncSequence` of lines, a dedicated SSE frame parser supporting `data:` lines, comments and blank-line dispatch, plus a typed `NodEvent` decoder. Do not treat an SSE line as a full JSON message unless parsing has confirmed a complete frame. Use an `actor` or isolated service for connection lifecycle and cancellation.

## 7. Approvals and questions

Nod handles approvals through `POST /api/messages`, not a separate approved/rejected endpoint. The persisted message state includes approval metadata. For an approval reply:

```json
{
  "text": "",
  "threadId": "CURRENT_THREAD_UUID",
  "replyToMessageId": "CONFIRMATION_MESSAGE_UUID",
  "approvalAnswer": {
    "approvalId": "APPROVAL_UUID",
    "approved": true
  }
}
```

Set `approved` to `false` to reject. Before submission, verify that the approval is still pending in freshly fetched state. Show the action title/details clearly; avoid accepting or rejecting on voice alone for sensitive actions unless a suitable explicit confirmation UX is designed. The broader `questionAnswer` structure is separate and should be modeled using its source schema before implementation.

## 8. Interruption semantics

There are **two different operations**:

1. **Stop speaking**: immediately stop local TTS and clear queued speech; Nod continues doing its work.
2. **Stop agent execution**: explicitly call `POST /api/thread/stop` to stop the active thread's work.

Do **not** automatically stop Nod when the user merely interrupts a spoken reply. UI should make both states legible. Verify whether rapid new-message submission while an existing turn runs is accepted and how Nod queues or rejects it.

## 9. Swift project layout

```text
NodVoice/
  App/
    NodVoiceApp.swift
    AppState.swift
  Features/
    Chat/ChatView.swift
    Voice/VoiceSessionView.swift
    Approvals/ApprovalSheet.swift
    Settings/ConnectionSettingsView.swift
  NodTransport/
    NodClient.swift
    NodModels.swift
    NodEventStream.swift
    SSEParser.swift
    NodAuthStore.swift
    NodErrors.swift
  Speech/
    SpeechRecognizer.swift
    AppleSpeechRecognizer.swift
    WhisperKitRecognizer.swift
    AudioCapture.swift
    SpeechSynthesizer.swift
    TurnCoordinator.swift
  Tests/
    NodTransportTests/
    SSEParserTests/
    SpeechBenchmarkTests/
    IntegrationTests/
```

### Suggested transport interfaces

```swift
protocol NodTransport: Sendable {
    func fetchSession() async throws -> NodSession
    func fetchState() async throws -> NodState
    func sendMessage(text: String, threadId: UUID,
                     clientMessageId: UUID) async throws
    func events(accountId: String) -> AsyncThrowingStream<NodEvent, Error>
    func submitApproval(threadId: UUID, messageId: UUID,
                        approvalId: UUID, approved: Bool) async throws
    func stopThread() async throws
}
```

Use `URLSession` for authenticated requests and SSE. Model error bodies and HTTP statuses; don't silently retry 401/403/409. A 409 may indicate a reset, a stale verification, or an active cancellation; surface a clear recovery flow.

### Swift connectivity sketch (illustrative, not a production client)

```swift
import Foundation

struct NodState: Decodable {
    let threadId: UUID
}

struct MessageSubmission: Encodable {
    let text: String
    let threadId: UUID
    let clientMessageId: UUID
}

struct NodClient {
    let baseURL: URL
    let token: String  // Obtain from Keychain; do not hardcode.

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    func fetchState() async throws -> NodState {
        let (data, response) = try await URLSession.shared.data(for: request("api/state"))
        try Self.validate(response)
        return try JSONDecoder().decode(NodState.self, from: data)
    }

    func send(text: String, threadId: UUID, clientMessageId: UUID) async throws {
        let payload = MessageSubmission(text: text, threadId: threadId,
                                        clientMessageId: clientMessageId)
        let body = try JSONEncoder().encode(payload)
        let (_, response) = try await URLSession.shared.data(
            for: request("api/messages", method: "POST", body: body)
        )
        try Self.validate(response)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
```

The example deliberately does not implement event streaming, secure token provisioning, body-level errors or request-reconciliation; those are required before release.

## 10. On-device voice layer

### STT

Benchmark **Apple SpeechAnalyzer** against **WhisperKit** with the same saved clips and ground-truth transcripts for English, Russian, Korean and code-switching. Compare:

- Word/character error rates (WER/CER) and proper nouns.
- Time to first partial, stable partial and final transcript.
- Memory, battery, model download size and device coverage.
- Noisy environments, accents, dates, addresses, interruptions and offline behavior.

Choose after measurement, not based solely on claimed language support. Keep a shared `SpeechRecognizer` protocol for interchangeable engines.

### TTS

Select an **on-device** TTS engine later; evaluate multilingual naturalness, latency to first audio, offline storage/licensing, chunking and immediate interruption. Avoid assuming a previously discussed example engine was adopted.

### Turn management

Initial mode: push-to-talk → final transcript → POST to Nod → SSE response → sentence-based local TTS. Then iterate toward overlapping speech/playback, barge-in, partial transcripts and turn detection. Distinguish *playback cancelled* from *agent task cancelled* in state.

## 11. Test plan and acceptance gates

### Transport tests

- Valid/invalid token; Cloudflare edge errors; wrong public origin/host.
- `/api/session`, `/api/state` and message submission against the installed version.
- SSE multiline framing, keepalive comments, network loss and reconnection.
- Two device/client connections observing the same conversation.
- Stale thread IDs after reset and duplicate message prevention.
- Approval acceptance/rejection, expiry and state reconciliation.
- Stop playback vs stop Nod agent work.

### End-to-end MVP acceptance

1. From an iPhone away from home, connect through the existing Cloudflare hostname.
2. Speak a request and see its transcription before submission.
3. Nod receives it in the **existing** conversation; the web client sees the same message.
4. The iOS client renders streamed text and reads it aloud locally.
5. A user can interrupt spoken playback without unintentionally aborting Nod.
6. A sensitive action shows an explicit approval UI and sends the correct structured answer.
7. Network interruptions recover through state reconciliation without repeating an action.
8. English, Russian and Korean test coverage is documented before claiming reliable multilingual support.

## 12. Implementation sequence

1. **Version pin / API smoke test:** record the deployed Nod commit/tag; test `/api/session`, `/api/state`, `/api/events` and message POST with a disposable prompt.
2. **Transport module:** Keychain, typed HTTP client, error handling, SSE parser, state synchronization and reconnection.
3. **Text-only SwiftUI MVP:** existing thread, messaging, activity, approvals, explicit stop button.
4. **Speech benchmark:** Apple SpeechAnalyzer and WhisperKit against the multilingual corpus.
5. **Voice MVP:** microphone capture, chosen STT, on-device TTS, push-to-talk and spoken-output interruption.
6. **Polish:** incremental speech chunking, reduced latency, robust reconnects, language switching, background/notification review.

## 13. Open questions

- Which Nod commit/tag is actually deployed on the Mac mini? Its schemas may differ from the inspected upstream revision.
- Is the public URL protected only by `NOD_AUTH_TOKEN`, or also by Cloudflare Access?
- Does the deployed `/api/events` stream emit text chunks or replace current stream contents? Confirm using live events before coding TTS buffering.
- How does the agent respond to a new user message while another turn is active?
- Which on-device STT/TTS engines meet our measured multilingual quality/latency goals?
- What foreground/background audio behavior is feasible on target iOS versions?

---

**Bottom line:** The source-inspected API already has the core primitives for a native voice interface: bearer auth, current state, message submission, SSE deltas/activity/refresh, approval answers and explicit stop. Build directly against those primitives, but isolate them in `NodTransport` because this is currently an internal implementation contract rather than an independently versioned public SDK.
