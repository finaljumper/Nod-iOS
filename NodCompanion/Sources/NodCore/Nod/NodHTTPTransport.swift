import Foundation

/// The connection to a real Nod server over its HTTP interface.
///
/// Nod has no "one request, one stream of answers" call. A message is posted, its reply
/// arrives on an event stream that is shared by everything Nod does, and the stored state says
/// when a turn is over. This type turns that into the per-request stream the conversation
/// logic expects: it follows the turn a message started, and the turn that carries out an
/// approval given here.
public actor NodHTTPTransport: NodTransport {
    private let client: NodClient
    private let eventRetry: RetryPolicy
    private let sleep: @Sendable (Double) async throws -> Void

    private var accountID: String?
    private var threadID: String?
    private var latest: NodAPI.State?
    private var latestAt = Date.distantPast
    private var eventTask: Task<Void, Never>?
    private var follower: Follower?
    private var watchers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// What has been stored on Nod for a request that is not accepted yet, so that trying
    /// again does not upload the same files twice.
    private var uploads: [UUID: [String]] = [:]

    /// The request whose reply is being followed.
    private struct Follower {
        let requestID: UUID
        let output: AsyncThrowingStream<NodEvent, any Error>.Continuation
        /// The turns whose output belongs to this request.
        var turns: Set<String> = []
        /// Reply text that arrived before Nod said which turn the request became.
        var early: [NodAPI.Delta] = []
        /// What has been passed on of each turn's reply.
        var passedOn: [String: String] = [:]
        var lastStream: String?
        var toolKey: String?
        var toolID: String?
        var toolCount = 0
        var announced: Set<String> = []
        var settled: Set<String> = []
        /// Above zero while an approval answer is on its way: the turn must not be taken as
        /// over before Nod has said which turn carries the action out.
        var holds = 0
    }

    public init(
        client: NodClient,
        eventRetry: RetryPolicy = RetryPolicy(maxRetries: nil),
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.client = client
        self.eventRetry = eventRetry
        self.sleep = sleep
    }

    // MARK: NodTransport

    public func connect() async throws {
        do {
            let session = try await client.session()
            guard let user = session.user else {
                throw NodError.refused(0, "Nod has not been set up yet. Finish its setup in the web app first.")
            }
            accountID = user.id
            _ = try await readState()
            startEvents()
        } catch {
            throw Self.transportError(error)
        }
    }

    public func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        follower?.output.finish(throwing: TransportError.connectionLost)
        follower = nil
        for watcher in watchers.values { watcher.finish() }
        watchers = [:]
    }

    public nonisolated func send(_ request: TurnRequest) -> AsyncThrowingStream<NodEvent, any Error> {
        AsyncThrowingStream { output in
            let task = Task { await self.begin(request, output) }
            output.onTermination = { _ in
                task.cancel()
                Task { await self.release(request.requestID) }
            }
        }
    }

    /// Stops the agent's work in the conversation. Nod has no way to stop one request only.
    public func cancel(requestID: UUID) async {
        try? await client.stopThread()
    }

    public func resolve(approvalID: String, approved: Bool) async throws {
        let over = TransportError.rejected("This approval is no longer waiting for an answer.")
        do {
            // The approval may have been answered elsewhere or have run out since it was shown.
            let state = try await readState()
            guard let threadID,
                  let message = state.messages.first(where: { $0.approval?.id == approvalID }),
                  message.approval?.state == "pending"
            else { throw over }

            let holder = follower?.requestID
            if holder != nil { follower?.holds += 1 }
            defer { if let holder, follower?.requestID == holder { follower?.holds -= 1 } }
            let submitted = try await client.answerApproval(
                threadID: threadID,
                messageID: message.id,
                approvalID: approvalID,
                approved: approved,
                text: approved ? "Approve" : "Decline",
                clientMessageID: UUID()
            )
            if let holder, follower?.requestID == holder {
                follower?.settled.insert(approvalID)
                if let turn = submitted.turnId?.lowercased() { follow(turn) }
            }
        } catch let error as TransportError {
            throw error
        } catch NodError.conflict {
            throw over
        } catch {
            throw Self.transportError(error)
        }
        try? await reconcile()
    }

    public func loadConversation() async throws -> [ConversationItem]? {
        do {
            // An event has usually just fetched the state; that copy is fresh enough.
            if let latest, Date().timeIntervalSince(latestAt) < 2 { return NodConversation.items(from: latest) }
            return NodConversation.items(from: try await readState())
        } catch {
            throw Self.transportError(error)
        }
    }

    public nonisolated func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.watch(id, continuation) }
            continuation.onTermination = { _ in Task { await self.unwatch(id) } }
        }
    }

    // MARK: Following a request

    private func begin(_ request: TurnRequest, _ output: AsyncThrowingStream<NodEvent, any Error>.Continuation) async {
        follower?.output.finish()
        follower = Follower(requestID: request.requestID, output: output)
        do {
            guard let threadID else { throw TransportError.notConnected }
            var stored = uploads[request.requestID] ?? []
            for attachment in request.attachments.dropFirst(stored.count) {
                guard let data = attachment.data else { throw NodError.refused(0, "\(attachment.name) is no longer on this device.") }
                let answer = try await client.upload(name: attachment.name, mimeType: attachment.mimeType, data: data)
                guard let id = answer.id else { throw NodError.notNod(200) }
                stored.append(id)
                uploads[request.requestID] = stored
            }
            let submitted = try await client.sendMessage(text: request.text, threadID: threadID, clientMessageID: request.requestID, attachmentIDs: stored)
            uploads[request.requestID] = nil
            guard follower?.requestID == request.requestID else { return }
            output.yield(.accepted)
            guard let turn = submitted.turnId?.lowercased() else {
                // Nod took the message without starting a turn for it.
                finish(.completed)
                return
            }
            follow(turn)
        } catch {
            if follower?.requestID == request.requestID { follower = nil }
            // After a refusal the stored files may be the reason; the next attempt starts over.
            if let refusal = error as? NodError, !refusal.isTransient { uploads[request.requestID] = nil }
            if !(error is CancellationError) { output.finish(throwing: Self.transportError(error)) }
            return
        }
        // The turn may already be over, for a repeated request or a very short reply.
        try? await reconcile()
    }

    private func release(_ requestID: UUID) {
        if follower?.requestID == requestID { follower = nil }
    }

    /// Adds a turn to the ones whose output belongs to the request being followed.
    private func follow(_ turn: String) {
        guard var current = follower else { return }
        current.turns.insert(turn)
        let early = current.early
        current.early = []
        for delta in early where delta.turnId.lowercased() == turn { pass(delta, &current) }
        follower = current
    }

    private func pass(_ delta: NodAPI.Delta, _ current: inout Follower) {
        guard let piece = delta.text, !piece.isEmpty else { return }
        let turn = delta.turnId.lowercased()
        let stream = delta.streamId ?? "turn:\(turn)"
        var text = piece
        // A turn can write several messages, each as a stream of its own.
        if let last = current.lastStream, last != stream, !(current.passedOn[turn] ?? "").isEmpty { text = "\n\n" + piece }
        current.lastStream = stream
        current.passedOn[turn, default: ""] += text
        current.output.yield(.textDelta(text))
    }

    private func finish(_ last: NodEvent) {
        guard let current = follower else { return }
        if let tool = current.toolID { current.output.yield(.toolFinished(id: tool, succeeded: true, summary: nil)) }
        current.output.yield(last)
        current.output.finish()
        follower = nil
    }

    // MARK: Events

    private func startEvents() {
        eventTask?.cancel()
        guard let accountID else { return }
        eventTask = Task { [weak self, client, eventRetry, sleep] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    for try await event in client.events(account: accountID) {
                        failures = 0
                        await self?.handle(event)
                    }
                } catch is CancellationError {
                    return
                } catch let error as NodError where !error.isTransient {
                    await self?.eventsRefused(error)
                    return
                } catch {}
                if Task.isCancelled { return }
                failures += 1
                await self?.eventsDropped(failures: failures)
                do { try await sleep(eventRetry.delay(beforeRetry: failures) ?? eventRetry.cap) } catch { return }
            }
        }
    }

    /// Missed events cannot be asked for again. Nod sends "refresh" when the stream opens, and
    /// the state read then says what happened meanwhile; this gives up on the request being
    /// followed only when the stream stays down.
    private func eventsDropped(failures: Int) {
        guard failures >= 3, let current = follower else { return }
        current.output.finish(throwing: TransportError.connectionLost)
        follower = nil
    }

    private func eventsRefused(_ error: NodError) {
        follower?.output.finish(throwing: TransportError.rejected(error.message))
        follower = nil
    }

    private func handle(_ event: NodAPI.Event) async {
        switch event {
        case .refresh:
            try? await reconcile()
            for watcher in watchers.values { watcher.yield() }
        case .activity(let items):
            apply(items)
        case .delta(let delta):
            guard delta.threadId.lowercased() == threadID, var current = follower else { return }
            if current.turns.isEmpty {
                if current.early.count < 2000 { current.early.append(delta) }
            } else if current.turns.contains(delta.turnId.lowercased()) {
                pass(delta, &current)
            }
            follower = current
        case .unknown:
            break
        }
    }

    private func apply(_ activity: [NodAPI.Activity]) {
        guard var current = follower, !current.turns.isEmpty else { return }
        let item = activity.first { current.turns.contains($0.turnId.lowercased()) && $0.background != true }
        let tool = item.flatMap { $0.doing == "tool" ? $0 : nil }
        let key = tool.map { "\($0.tool ?? "")|\($0.step ?? "")|\($0.site ?? "")" }
        guard key != current.toolKey else { return }
        if let open = current.toolID {
            current.output.yield(.toolFinished(id: open, succeeded: true, summary: nil))
            current.toolID = nil
        }
        if let tool {
            current.toolCount += 1
            let id = "\(tool.turnId.lowercased())#\(current.toolCount)"
            current.toolID = id
            current.output.yield(.toolStarted(id: id, name: Self.toolName(tool), detail: tool.step ?? tool.site))
        } else if current.toolKey != nil {
            current.output.yield(.thinking)
        }
        current.toolKey = key
        follower = current
    }

    static func toolName(_ activity: NodAPI.Activity) -> String {
        let raw = activity.tool ?? activity.title ?? "a tool"
        let words = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: State

    @discardableResult
    private func readState() async throws -> NodAPI.State {
        let state = try await client.state()
        latest = state
        latestAt = Date()
        let thread = state.threadId.lowercased()
        if let threadID, threadID != thread, let current = follower {
            // The conversation was reset on Nod; what was being followed is gone.
            current.output.finish(throwing: TransportError.rejected("The conversation was reset on Nod."))
            follower = nil
        }
        threadID = thread
        return state
    }

    /// Reads the state and settles what the request being followed is waiting for.
    private func reconcile() async throws {
        let state = try await readState()
        guard var current = follower, !current.turns.isEmpty, current.holds == 0 else { return }

        var waitsForApproval = false
        for message in state.messages {
            guard let turn = message.turnId?.lowercased(), current.turns.contains(turn), let approval = message.approval else { continue }
            if approval.state == "pending" {
                waitsForApproval = true
                if !current.announced.contains(approval.id) {
                    current.announced.insert(approval.id)
                    // What Nod wrote before asking comes before the question it belongs to.
                    catchUp(turn, nil, state, &current)
                    current.output.yield(.approvalRequested(NodConversation.approval(approval)))
                }
            } else if current.announced.contains(approval.id), !current.settled.contains(approval.id) {
                // Answered somewhere else, or run out.
                current.settled.insert(approval.id)
                current.output.yield(.approvalResolved(id: approval.id, approved: ["working", "done", "uncertain"].contains(approval.state)))
            }
        }

        let turns = state.turns.filter { current.turns.contains($0.id.lowercased()) }
        // A turn that waits without an open approval has asked the user something: for this
        // app that is the end of the reply.
        let over = turns.count == current.turns.count && turns.allSatisfy { $0.isOver || ($0.status == "waiting" && !waitsForApproval) }
        guard over else {
            follower = current
            return
        }

        for turn in turns { catchUp(turn.id.lowercased(), turn, state, &current) }
        follower = current
        finish(.completed)
    }

    /// Passes on text that Nod has stored for a turn but that was never streamed here, for
    /// instance while the events were down.
    private func catchUp(_ id: String, _ turn: NodAPI.Turn?, _ state: NodAPI.State, _ current: inout Follower) {
        let stored = NodConversation.reply(of: id, in: state)
        let passed = (current.passedOn[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var missing = ""
        if passed.isEmpty {
            missing = stored
            if stored.isEmpty, let turn, turn.status == "failed" {
                missing = "Nod could not finish this: \(turn.error ?? "no reason was given")."
            }
        } else if stored.hasPrefix(passed), stored.count > passed.count {
            missing = String(stored.dropFirst(passed.count))
        }
        guard !missing.isEmpty else { return }
        current.passedOn[id, default: ""] += missing
        current.output.yield(.textDelta(missing))
    }

    private func watch(_ id: UUID, _ continuation: AsyncStream<Void>.Continuation) {
        watchers[id] = continuation
    }

    private func unwatch(_ id: UUID) {
        watchers[id] = nil
    }

    /// Refusals are not tried again on their own; trouble on the way is.
    static func transportError(_ error: any Error) -> any Error {
        if error is TransportError || error is CancellationError { return error }
        guard let error = error as? NodError else { return TransportError.connectionLost }
        return error.isTransient ? TransportError.connectionLost : TransportError.rejected(error.message)
    }
}
