import Foundation
import Observation

/// The conversation with Nod: what was said, what Nod is doing, and what is waiting for the user.
///
/// The model owns the rules that must hold whichever transport and speech engines are attached:
/// a new message or the user's voice silences the current reply, only the user's Stop makes
/// Nod stop working, approvals are given by tapping and never by voice, and a request Nod has
/// accepted is never sent a second time on its own.
@MainActor
@Observable
public final class ConversationModel {
    public private(set) var items: [ConversationItem] = []
    public private(set) var activity: [ActivityEntry] = []
    public private(set) var phase: AssistantPhase = .idle
    public private(set) var connection: ConnectionState = .disconnected
    /// Whether the conversation as Nod holds it has been asked for since this model started.
    /// Before that, an empty conversation only means that nothing is known yet.
    public private(set) var hasLoadedConversation = false
    public private(set) var isSpeaking = false
    public private(set) var isListening = false
    /// What the recogniser has heard so far of the utterance in progress.
    public private(set) var liveTranscript = ""
    /// Hands-free dialogue: the app listens all the time and every utterance is sent.
    public private(set) var isDialogueActive = false
    /// In a dialogue: the user is talking right now.
    public private(set) var userIsSpeaking = false
    /// A message from the recogniser, such as a speech model being downloaded.
    public private(set) var speechInputNotice: String?

    /// Speak Nod's replies aloud.
    public var speaksReplies = true
    public var speechInput: any SpeechInput
    public var listeningLanguages = ["en", "ru", "ko"]

    @ObservationIgnored private let transport: any NodTransport
    /// Where the conversation is kept between launches, if it is.
    @ObservationIgnored private let store: ConversationStore?
    @ObservationIgnored private let speech: any SpeechOutput
    @ObservationIgnored private let conversationID: String
    @ObservationIgnored private let turnRetry: RetryPolicy
    @ObservationIgnored private let connectionRetry: RetryPolicy
    @ObservationIgnored private let sleep: @Sendable (Double) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored var turnTask: Task<Void, Never>?
    @ObservationIgnored var cancelTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private var accepted = false
    @ObservationIgnored private var replyID: UUID?
    @ObservationIgnored private var chunker = SentenceChunker()
    @ObservationIgnored private var speechMutedForTurn = false
    /// Whether the turn in progress has streamed any reply text.
    @ObservationIgnored private var turnHadText = false
    /// The earliest message sent from here whose reply was not streamed: its turn ended, or
    /// was left for a newer message, before any text came. Nod's reply to it then only
    /// appears when the conversation is read again, and is spoken from there.
    @ObservationIgnored private var unspokenSince: UUID?
    /// What the app has said lately, to recognise its own voice when the microphone hears it.
    @ObservationIgnored private var recentlySpoken: [(text: String, date: Date)] = []
    /// The voice is held because the microphone heard something while it spoke.
    @ObservationIgnored private var voiceHeldForUser = false

    public init(
        transport: any NodTransport,
        speech: any SpeechOutput,
        speechInput: (any SpeechInput)? = nil,
        store: ConversationStore? = nil,
        conversationID: String = UUID().uuidString,
        turnRetry: RetryPolicy = RetryPolicy(maxRetries: 4),
        connectionRetry: RetryPolicy = RetryPolicy(maxRetries: nil),
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.store = store
        // What was on screen last time is there again at once. Nod's record replaces it as
        // soon as it has been read.
        self.items = store?.load() ?? []
        self.speech = speech
        self.speechInput = speechInput ?? NoSpeechInput()
        self.conversationID = conversationID
        self.turnRetry = turnRetry
        self.connectionRetry = connectionRetry
        self.sleep = sleep
        self.now = now
        speech.onSpeakingChanged = { [weak self] speaking in self?.isSpeaking = speaking }
    }

    // MARK: Reading the state

    public var pendingApprovals: [ApprovalRequest] {
        items.compactMap { if case .approval(let approval) = $0, approval.isPending { return approval } else { return nil } }
    }

    public var speechInputAvailability: SpeechInputAvailability { speechInput.availability }

    /// What a hands-free dialogue is doing, for the dialogue screen.
    public enum DialogueState: Sendable, Equatable {
        case off, listening, hearing, thinking, waitingForApproval, speaking
    }

    public var dialogueState: DialogueState {
        guard isDialogueActive else { return .off }
        if userIsSpeaking { return .hearing }
        if phase == .waitingForApproval || !pendingApprovals.isEmpty { return .waitingForApproval }
        if isSpeaking { return .speaking }
        return phase.isBusy ? .thinking : .listening
    }

    /// Whether a user message can be sent again with the button next to it.
    public func canRetry(_ message: ChatMessage) -> Bool {
        guard message.role == .user else { return false }
        switch message.status {
        case .failed, .uncertain: return true
        default: return false
        }
    }

    // MARK: Connection

    /// Connects in the background and keeps trying until it succeeds.
    public func start() {
        guard connectTask == nil, connection != .connected else { return }
        connectTask = Task { [weak self] in
            var retry = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.ensureConnected()
                    break
                } catch {
                    if Task.isCancelled { break }
                    if case TransportError.rejected(let reason) = error {
                        self.connection = .refused(reason)
                        break
                    }
                    retry += 1
                    let delay = self.connectionRetry.delay(beforeRetry: retry) ?? self.connectionRetry.cap
                    self.connection = .waitingToRetry(attempt: retry, seconds: delay)
                    do { try await self.sleep(delay) } catch { break }
                }
            }
            self?.connectTask = nil
        }
    }

    private func ensureConnected() async throws {
        if connection == .connected { return }
        connection = .connecting
        do {
            try await transport.connect()
            connection = .connected
        } catch {
            connection = .disconnected
            throw error
        }
        observeUpdates()
        await reloadConversation()
        hasLoadedConversation = true
    }

    /// Ends everything this model has running. Used when the app switches to another Nod.
    public func shutDown() {
        stopDialogue()
        cancelListening()
        speech.stop()
        connectTask?.cancel()
        turnTask?.cancel()
        updatesTask?.cancel()
        reloadTask?.cancel()
        activeRequestID = nil
        let transport = self.transport
        Task { await transport.disconnect() }
    }

    // MARK: The conversation as Nod holds it

    private func observeUpdates() {
        guard updatesTask == nil else { return }
        let updates = transport.updates()
        updatesTask = Task { [weak self] in
            for await _ in updates {
                guard let self, !Task.isCancelled else { return }
                await self.reloadConversation()
            }
        }
    }

    /// Replaces what is shown by Nod's own record of the conversation, which also holds what
    /// was said from other devices. Not during a turn: the reply in progress is not stored yet.
    /// Messages that never reached Nod stay, so that they can be sent again.
    private func reloadConversation() async {
        guard activeRequestID == nil else { return }
        guard let loaded = try? await transport.loadConversation() else { return }
        guard activeRequestID == nil else { return }
        var known = Set<UUID>()
        for case .message(let message) in loaded { known.insert(message.id) }
        var local: [UUID: ChatMessage] = [:]
        // Replies shown while they streamed carry an identifier made here; Nod's record has
        // its own. A reply with the same text keeps the identifier it is shown under, so
        // that it stays the same row on screen instead of being replaced by a twin.
        var shownUnder: [String: [UUID]] = [:]
        for case .message(let message) in items {
            local[message.id] = message
            if message.role == .assistant, !known.contains(message.id) { shownUnder[message.text, default: []].append(message.id) }
        }
        let merged = loaded.map { item -> ConversationItem in
            guard case .message(var message) = item else { return item }
            if let mine = local[message.id] {
                // What was sent from here still has its content, for the preview.
                if mine.attachments.count == message.attachments.count { message.attachments = mine.attachments }
                message.inputMode = mine.inputMode
                return .message(message)
            }
            if message.role == .assistant, let id = shownUnder[message.text]?.first {
                shownUnder[message.text]?.removeFirst()
                return .message(ChatMessage(id: id, role: .assistant, text: message.text, attachments: message.attachments, status: message.status, createdAt: message.createdAt))
            }
            return item
        }
        let unsent = items.filter { item in
            guard case .message(let message) = item, message.role == .user, !known.contains(message.id) else { return false }
            switch message.status {
            case .failed, .uncertain: return true
            default: return false
            }
        }
        items = merged + unsent
        speakRepliesNotStreamed(in: merged, shown: local)
        if let store {
            let snapshot = items
            Task.detached(priority: .utility) { store.save(snapshot) }
        }
    }

    /// Speaks Nod's replies to a message whose turn streamed no text: those in its record
    /// after that message that were not on screen before. A streamed reply keeps the
    /// identifier it was shown under, so it counts as shown.
    private func speakRepliesNotStreamed(in merged: [ConversationItem], shown: [UUID: ChatMessage]) {
        guard let since = unspokenSince else { return }
        guard let start = merged.firstIndex(where: { if case .message(let message) = $0 { return message.id == since } else { return false } }) else { return }
        var replies: [String] = []
        for case .message(let message) in merged[merged.index(after: start)...] where message.role == .assistant && shown[message.id] == nil {
            replies.append(message.text)
        }
        guard !replies.isEmpty else { return }
        Self.trace("speaking \(replies.count) repl(ies) that arrived without streaming")
        unspokenSince = nil
        replies.forEach(speak)
    }

    // MARK: Sending

    /// Sends a message. If Nod is still busy with the previous one, the app stops speaking and
    /// following that one; whether Nod drops it is Nod's decision.
    ///
    /// A spoken message is not sent while an approval is open. Nod reads a message that
    /// arrives then as a possible answer to it, and an approval must never be given by voice.
    public func send(_ text: String, attachments: [Attachment] = [], mode: ChatMessage.InputMode = .typed) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if mode == .spoken, !pendingApprovals.isEmpty {
            log(.problem, "Not sent: an approval is waiting", detail: trimmed)
            return
        }
        leaveTurn()
        let message = ChatMessage(role: .user, text: trimmed, attachments: attachments, status: .sending, inputMode: mode, createdAt: now())
        items.append(.message(message))
        startTurn(TurnRequest(requestID: message.id, conversationID: conversationID, text: trimmed, attachments: attachments, inputMode: mode))
    }

    /// Sends a message again that failed or whose outcome is unknown. The request keeps its
    /// identifier, so a Nod that already has it can recognise the repeat.
    public func retry(messageID: UUID) {
        guard let message = message(messageID), canRetry(message) else { return }
        leaveTurn()
        updateMessage(messageID) { $0.status = .sending }
        startTurn(TurnRequest(requestID: messageID, conversationID: conversationID, text: message.text, attachments: message.attachments, inputMode: message.inputMode))
    }

    private func startTurn(_ request: TurnRequest) {
        connectTask?.cancel()
        connectTask = nil
        activeRequestID = request.requestID
        accepted = false
        replyID = nil
        speechMutedForTurn = false
        turnHadText = false
        chunker.reset()
        phase = .sending
        turnTask = Task { [weak self] in await self?.runTurn(request) }
    }

    private func isCurrent(_ request: TurnRequest) -> Bool {
        activeRequestID == request.requestID && !Task.isCancelled
    }

    private func runTurn(_ request: TurnRequest) async {
        var retry = 0
        while isCurrent(request) {
            do {
                try await ensureConnected()
                var completed = false
                for try await event in transport.send(request) {
                    guard isCurrent(request) else { return }
                    if event == .completed { completed = true }
                    handle(event)
                }
                if completed || !isCurrent(request) { return }
                throw TransportError.connectionLost
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(request) else { return }
                if case TransportError.rejected(let reason) = error {
                    endTurnInFailure(request, userStatus: .failed(reason), note: reason)
                    return
                }
                connection = .disconnected
                if accepted {
                    // Nod has the request and may be acting on it. Sending it again from here
                    // could make it act twice, so that decision is left to the user.
                    let note = "The connection was lost while Nod was working. It may have finished."
                    endTurnInFailure(request, userStatus: .uncertain(note), note: note)
                    return
                }
                retry += 1
                guard let delay = turnRetry.delay(beforeRetry: retry) else {
                    let note = "Could not reach Nod."
                    endTurnInFailure(request, userStatus: .failed(note), note: note)
                    return
                }
                connection = .waitingToRetry(attempt: retry, seconds: delay)
                do { try await sleep(delay) } catch { return }
            }
        }
    }

    /// Development aid: with `NOD_AUDIO_TRACE` set, why replies are or are not spoken is
    /// written to standard error.
    private static let tracing = ProcessInfo.processInfo.environment["NOD_AUDIO_TRACE"] != nil
    private static func trace(_ text: @autoclosure () -> String) {
        guard tracing else { return }
        FileHandle.standardError.write(Data("[talk \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(text())\n".utf8))
    }

    private func handle(_ event: NodEvent) {
        if case .textDelta(let text) = event {
            Self.trace("text \(text.count) chars")
        } else {
            Self.trace("event \(String(describing: event).prefix(80))")
        }
        switch event {
        case .accepted:
            accepted = true
            if let id = activeRequestID { updateMessage(id) { $0.status = .delivered } }
            phase = .thinking
        case .thinking:
            phase = .thinking
        case .textDelta(let text):
            turnHadText = true
            appendToReply(text)
            phase = .responding
            for sentence in chunker.append(text) { speak(sentence) }
        case .toolStarted(let id, let name, let detail):
            closeReplySegment()
            items.append(.tool(ToolActivity(id: id, name: name, detail: detail, startedAt: now())))
            phase = .usingTool(name)
        case .toolFinished(let id, let succeeded, let summary):
            updateTool(id) {
                $0.state = succeeded ? .succeeded : .failed
                $0.summary = summary
            }
            if let tool = tool(id) {
                log(.tool, tool.name, detail: summary ?? (succeeded ? tool.detail : "Failed"))
            }
            phase = .thinking
        case .approvalRequested(let approval):
            closeReplySegment()
            items.append(.approval(approval))
            log(.approvalRequested, approval.title, detail: approval.detail)
            phase = .waitingForApproval
            speak(approval.title)
        case .approvalResolved(let id, let approved):
            updateApproval(id) { approval in
                if case .decided = approval.state { return }
                approval.state = .decided(approved ? .approved : .denied)
            }
            if pendingApprovals.isEmpty, phase == .waitingForApproval { phase = .thinking }
        case .completed:
            closeReplySegment()
            noteTurnWithoutText()
            activeRequestID = nil
            turnTask = nil
            phase = .idle
            reloadTask = Task { [weak self] in await self?.reloadConversation() }
        }
    }

    private func noteTurnWithoutText() {
        guard let requestID = activeRequestID, !turnHadText, unspokenSince == nil else { return }
        Self.trace("turn ended without streamed text; its reply will be spoken from Nod's record")
        unspokenSince = requestID
    }

    private func endTurnInFailure(_ request: TurnRequest, userStatus: ChatMessage.Status, note: String) {
        updateMessage(request.requestID) { $0.status = userStatus }
        finishReply(.interrupted)
        closeOpenWork(toolState: .unknown)
        chunker.reset()
        activeRequestID = nil
        turnTask = nil
        phase = .idle
        log(.problem, note)
        start()
    }

    // MARK: Interrupting

    /// The user's Stop: playback ends at once, Nod is told to stop working, and approvals that
    /// were waiting are closed without a decision.
    public func interrupt() {
        Self.trace("interrupt")
        speech.stop()
        chunker.reset()
        guard let requestID = activeRequestID else { return }
        activeRequestID = nil
        turnTask?.cancel()
        turnTask = nil
        let transport = self.transport
        cancelTask = Task { [weak self] in
            await transport.cancel(requestID: requestID)
            await self?.reloadConversation()
        }
        updateMessage(requestID) { if $0.status == .sending { $0.status = .interrupted } }
        finishReply(.interrupted)
        closeOpenWork(toolState: .cancelled, expiringApprovals: true)
        phase = .idle
        log(.interrupted, "Stopped by you")
    }

    /// Stops speaking and following the turn in progress because the user has moved on. Nod is
    /// not told to stop: its stop ends everything it is doing in the conversation, which is
    /// too much for a new message. Open approvals stay open; they are Nod's to close.
    private func leaveTurn() {
        Self.trace("leaveTurn")
        speech.stop()
        chunker.reset()
        noteTurnWithoutText()
        guard let requestID = activeRequestID else { return }
        activeRequestID = nil
        turnTask?.cancel()
        turnTask = nil
        updateMessage(requestID) { if $0.status == .sending { $0.status = .interrupted } }
        finishReply(.delivered)
        closeOpenWork(toolState: .unknown, expiringApprovals: false)
        phase = .idle
    }

    /// Stops playback and stays silent for the rest of this reply. Nod keeps working.
    public func stopSpeaking() {
        Self.trace("stopSpeaking: the rest of this reply stays silent")
        speech.stop()
        unspokenSince = nil
        chunker.reset()
        speechMutedForTurn = true
        voiceHeldForUser = false
    }

    private func closeOpenWork(toolState: ToolActivity.State, expiringApprovals: Bool = true) {
        for index in items.indices {
            switch items[index] {
            case .tool(var tool) where tool.state == .running:
                tool.state = toolState
                items[index] = .tool(tool)
            case .approval(var approval) where approval.isPending && expiringApprovals:
                approval.state = .expired
                items[index] = .approval(approval)
            default:
                break
            }
        }
    }

    // MARK: Approvals

    public func decide(approvalID: String, _ decision: ApprovalRequest.Decision) async {
        guard let approval = approval(approvalID), approval.isPending else { return }
        updateApproval(approvalID) {
            $0.state = .submitting(decision)
            $0.problem = nil
        }
        do {
            try await transport.resolve(approvalID: approvalID, approved: decision == .approved)
            updateApproval(approvalID) { $0.state = .decided(decision) }
            log(decision == .approved ? .approved : .denied, approval.title)
            if pendingApprovals.isEmpty, phase == .waitingForApproval { phase = .thinking }
        } catch TransportError.rejected(let reason) {
            // Nod no longer has the approval open: it ran out or was answered elsewhere.
            updateApproval(approvalID) {
                guard $0.state == .submitting(decision) else { return }
                $0.state = .expired
                $0.problem = reason
            }
            if pendingApprovals.isEmpty, phase == .waitingForApproval { phase = .thinking }
            if activeRequestID == nil { await reloadConversation() }
        } catch {
            updateApproval(approvalID) {
                guard $0.state == .submitting(decision) else { return }
                $0.state = .pending
                $0.problem = "Your decision did not reach Nod. Try again."
            }
        }
    }

    // MARK: Listening

    /// Starts listening to the user. Playback stops at once, because the user is talking.
    public func startListening() {
        guard !isListening, !isDialogueActive, case .ready = speechInput.availability else { return }
        stopSpeaking()
        isListening = true
        liveTranscript = ""
        let stream = speechInput.start(languages: listeningLanguages, continuous: false)
        listenTask = Task { [weak self] in
            var heard: String?
            do {
                for try await event in stream {
                    switch event {
                    case .speechStarted: break
                    case .partial(let text): self?.liveTranscript = text
                    case .final(let text): heard = text
                    case .notice(let text): self?.speechInputNotice = text
                    }
                }
            } catch {
                self?.log(.problem, "Listening failed", detail: String(describing: error))
            }
            guard let self, !Task.isCancelled else { return }
            self.isListening = false
            self.liveTranscript = ""
            self.speechInputNotice = nil
            self.listenTask = nil
            if let heard { self.send(heard, mode: .spoken) }
        }
    }

    /// The user has finished talking: the transcript is completed and sent.
    public func finishListening() {
        guard isListening else { return }
        speechInput.finish()
    }

    /// Stops listening and throws away what was heard.
    public func cancelListening() {
        guard isListening else { return }
        listenTask?.cancel()
        listenTask = nil
        speechInput.cancel()
        isListening = false
        liveTranscript = ""
        speechInputNotice = nil
    }

    // MARK: Dialogue

    /// Starts a hands-free dialogue: the recogniser listens all the time, every utterance is
    /// sent to Nod, replies are spoken, and talking over a reply stops it.
    public func startDialogue() {
        guard !isDialogueActive, case .ready = speechInput.availability else { return }
        cancelListening()
        isDialogueActive = true
        userIsSpeaking = false
        liveTranscript = ""
        let stream = speechInput.start(languages: listeningLanguages, continuous: true)
        listenTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, self.isDialogueActive, !Task.isCancelled else { return }
                    self.handleDialogue(event)
                }
            } catch {
                self?.log(.problem, "Listening failed", detail: String(describing: error))
            }
            guard let self, !Task.isCancelled else { return }
            self.endDialogue()
        }
    }

    /// Leaves the dialogue. A reply in progress keeps going as text; the voice stops.
    public func stopDialogue() {
        guard isDialogueActive else { return }
        listenTask?.cancel()
        speechInput.cancel()
        stopSpeaking()
        endDialogue()
    }

    private func endDialogue() {
        listenTask = nil
        isDialogueActive = false
        userIsSpeaking = false
        liveTranscript = ""
        speechInputNotice = nil
    }

    private func handleDialogue(_ event: SpeechInputEvent) {
        switch event {
        case .speechStarted:
            userBeganSpeaking()
        case .partial(let text):
            // Recognisers that do not report the start of speech are covered here.
            userBeganSpeaking()
            liveTranscript = text
        case .final(let text):
            Self.trace("heard \(text.count) chars: voiceHeld=\(voiceHeldForUser)")
            userIsSpeaking = false
            liveTranscript = ""
            if voiceHeldForUser {
                voiceHeldForUser = false
                let spoken = recentlySpoken.map(\.text).joined(separator: " ")
                if EchoFilter.isEcho(heard: text, spoken: spoken) {
                    // The microphone heard the app itself, or a noise without words: the
                    // voice goes on and nothing is sent.
                    speech.resume()
                    speechInput.noteEcho()
                    if !text.isEmpty { log(.problem, "Heard its own voice", detail: text) }
                    return
                }
                stopSpeaking()
            }
            send(text, mode: .spoken)
        case .notice(let text):
            speechInputNotice = text.isEmpty ? nil : text
        }
    }

    /// Barge-in: the moment something is heard while the app speaks, the voice falls silent.
    /// Whether it stays silent is decided when the words arrive: the user's words end the
    /// reply's voice and are sent, the app's own voice coming back lets it go on. Nod keeps
    /// working either way.
    private func userBeganSpeaking() {
        guard !userIsSpeaking else { return }
        Self.trace("user began speaking: appSpeaking=\(isSpeaking)")
        userIsSpeaking = true
        guard isSpeaking else { return }
        speech.pause()
        voiceHeldForUser = true
    }

    // MARK: Speaking

    private func speak(_ text: String) {
        Self.trace("speak \(text.count) chars: speaksReplies=\(speaksReplies) dialogue=\(isDialogueActive) muted=\(speechMutedForTurn)")
        guard speaksReplies || isDialogueActive, !speechMutedForTurn else { return }
        let date = now()
        recentlySpoken.removeAll { date.timeIntervalSince($0.date) > 60 }
        for segment in LanguageSegmenter.segments(of: SpeechTextSanitizer.clean(text)) {
            recentlySpoken.append((segment.text, date))
            speech.speak(segment)
        }
    }

    // MARK: Items

    private func log(_ kind: ActivityEntry.Kind, _ title: String, detail: String? = nil) {
        activity.append(ActivityEntry(kind: kind, title: title, detail: detail, date: now()))
    }

    private func message(_ id: UUID) -> ChatMessage? {
        for case .message(let message) in items where message.id == id { return message }
        return nil
    }

    private func tool(_ id: String) -> ToolActivity? {
        for case .tool(let tool) in items where tool.id == id { return tool }
        return nil
    }

    private func approval(_ id: String) -> ApprovalRequest? {
        for case .approval(let approval) in items where approval.id == id { return approval }
        return nil
    }

    private func updateMessage(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        for index in items.indices {
            if case .message(var message) = items[index], message.id == id {
                change(&message)
                items[index] = .message(message)
                return
            }
        }
    }

    private func updateTool(_ id: String, _ change: (inout ToolActivity) -> Void) {
        for index in items.indices {
            if case .tool(var tool) = items[index], tool.id == id {
                change(&tool)
                items[index] = .tool(tool)
                return
            }
        }
    }

    private func updateApproval(_ id: String, _ change: (inout ApprovalRequest) -> Void) {
        for index in items.indices {
            if case .approval(var approval) = items[index], approval.id == id {
                change(&approval)
                items[index] = .approval(approval)
                return
            }
        }
    }

    private func appendToReply(_ text: String) {
        if let replyID {
            updateMessage(replyID) { $0.text += text }
        } else {
            let reply = ChatMessage(role: .assistant, text: text, status: .streaming, createdAt: now())
            replyID = reply.id
            items.append(.message(reply))
        }
    }

    /// Ends the reply text so far. What Nod says after a tool or an approval starts a new
    /// message below it, which keeps the conversation in the order things happened.
    private func closeReplySegment() {
        finishReply(.delivered)
        if let rest = chunker.flush() { speak(rest) }
    }

    private func finishReply(_ status: ChatMessage.Status) {
        guard let replyID else { return }
        updateMessage(replyID) {
            $0.text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.status = status
        }
        self.replyID = nil
    }
}
