import XCTest
@testable import NodCore

/// The conversation logic together with the Nod transport, against the stand-in server.
@MainActor
final class NodConversationTests: XCTestCase {
    private var nod: FakeNod!
    private var speech: RecordingSpeechOutput!

    private func makeModel(key: String = FakeNod.key, store: ConversationStore? = nil) -> ConversationModel {
        nod = nod ?? FakeNod()
        speech = RecordingSpeechOutput()
        let transport = NodHTTPTransport(
            client: NodClient(baseURL: URL(string: "https://nod.example.com")!, key: key, http: nod),
            eventRetry: RetryPolicy(base: 0, factor: 1, cap: 0, maxRetries: nil),
            sleep: { _ in try await Task.sleep(for: .milliseconds(2)) }
        )
        return ConversationModel(transport: transport, speech: speech, store: store, sleep: { _ in await Task.yield() })
    }

    private func until(_ what: String, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<3000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    private func messages(_ model: ConversationModel) -> [ChatMessage] {
        model.items.compactMap { if case .message(let message) = $0 { return message } else { return nil } }
    }

    private func turn(of message: ChatMessage) -> String {
        nod.userMessages.first { $0["id"] as? String == message.id.uuidString.lowercased() }?["turnId"] as? String ?? ""
    }

    func testTheExistingConversationIsShownOnConnecting() async {
        nod = FakeNod()
        nod.addMessage(role: "user", text: "Remind me to call Mina")
        nod.addMessage(role: "assistant", text: "I will remind you at five.")
        let model = makeModel()
        model.start()
        await until("the conversation") { self.messages(model).count == 2 }

        XCTAssertEqual(model.connection, .connected)
        XCTAssertEqual(messages(model).map(\.text), ["Remind me to call Mina", "I will remind you at five."])
        XCTAssertTrue(speech.spoken.isEmpty, "what was said earlier is not read out")
        model.shutDown()
    }

    func testTheConversationIsThereAtOnceTheNextTimeTheAppOpens() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "nod-store-\(UUID().uuidString)/conversation.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConversationStore(file: file)
        nod = FakeNod()
        nod.addMessage(role: "user", text: "Remind me to call Mina")
        nod.addMessage(role: "assistant", text: "I will remind you at five.")

        let first = makeModel(store: store)
        XCTAssertTrue(first.items.isEmpty, "nothing is kept before the first launch")
        first.start()
        await until("the conversation") { self.messages(first).count == 2 }
        await until("the conversation to be kept") { store.load().count == 2 }
        let shown = first.items.map(\.id)
        first.shutDown()

        // The next launch: the messages are there before anything was asked of Nod.
        nod.addMessage(role: "assistant", text: "It is five. Call Mina.")
        let second = makeModel(store: store)
        XCTAssertEqual(second.items.map(\.id), shown)
        XCTAssertEqual(messages(second).map(\.text), ["Remind me to call Mina", "I will remind you at five."])
        XCTAssertFalse(second.hasLoadedConversation)

        // Nod's record then takes their place, and the rows that were there stay the same rows.
        second.start()
        await until("what was said meanwhile") { self.messages(second).count == 3 }
        XCTAssertEqual(Array(second.items.map(\.id).prefix(2)), shown)
        XCTAssertTrue(second.hasLoadedConversation)
        XCTAssertTrue(speech.spoken.isEmpty)
        second.shutDown()
    }

    func testAReplyIsStreamedSpokenAndThenMatchesNodsRecord() async {
        let model = makeModel()
        model.send("What is on my calendar?")
        await until("Nod to accept") { self.messages(model).first?.status == .delivered }
        let asked = messages(model)[0]
        let turn = turn(of: asked)

        nod.delta(turn: turn, "You have two things today. ")
        await until("the first sentence") { self.messages(model).count == 2 }
        XCTAssertEqual(messages(model)[1].status, .streaming)
        nod.delta(turn: turn, "Stand-up at ten.")
        nod.addMessage(role: "assistant", text: "You have two things today. Stand-up at ten.", turn: turn)
        nod.setTurn(turn, status: "succeeded")
        nod.refresh()
        await until("the turn to end") { model.phase == .idle && self.messages(model).last?.status == .delivered }
        await model.reloadTask?.value

        XCTAssertEqual(messages(model).map(\.text), ["What is on my calendar?", "You have two things today. Stand-up at ten."])
        XCTAssertEqual(messages(model)[0].id, asked.id, "the message keeps the identifier it was sent with")
        XCTAssertEqual(speech.spoken.map(\.text), ["You have two things today.", "Stand-up at ten."])
        model.shutDown()
    }

    func testAReplyStaysTheSameRowWhenNodsRecordReplacesTheList() async {
        let model = makeModel()
        model.send("Hello")
        await until("Nod to accept") { self.messages(model).first?.status == .delivered }
        let turn = turn(of: messages(model)[0])
        nod.delta(turn: turn, "Hi there.")
        await until("the reply") { self.messages(model).count == 2 }
        let shownUnder = messages(model)[1].id

        nod.finish(turn: turn, reply: "Hi there.")
        await until("the turn to end") { model.phase == .idle }
        await model.reloadTask?.value
        // Something else changes later and the list is read again.
        nod.addMessage(role: "assistant", text: "A reminder.")
        nod.refresh()
        await until("the reminder") { self.messages(model).count == 3 }

        XCTAssertEqual(messages(model)[1].id, shownUnder, "no twin replaces the reply on screen")
        XCTAssertEqual(messages(model)[1].status, .delivered)
        model.shutDown()
    }

    func testAPhotoIsSentAndKeepsItsPreviewAfterNodsRecordArrives() async {
        let model = makeModel()
        let photo = Attachment(name: "Photo 1.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))
        model.send("", attachments: [photo])
        await until("Nod to accept") { self.messages(model).first?.status == .delivered }
        let turn = turn(of: messages(model)[0])
        nod.finish(turn: turn, reply: "A cat.")
        await until("the turn to end") { model.phase == .idle && self.messages(model).count == 2 }
        await model.reloadTask?.value

        XCTAssertEqual(nod.uploads.count, 1)
        XCTAssertEqual(messages(model)[0].attachments.first?.data, Data([1, 2, 3]), "the content stays for the preview")
        model.shutDown()
    }

    func testWhatHappensOnAnotherDeviceAppears() async {
        let model = makeModel()
        model.start()
        await until("connected") { model.connection == .connected }

        nod.addMessage(role: "user", text: "Typed in the web app")
        nod.addMessage(role: "assistant", text: "Answered there.")
        nod.refresh()
        await until("the other device's messages") { self.messages(model).count == 2 }

        XCTAssertTrue(speech.spoken.isEmpty)
        model.shutDown()
    }

    func testAKeyThatIsNotAcceptedIsNotTriedOverAndOver() async {
        let model = makeModel(key: "wrong")
        model.start()
        await until("the refusal") { if case .refused = model.connection { return true } else { return false } }
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.connection, .refused("Nod did not accept the authentication key."))
        XCTAssertEqual(nod.calls(to: "/api/session").count, 1, "a refusal is not retried on its own")
        model.shutDown()
    }

    func testStopAsksNodToStopAndANewMessageDoesNot() async {
        let model = makeModel()
        model.send("Research this at length")
        await until("Nod to accept") { self.messages(model).first?.status == .delivered }

        model.send("And another thing")
        await until("the second message") { self.nod.userMessages.count == 2 }
        XCTAssertTrue(nod.calls(to: "/api/thread/stop", method: "POST").isEmpty)

        model.interrupt()
        await model.cancelTask?.value
        XCTAssertEqual(nod.calls(to: "/api/thread/stop", method: "POST").count, 1)
        model.shutDown()
    }

    func testAnApprovalFromTheRecordCanBeAnsweredByTapping() async {
        nod = FakeNod()
        let approvalID = UUID().uuidString.lowercased()
        nod.addMessage(role: "assistant", text: "Shall I send this?", approval: ["id": approvalID, "state": "pending", "title": "Send email to Alex", "app": "Gmail", "slug": "gmail"])
        let model = makeModel()
        model.start()
        await until("the approval") { model.pendingApprovals.count == 1 }

        model.send("yes do it", mode: .spoken)
        XCTAssertTrue(nod.userMessages.isEmpty, "speech is held back while the approval is open")

        await model.decide(approvalID: approvalID, .approved)
        let answer = nod.calls(to: "/api/messages", method: "POST").last?.body
        XCTAssertEqual((answer?["approvalAnswer"] as? [String: Any])?["approved"] as? Bool, true)
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        model.shutDown()
    }

    func testAReplyThatWasNotStreamedIsSpokenFromNodsRecord() async {
        let model = makeModel()
        model.send("What is on my calendar?")
        await until("Nod to accept") { self.messages(model).first?.status == .delivered }
        let turn = turn(of: messages(model)[0])

        // Nod answers without streaming: the reply is only in its record.
        nod.finish(turn: turn, reply: "Stand-up at ten.")
        await until("the reply") { self.messages(model).count == 2 }
        await until("the reply to be spoken") { !self.speech.spoken.isEmpty }

        XCTAssertEqual(speech.spoken.map(\.text), ["Stand-up at ten."])
        model.shutDown()
    }

    func testAReplyToAMessageThatWasLeftIsSpokenWhenItArrives() async {
        let model = makeModel()
        model.send("What is on my calendar?")
        await until("Nod to accept") { self.messages(model).first?.status == .delivered }
        let first = turn(of: messages(model)[0])
        // Another utterance before any text came.
        model.send("And tomorrow?")
        await until("Nod to accept the second") { self.messages(model).count == 2 && self.messages(model)[1].status == .delivered }
        let second = turn(of: messages(model)[1])

        nod.addMessage(role: "assistant", text: "Stand-up at ten.", turn: first)
        nod.setTurn(first, status: "succeeded")
        nod.finish(turn: second, reply: "Tomorrow is free.")
        await until("both replies") { self.messages(model).count == 4 }
        await until("the replies to be spoken") { self.speech.spoken.count == 2 }

        // The turn followed now passes on its own reply; the one left behind comes from Nod's record.
        XCTAssertEqual(speech.spoken.map(\.text), ["Tomorrow is free.", "Stand-up at ten."])
        model.shutDown()
    }

    func testAStreamedReplyIsNotSpokenAgainFromNodsRecord() async {
        let model = makeModel()
        model.send("Hello")
        await until("Nod to accept") { self.messages(model).first?.status == .delivered }
        let turn = turn(of: messages(model)[0])
        nod.delta(turn: turn, "Hi there.")
        await until("the reply") { self.messages(model).count == 2 }
        nod.finish(turn: turn, reply: "Hi there.")
        await until("the turn to end") { model.phase == .idle }
        await model.reloadTask?.value
        nod.addMessage(role: "assistant", text: "A reminder.")
        nod.refresh()
        await until("the reminder") { self.messages(model).count == 3 }

        XCTAssertEqual(speech.spoken.map(\.text), ["Hi there."], "neither the reply again nor the later note")
        model.shutDown()
    }
}
