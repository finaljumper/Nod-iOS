import XCTest
@testable import NodCore

final class NodTransportTests: XCTestCase {
    private var nod: FakeNod!
    private let address = URL(string: "https://nod.example.com")!

    override func setUp() {
        nod = FakeNod()
    }

    private func makeTransport(key: String? = FakeNod.key) -> NodHTTPTransport {
        NodHTTPTransport(
            client: NodClient(baseURL: address, key: key, http: nod),
            eventRetry: RetryPolicy(base: 0, factor: 1, cap: 0, maxRetries: nil),
            sleep: { _ in try await Task.sleep(for: .milliseconds(2)) }
        )
    }

    private func until(_ what: String, _ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    private func request(_ text: String, id: UUID = UUID()) -> TurnRequest {
        TurnRequest(requestID: id, conversationID: "unused", text: text, inputMode: .typed)
    }

    /// Sends a message and waits until Nod has made a turn of it.
    private func send(_ transport: NodHTTPTransport, _ text: String, id: UUID = UUID()) async -> (log: EventLog, turn: String) {
        let before = nod.calls(to: "/api/messages", method: "POST").count
        let (log, _) = EventLog.following(transport.send(request(text, id: id)))
        await until("Nod to accept the message") { await log.events.contains(.accepted) }
        XCTAssertEqual(nod.calls(to: "/api/messages", method: "POST").count, before + 1)
        let turn = nod.userMessages.first { $0["id"] as? String == id.uuidString.lowercased() }?["turnId"] as? String ?? ""
        return (log, turn)
    }

    // MARK: Connecting

    func testConnectingSendsTheKeyInAHeaderAndNowhereElse() async throws {
        let transport = makeTransport()
        try await transport.connect()
        await until("the event stream") { self.nod.eventConnections == 1 }

        let calls = nod.calls
        XCTAssertEqual(calls.prefix(2).map(\.path), ["/api/session", "/api/state"])
        XCTAssertTrue(calls.allSatisfy { $0.authorization == "Bearer \(FakeNod.key)" })
        XCTAssertTrue(calls.allSatisfy { !($0.query ?? "").contains(FakeNod.key) && !$0.path.contains(FakeNod.key) })
        XCTAssertEqual(nod.calls(to: "/api/events").first?.query, "account=owner-1")
        await transport.disconnect()
    }

    func testAKeyNodDoesNotAcceptIsARefusalNotALostConnection() async {
        let transport = makeTransport(key: "wrong")
        do {
            try await transport.connect()
            XCTFail("connected with a wrong key")
        } catch {
            XCTAssertEqual(error as? TransportError, .rejected("Nod did not accept the authentication key."))
        }
    }

    func testAServerThatIsDownIsALostConnection() async {
        nod.answerOnce("/api/session", status: 502, body: "<html>Bad gateway</html>")
        do {
            try await makeTransport().connect()
            XCTFail("connected")
        } catch {
            XCTAssertEqual(error as? TransportError, .connectionLost)
        }
    }

    // MARK: A request and its reply

    func testAMessageIsPostedWithItsIDAndTheReplyIsStreamed() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let id = UUID()
        let (log, turn) = await send(transport, "What is on my calendar?", id: id)

        let body = try XCTUnwrap(nod.calls(to: "/api/messages", method: "POST").first?.body)
        XCTAssertEqual(body["text"] as? String, "What is on my calendar?")
        XCTAssertEqual(body["threadId"] as? String, nod.threadID)
        XCTAssertEqual(body["clientMessageId"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(body.count, 3, "nothing is sent that the request does not need")

        nod.delta(turn: turn, "You have two ")
        nod.delta(turn: turn, "things today.")
        nod.finish(turn: turn, reply: "You have two things today.")
        await until("the reply to end") { await log.finished }

        let events = await log.events
        XCTAssertEqual(events, [.accepted, .textDelta("You have two "), .textDelta("things today."), .completed])
        let failure = await log.failure
        XCTAssertNil(failure)
        await transport.disconnect()
    }

    func testTextOfOtherTurnsAndConversationsIsNotMixedIn() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, turn) = await send(transport, "Hello")

        nod.delta(turn: UUID().uuidString.lowercased(), "A scheduled task reports. ")
        nod.delta(turn: turn, "Not this conversation. ", thread: UUID().uuidString.lowercased())
        nod.delta(turn: turn, "Hi.")
        nod.finish(turn: turn, reply: "Hi.")
        await until("the reply to end") { await log.finished }

        let text = await log.text
        XCTAssertEqual(text, "Hi.")
        await transport.disconnect()
    }

    func testSeveralMessagesInOneTurnAreSeparated() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, turn) = await send(transport, "Hello")

        nod.delta(turn: turn, "Let me look.", stream: "a")
        nod.delta(turn: turn, "Here it is.", stream: "b")
        nod.addMessage(role: "assistant", text: "Let me look.", turn: turn)
        nod.finish(turn: turn, reply: "Here it is.")
        await until("the reply to end") { await log.finished }

        let text = await log.text
        XCTAssertEqual(text, "Let me look.\n\nHere it is.")
        await transport.disconnect()
    }

    func testAReplyThatWasNeverStreamedIsTakenFromTheState() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, turn) = await send(transport, "Hello")

        nod.finish(turn: turn, reply: "Hi there.")
        await until("the reply to end") { await log.finished }

        let events = await log.events
        XCTAssertEqual(events, [.accepted, .textDelta("Hi there."), .completed])
        await transport.disconnect()
    }

    func testAFailedTurnSaysSo() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, turn) = await send(transport, "Hello")

        nod.setTurn(turn, status: "failed", error: "The model is not reachable")
        nod.refresh()
        await until("the reply to end") { await log.finished }

        let text = await log.text
        XCTAssertEqual(text, "Nod could not finish this: The model is not reachable.")
        await transport.disconnect()
    }

    func testTheSameRequestSentAgainIsNotActedOnTwice() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let id = UUID()
        let (first, turn) = await send(transport, "Send the report", id: id)
        nod.finish(turn: turn, reply: "Done.")
        await until("the first reply to end") { await first.finished }

        // The app does not know whether the first attempt arrived and sends it again.
        let (second, sameTurn) = await send(transport, "Send the report", id: id)
        await until("the second reply to end") { await second.finished }

        XCTAssertEqual(nod.userMessages.count, 1, "Nod holds the message once")
        XCTAssertEqual(sameTurn, turn)
        let events = await second.events
        XCTAssertEqual(events, [.accepted, .textDelta("Done."), .completed])
        await transport.disconnect()
    }

    func testARefusedMessageIsReportedWithNodsReason() async throws {
        let transport = makeTransport()
        try await transport.connect()
        nod.answerOnce("/api/messages", status: 503, body: #"{"error":"Configure an agent provider before starting a conversation."}"#)
        let (log, _) = EventLog.following(transport.send(request("Hello")))
        await until("the refusal") { await log.finished }

        let failure = await log.failure
        XCTAssertEqual(failure as? TransportError, .rejected("Configure an agent provider before starting a conversation."))
        let events = await log.events
        XCTAssertEqual(events, [], "the message was not accepted")
        await transport.disconnect()
    }

    // MARK: Photos and files

    private func photo(_ name: String = "Photo 1.jpg") -> Attachment {
        Attachment(name: name, mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]))
    }

    func testAttachmentsAreStoredFirstAndThenNamedInTheMessage() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let request = TurnRequest(requestID: UUID(), conversationID: "unused", text: "", attachments: [photo(), Attachment(name: "notes \"final\".pdf", mimeType: "application/pdf", data: Data("%PDF".utf8))], inputMode: .typed)
        let (log, _) = EventLog.following(transport.send(request))
        await until("Nod to accept the message") { await log.events.contains(.accepted) }

        XCTAssertEqual(nod.uploads.map { $0["name"] as? String }, ["Photo 1.jpg", "notes 'final'.pdf"])
        XCTAssertEqual(nod.uploads.map { $0["mimeType"] as? String }, ["image/jpeg", "application/pdf"])
        XCTAssertEqual(nod.uploads.first?["size"] as? Int, 8, "the bytes arrive unchanged")
        let body = try XCTUnwrap(nod.calls(to: "/api/messages", method: "POST").first?.body)
        XCTAssertEqual(body["attachmentIds"] as? [String], nod.uploads.compactMap { $0["id"] as? String })
        XCTAssertEqual(body["text"] as? String, "", "a message can be attachments alone")
        XCTAssertTrue(nod.calls(to: "/api/uploads", method: "POST").allSatisfy { $0.authorization == "Bearer \(FakeNod.key)" })
        await transport.disconnect()
    }

    func testTryingAgainDoesNotStoreTheSameFileTwice() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let request = TurnRequest(requestID: UUID(), conversationID: "unused", text: "Look at this", attachments: [photo()], inputMode: .typed)
        // The file arrives, the message does not.
        nod.answerOnce("/api/messages", status: 502, body: "<html>Bad gateway</html>")
        let (first, _) = EventLog.following(transport.send(request))
        await until("the first attempt to fail") { await first.finished }
        let failure = await first.failure
        XCTAssertEqual(failure as? TransportError, .connectionLost)

        let (second, _) = EventLog.following(transport.send(request))
        await until("Nod to accept the message") { await second.events.contains(.accepted) }
        XCTAssertEqual(nod.uploads.count, 1)
        XCTAssertEqual(nod.userMessages.count, 1)
        await transport.disconnect()
    }

    func testAMessageWithoutAttachmentsDoesNotMentionThem() async throws {
        let transport = makeTransport()
        try await transport.connect()
        _ = await send(transport, "Hello")
        let body = try XCTUnwrap(nod.calls(to: "/api/messages", method: "POST").first?.body)
        XCTAssertNil(body["attachmentIds"])
        await transport.disconnect()
    }

    func testStoredAttachmentsComeBackWithTheirNames() throws {
        let json = #"{"threadId":"t","messages":[{"id":"7b1f2c3a-0000-4000-8000-000000000001","role":"user","text":"","turnId":null,"createdAt":"2026-11-20T10:00:00.000Z","attachments":[{"id":"7b1f2c3a-0000-4000-8000-0000000000aa","name":"Photo 1.jpg","mimeType":"image/jpeg","size":2048,"url":"/api/artifacts/x"}]}],"turns":[]}"#
        let items = NodConversation.items(from: try JSONDecoder().decode(NodAPI.State.self, from: Data(json.utf8)))
        guard case .message(let message) = items.first else { return XCTFail("no message") }
        XCTAssertEqual(message.text, "")
        XCTAssertEqual(message.attachments.map(\.name), ["Photo 1.jpg"])
        XCTAssertEqual(message.attachments.first?.isImage, true)
        XCTAssertEqual(message.attachments.first?.byteCount, 2048)
        XCTAssertNil(message.attachments.first?.data)
    }

    // MARK: Events that go missing

    func testAfterTheEventsDropTheStateSaysWhatWasMissed() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, turn) = await send(transport, "Hello")
        nod.delta(turn: turn, "The first half")
        await until("the first half") { await log.text == "The first half" }

        // The line drops; Nod finishes meanwhile; the app comes back and reads the state.
        nod.refuseEvents(true)
        nod.dropEvents()
        nod.addMessage(role: "assistant", text: "The first half and the second.", turn: turn)
        nod.setTurn(turn, status: "succeeded")
        try await Task.sleep(for: .milliseconds(3))
        nod.refuseEvents(false)
        await until("the reply to end") { await log.finished }

        let text = await log.text
        XCTAssertEqual(text, "The first half and the second.")
        let failure = await log.failure
        XCTAssertNil(failure)
        await transport.disconnect()
    }

    func testEventsThatStayDownEndTheRequestAsLost() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, _) = await send(transport, "Hello")

        nod.refuseEvents(true)
        nod.dropEvents()
        await until("the request to be given up") { await log.finished }

        let failure = await log.failure
        XCTAssertEqual(failure as? TransportError, .connectionLost)
        await transport.disconnect()
    }

    // MARK: Approvals

    private func approvalFields(_ id: String, state: String = "pending") -> [String: Any] {
        ["id": id, "state": state, "title": "Send email to Alex", "app": "Gmail", "slug": "gmail", "fields": [["label": "To", "value": "alex@example.com"]], "body": "See you Friday."]
    }

    func testAnApprovalIsAnnouncedAnsweredAndItsActionFollowed() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, turn) = await send(transport, "Email Alex about Friday")

        let approvalID = UUID().uuidString.lowercased()
        let question = nod.addMessage(role: "assistant", text: "Shall I send this?", turn: turn, approval: approvalFields(approvalID))
        nod.setTurn(turn, status: "waiting")
        nod.refresh()
        await until("the approval") { await log.events.contains { if case .approvalRequested = $0 { return true } else { return false } } }

        let announced = await log.events.compactMap { event -> ApprovalRequest? in
            if case .approvalRequested(let approval) = event { return approval } else { return nil }
        }
        XCTAssertEqual(announced.map(\.id), [approvalID])
        XCTAssertEqual(announced.first?.title, "Send email to Alex")
        XCTAssertEqual(announced.first?.detail, "Gmail\nTo: alex@example.com\nSee you Friday.")
        let waiting = await log.finished
        XCTAssertFalse(waiting, "a turn that waits for an approval is not over")

        try await transport.resolve(approvalID: approvalID, approved: true)
        let answer = try XCTUnwrap(nod.calls(to: "/api/messages", method: "POST").last?.body)
        XCTAssertEqual(answer["replyToMessageId"] as? String, question)
        XCTAssertEqual((answer["approvalAnswer"] as? [String: Any])?["approvalId"] as? String, approvalID)
        XCTAssertEqual((answer["approvalAnswer"] as? [String: Any])?["approved"] as? Bool, true)
        XCTAssertEqual(answer["text"] as? String, "Approve", "Nod refuses an approval answer without text")

        // Nod carries the action out in a turn of its own; its reply belongs to the request.
        let action = try XCTUnwrap(nod.userMessages.last?["turnId"] as? String)
        nod.setTurn(turn, status: "succeeded")
        nod.setApproval(approvalID, state: "done")
        nod.delta(turn: action, "Sent.")
        nod.finish(turn: action, reply: "Sent.")
        await until("the reply to end") { await log.finished }

        let events = await log.events
        XCTAssertEqual(events.first { if case .textDelta = $0 { return true } else { return false } }, .textDelta("Shall I send this?"), "what Nod wrote before asking comes before the approval")
        XCTAssertEqual(Array(events.suffix(2)), [.textDelta("Sent."), .completed])
        XCTAssertFalse(events.contains { if case .approvalResolved = $0 { return true } else { return false } }, "the app's own answer is not reported back to it")
        await transport.disconnect()
    }

    func testAnApprovalAnsweredElsewhereIsReported() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, turn) = await send(transport, "Email Alex about Friday")
        let approvalID = UUID().uuidString.lowercased()
        nod.addMessage(role: "assistant", text: "Shall I send this?", turn: turn, approval: approvalFields(approvalID))
        nod.setTurn(turn, status: "waiting")
        nod.refresh()
        await until("the approval") { await log.events.count == 3 }

        // Declined in the web app.
        nod.setApproval(approvalID, state: "declined")
        nod.setTurn(turn, status: "succeeded")
        nod.refresh()
        await until("the reply to end") { await log.finished }

        let events = await log.events
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(Array(events.suffix(2)), [.approvalResolved(id: approvalID, approved: false), .completed])
        await transport.disconnect()
    }

    func testAnApprovalThatIsOverCannotBeAnswered() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let approvalID = UUID().uuidString.lowercased()
        nod.addMessage(role: "assistant", text: "Shall I send this?", approval: approvalFields(approvalID, state: "expired"))

        do {
            try await transport.resolve(approvalID: approvalID, approved: true)
            XCTFail("an expired approval was answered")
        } catch {
            XCTAssertEqual(error as? TransportError, .rejected("This approval is no longer waiting for an answer."))
        }
        XCTAssertTrue(nod.calls(to: "/api/messages", method: "POST").isEmpty, "nothing was sent to Nod")
        await transport.disconnect()
    }

    // MARK: Stopping

    func testStoppingAsksNodToStopItsWork() async throws {
        let transport = makeTransport()
        try await transport.connect()
        await transport.cancel(requestID: UUID())
        XCTAssertEqual(nod.calls(to: "/api/thread/stop", method: "POST").count, 1)
        await transport.disconnect()
    }

    // MARK: The stored conversation

    func testTheStoredConversationIsMappedInOrder() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let user = nod.addMessage(role: "user", text: "Email Alex about Friday")
        nod.addMessage(role: "assistant", text: "Shall I send this?", approval: approvalFields("a-1", state: "declined"))
        nod.addMessage(role: "assistant", text: "   ")

        // Past the short time in which the state read while connecting counts as fresh.
        try await Task.sleep(for: .seconds(2.1))
        let items = try await transport.loadConversation() ?? []
        XCTAssertEqual(items.count, 3, "a message without text or attachments is left out")
        guard case .message(let first) = items[0], case .message(let second) = items[1], case .approval(let approval) = items[2] else {
            return XCTFail("unexpected items \(items)")
        }
        XCTAssertEqual(first.id.uuidString.lowercased(), user)
        XCTAssertEqual(first.role, .user)
        XCTAssertEqual(first.status, .delivered)
        XCTAssertEqual(first.createdAt.timeIntervalSince1970, 1_795_168_800, accuracy: 1)
        XCTAssertEqual(second.role, .assistant)
        XCTAssertEqual(approval.state, .decided(.denied))
        await transport.disconnect()
    }

    func testApprovalStatesAreMapped() {
        func state(_ name: String) -> ApprovalRequest.State {
            NodConversation.approval(NodAPI.Approval(id: "a", state: name, title: "t")).state
        }
        XCTAssertEqual(state("pending"), .pending)
        XCTAssertEqual(state("working"), .submitting(.approved))
        XCTAssertEqual(state("done"), .decided(.approved))
        XCTAssertEqual(state("declined"), .decided(.denied))
        XCTAssertEqual(state("expired"), .expired)
        XCTAssertEqual(state("something new"), .expired, "an unknown state is never shown as open")
        let uncertain = NodConversation.approval(NodAPI.Approval(id: "a", state: "uncertain", title: "t"))
        XCTAssertNotNil(uncertain.problem)
    }

    func testAStateWithEntriesInAnUnknownShapeIsStillRead() throws {
        let json = #"{"threadId":"t","messages":[{"id":"m1","role":"user","text":"hi","turnId":null,"createdAt":"2026-11-20T10:00:00.000Z","attachments":[]},{"unexpected":true},{"id":"m2","role":"assistant","text":"hello","somethingNew":{"a":1}}],"turns":[{"id":"u1","status":"running","source":"user"},17]}"#
        let state = try JSONDecoder().decode(NodAPI.State.self, from: Data(json.utf8))
        XCTAssertEqual(state.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(state.turns.map(\.id), ["u1"])
        XCTAssertEqual(state.activity, [])
    }

    // MARK: Event stream and errors

    func testEventStreamFramesAreParsed() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(": keepalive"))
        XCTAssertNil(parser.feed(""), "a comment alone is not a frame")
        XCTAssertNil(parser.feed(#"data: {"type":"refresh"}"#), "a frame is complete only at the empty line")
        XCTAssertEqual(parser.feed(""), #"{"type":"refresh"}"#)
        XCTAssertNil(parser.feed("event: something"))
        XCTAssertNil(parser.feed("data:first"))
        XCTAssertNil(parser.feed("data: second"))
        XCTAssertEqual(parser.feed(""), "first\nsecond")
    }

    func testEventsAreDecoded() {
        XCTAssertEqual(NodAPI.Event(payload: #"{"type":"refresh"}"#), .refresh)
        XCTAssertEqual(
            NodAPI.Event(payload: #"{"type":"delta","threadId":"t","turnId":"u","text":"hi","streamId":"s","done":false}"#),
            .delta(NodAPI.Delta(threadId: "t", turnId: "u", text: "hi", streamId: "s", done: false))
        )
        XCTAssertEqual(
            NodAPI.Event(payload: #"{"type":"activity","items":[{"turnId":"u","taskId":null,"title":null,"step":"Reading mail","site":null,"since":"x","doing":"tool","quietSince":"x","tool":"gmail_search"}]}"#),
            .activity([NodAPI.Activity(turnId: "u", step: "Reading mail", doing: "tool", tool: "gmail_search")])
        )
        XCTAssertEqual(NodAPI.Event(payload: #"{"type":"working"}"#), .unknown)
        XCTAssertEqual(NodAPI.Event(payload: "not json"), .unknown)
    }

    func testToolUseIsReportedFromNodsActivity() async throws {
        let transport = makeTransport()
        try await transport.connect()
        let (log, turn) = await send(transport, "Any mail from Alex?")

        nod.emit(["type": "activity", "items": [["turnId": turn, "doing": "tool", "tool": "gmail_search", "step": "Reading mail"]]])
        nod.emit(["type": "activity", "items": [["turnId": turn, "doing": "model"]]])
        nod.finish(turn: turn, reply: "No.")
        await until("the reply to end") { await log.finished }

        let events = await log.events
        XCTAssertEqual(events, [
            .accepted,
            .toolStarted(id: "\(turn)#1", name: "Gmail search", detail: "Reading mail"),
            .toolFinished(id: "\(turn)#1", succeeded: true, summary: nil),
            .thinking,
            .textDelta("No."),
            .completed,
        ])
        await transport.disconnect()
    }

    func testErrorAnswersAreToldApart() {
        func failure(_ status: Int, _ body: String) -> NodError { NodClient.failure(status: status, body: Data(body.utf8)) }
        XCTAssertEqual(failure(401, #"{"error":"Enter your server authentication token."}"#), .unauthorized("Enter your server authentication token."))
        XCTAssertEqual(failure(403, #"{"error":"This host is not permitted."}"#), .forbidden("This host is not permitted."))
        XCTAssertEqual(failure(403, "<html>Cloudflare</html>"), .notNod(403), "a refusal that is not Nod's own")
        XCTAssertEqual(failure(302, ""), .redirected)
        XCTAssertEqual(failure(409, #"{"error":"Gone.","code":"question_unavailable"}"#), .conflict("Gone.", code: "question_unavailable"))
        XCTAssertEqual(failure(502, "<html>Bad gateway</html>"), .server(502))
        XCTAssertTrue(failure(502, "").isTransient)
        XCTAssertFalse(failure(401, #"{"error":"x"}"#).isTransient)
    }

    // MARK: Setup checks

    func testAnAddressIsNodWhenItAsksForTheKey() async {
        let isNod = await NodConnectionCheck.address(address, http: nod)
        XCTAssertNoThrow(try isNod.get())
        XCTAssertNil(nod.calls.first?.authorization, "the address is checked without a key")

        nod.answerOnce("/api/health", status: 302, body: "", headers: ["Location": "https://login.example.com"])
        let behindSignIn = await NodConnectionCheck.address(address, http: nod)
        XCTAssertEqual(behindSignIn.failure, .redirected)

        nod.answerOnce("/api/health", status: 403, body: #"{"error":"This host is not permitted."}"#)
        let wrongHost = await NodConnectionCheck.address(address, http: nod)
        XCTAssertEqual(wrongHost.failure, .forbidden("This host is not permitted."))

        nod.answerOnce("/api/health", status: 200, body: "<html>A web site</html>")
        let somethingElse = await NodConnectionCheck.address(address, http: nod)
        XCTAssertEqual(somethingElse.failure, .notNod(200))
    }

    func testAKeyIsCheckedAgainstNod() async {
        let accepted = await NodConnectionCheck.key(FakeNod.key, at: address, http: nod)
        XCTAssertEqual(try? accepted.get(), "Ren")
        let refused = await NodConnectionCheck.key("wrong", at: address, http: nod)
        XCTAssertEqual(refused.failure, .unauthorized("Enter your server authentication token."))
    }

    func testTheFinalCheckPassesEveryPartAndSendsNothingToTheAgent() async {
        for part in NodConnectionCheck.Part.allCases {
            let result = await NodConnectionCheck.verify(part, key: FakeNod.key, at: address, http: nod)
            XCTAssertNil(result.failure, "\(part)")
        }
        XCTAssertTrue(nod.calls.allSatisfy { $0.method == "GET" }, "the check only reads")
        XCTAssertFalse(nod.calls(to: "/api/events").isEmpty)
    }

    func testTheFinalCheckNamesWhatDoesNotWork() async {
        let wrongKey = await NodConnectionCheck.verify(.key, key: "wrong", at: address, http: nod)
        XCTAssertEqual(wrongKey.failure, .unauthorized("Enter your server authentication token."))

        nod.answerOnce("/api/state", status: 502, body: "<html>Bad gateway</html>")
        let noConversation = await NodConnectionCheck.verify(.conversation, key: FakeNod.key, at: address, http: nod)
        XCTAssertEqual(noConversation.failure, .server(502))

        nod.refuseEvents(true)
        let noStream = await NodConnectionCheck.verify(.liveUpdates, key: FakeNod.key, at: address, http: nod)
        guard case .unreachable = noStream.failure else { return XCTFail("\(String(describing: noStream.failure))") }
        nod.refuseEvents(false)

        // The stream opens but nothing comes through, as behind a proxy that buffers.
        nod.silenceEvents(true)
        let silent = await NodConnectionCheck.verify(.liveUpdates, key: FakeNod.key, at: address, http: nod, patience: .milliseconds(200))
        guard case .unreachable(let reason) = silent.failure else { return XCTFail("\(String(describing: silent.failure))") }
        XCTAssertTrue(reason.contains("live updates"))
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure } else { return nil }
    }
}
