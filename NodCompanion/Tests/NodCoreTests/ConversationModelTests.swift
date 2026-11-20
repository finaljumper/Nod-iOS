import XCTest
@testable import NodCore

/// Records what would have been spoken.
@MainActor
final class RecordingSpeechOutput: SpeechOutput {
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?
    private(set) var spoken: [SpeechSegment] = []
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0

    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }

    func speak(_ segment: SpeechSegment) {
        spoken.append(segment)
        onSpeakingChanged?(true)
    }

    func stop() {
        stopCount += 1
        onSpeakingChanged?(false)
    }
}

@MainActor
final class ConversationModelTests: XCTestCase {
    private var transport: DemoTransport!
    private var speech: RecordingSpeechOutput!

    /// A model whose waits between retries take no time.
    private func makeModel(
        timing: DemoTransport.Timing = .instant,
        turnRetry: RetryPolicy = RetryPolicy(maxRetries: 4),
        speechInput: (any SpeechInput)? = nil
    ) -> ConversationModel {
        transport = DemoTransport(timing: timing)
        speech = RecordingSpeechOutput()
        return ConversationModel(
            transport: transport,
            speech: speech,
            speechInput: speechInput,
            turnRetry: turnRetry,
            sleep: { _ in await Task.yield() }
        )
    }

    private func until(_ what: String, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    private func finishTurn(_ model: ConversationModel) async {
        await until("the turn to end") { model.phase == .idle && model.turnTask == nil }
    }

    private func messages(_ model: ConversationModel, _ role: ChatMessage.Role) -> [ChatMessage] {
        model.items.compactMap { if case .message(let message) = $0, message.role == role { return message } else { return nil } }
    }

    private func tools(_ model: ConversationModel) -> [ToolActivity] {
        model.items.compactMap { if case .tool(let tool) = $0 { return tool } else { return nil } }
    }

    private func approvals(_ model: ConversationModel) -> [ApprovalRequest] {
        model.items.compactMap { if case .approval(let approval) = $0 { return approval } else { return nil } }
    }

    // MARK: A normal turn

    func testReplyIsStreamedDeliveredAndSpokenSentenceBySentence() async {
        let model = makeModel()
        model.send("  What is on my calendar today?  ")
        XCTAssertEqual(model.phase, .sending)
        await finishTurn(model)

        let user = messages(model, .user)
        XCTAssertEqual(user.map(\.text), ["What is on my calendar today?"], "the message is trimmed")
        XCTAssertEqual(user.first?.status, .delivered)
        XCTAssertEqual(tools(model).map(\.state), [.succeeded])
        let reply = messages(model, .assistant)
        XCTAssertEqual(reply.map(\.text), ["You have two things today. Stand-up at 10:00, and lunch with Dmitri at 12:30."])
        XCTAssertEqual(reply.first?.status, .delivered)
        XCTAssertEqual(model.connection, .connected)
        XCTAssertEqual(speech.spoken, [
            SpeechSegment(text: "You have two things today.", language: "en"),
            SpeechSegment(text: "Stand-up at 10:00, and lunch with Dmitri at 12:30.", language: "en"),
        ])
        XCTAssertEqual(model.activity.map(\.kind), [.tool])
    }

    func testRepliesAreSpokenInTheLanguageTheyAreWrittenIn() async {
        let model = makeModel()
        model.send("Что у меня в календаре?")
        await finishTurn(model)
        XCTAssertEqual(Set(speech.spoken.map(\.language)), ["ru"])

        model.send("오늘 일정 알려 줘")
        await finishTurn(model)
        XCTAssertEqual(speech.spoken.last?.language, "ko")
    }

    func testEmptyMessagesAreNotSent() async {
        let model = makeModel()
        model.send("   \n ")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.phase, .idle)
    }

    func testNothingIsSpokenWhenSpeakingIsOff() async {
        let model = makeModel()
        model.speaksReplies = false
        model.send("What is on my calendar?")
        await finishTurn(model)
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(messages(model, .assistant).count, 1)
    }

    // MARK: Interrupting

    func testANewMessageSilencesTheReplyInProgressButDoesNotStopNod() async {
        let model = makeModel(timing: .init(thinking: 0, tool: 0, word: 0.02))
        model.send("What is on my calendar?")
        await until("the first reply to start") { model.phase == .responding }

        model.send("Что у меня в календаре?")
        await finishTurn(model)

        let replies = messages(model, .assistant)
        XCTAssertEqual(replies.map(\.status), [.delivered, .delivered])
        XCTAssertLessThan(replies[0].text.count, 40, "the app stopped following the first reply")
        XCTAssertTrue(replies[1].text.hasPrefix("Сегодня у вас две встречи"))
        XCTAssertGreaterThanOrEqual(speech.stopCount, 1, "playback stops at once")
        let cancelled = await transport.cancelledRequests
        XCTAssertTrue(cancelled.isEmpty, "Nod's stop ends all of its work; a new message must not trigger it")
    }

    func testStopTellsNodToStop() async {
        let model = makeModel(timing: .init(thinking: 0, tool: 0, word: 0.02))
        model.send("What is on my calendar?")
        await until("the reply to start") { model.phase == .responding }
        let first = messages(model, .user)[0].id

        model.interrupt()
        await model.cancelTask?.value

        XCTAssertEqual(messages(model, .assistant).map(\.status), [.interrupted])
        XCTAssertEqual(model.phase, .idle)
        let cancelled = await transport.cancelledRequests
        XCTAssertEqual(cancelled, [first])
        XCTAssertTrue(model.activity.contains { $0.kind == .interrupted })
    }

    func testStopSpeakingSilencesTheRestOfTheReplyButLetsItFinish() async {
        let model = makeModel(timing: .init(thinking: 0, tool: 0, word: 0.01))
        model.send("What is on my calendar?")
        await until("the first sentence to be spoken") { !self.speech.spoken.isEmpty }
        model.stopSpeaking()
        let spokenBefore = speech.spoken.count
        await finishTurn(model)

        XCTAssertEqual(speech.spoken.count, spokenBefore)
        XCTAssertEqual(messages(model, .assistant).first?.status, .delivered)
        let cancelled = await transport.cancelledRequests
        XCTAssertTrue(cancelled.isEmpty, "Nod was not asked to stop")
    }

    // MARK: Approvals

    private func emailAwaitingApproval(_ model: ConversationModel) async -> ApprovalRequest {
        model.send("Send an email to Alex about Friday")
        await until("the approval request") { model.phase == .waitingForApproval }
        return model.pendingApprovals[0]
    }

    func testAnApprovedEmailIsSent() async {
        let model = makeModel()
        let approval = await emailAwaitingApproval(model)
        XCTAssertEqual(approval.kind, .email)
        var sent = await transport.emailsSent
        XCTAssertEqual(sent, 0, "nothing is sent while the approval is open")
        XCTAssertEqual(speech.spoken.last?.text, "Send email to Alex", "the request is also spoken")

        await model.decide(approvalID: approval.id, .approved)
        await finishTurn(model)

        sent = await transport.emailsSent
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(approvals(model).map(\.state), [.decided(.approved)])
        XCTAssertEqual(messages(model, .assistant).map(\.text), [
            "I drafted the email. It needs your approval before I send it.",
            "Done. The email is sent.",
        ])
        // The conversation reads in the order things happened.
        let order = model.items.map { item -> String in
            switch item {
            case .message(let message): return message.role.rawValue
            case .tool(let tool): return tool.name
            case .approval: return "approval"
            }
        }
        XCTAssertEqual(order, ["user", "mail.compose", "assistant", "approval", "mail.send", "assistant"])
        XCTAssertEqual(model.activity.map(\.kind), [.tool, .approvalRequested, .approved, .tool])
    }

    func testADeniedEmailIsNotSent() async {
        let model = makeModel()
        let approval = await emailAwaitingApproval(model)
        await model.decide(approvalID: approval.id, .denied)
        await finishTurn(model)

        let sent = await transport.emailsSent
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(approvals(model).map(\.state), [.decided(.denied)])
        XCTAssertEqual(messages(model, .assistant).last?.text, "Okay, I did not send it.")
        XCTAssertTrue(model.activity.contains { $0.kind == .denied })
    }

    func testInterruptingClosesTheApprovalAndNothingIsSent() async {
        let model = makeModel()
        let approval = await emailAwaitingApproval(model)
        model.interrupt()
        await model.cancelTask?.value

        XCTAssertEqual(approvals(model).map(\.state), [.expired])
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        // A decision that arrives late changes nothing.
        await model.decide(approvalID: approval.id, .approved)
        try? await Task.sleep(for: .milliseconds(20))
        let sent = await transport.emailsSent
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(approvals(model).map(\.state), [.expired])
    }

    func testASpokenRequestIsNotSentWhileAnApprovalIsOpen() async {
        // Nod reads a message that arrives while an approval is open as a possible answer to
        // it. Speech must never approve anything, so spoken words are held back.
        let model = makeModel()
        _ = await emailAwaitingApproval(model)
        model.send("Yes, go ahead", mode: .spoken)

        XCTAssertEqual(messages(model, .user).count, 1, "the spoken words were not sent")
        XCTAssertEqual(approvals(model).map(\.state), [.pending])
        XCTAssertEqual(model.phase, .waitingForApproval)
        let sent = await transport.emailsSent
        XCTAssertEqual(sent, 0)
    }

    func testATypedMessageLeavesAnOpenApprovalToNod() async {
        let model = makeModel()
        let approval = await emailAwaitingApproval(model)
        model.send("What is on my calendar?")
        await finishTurn(model)

        XCTAssertEqual(approvals(model).map(\.state), [.pending], "the app does not close what Nod still holds open")
        // The demo, like Nod, no longer answers for a turn that was left; the card then closes.
        await model.decide(approvalID: approval.id, .approved)
        XCTAssertEqual(approvals(model).map(\.state), [.expired])
        let sent = await transport.emailsSent
        XCTAssertEqual(sent, 0)
    }

    // MARK: Connection trouble

    func testARequestLostBeforeNodAcceptedItIsSentAgainOnItsOwn() async {
        let model = makeModel()
        await transport.dropNextSends(1)
        model.send("What is on my calendar?")
        await finishTurn(model)

        let executed = await transport.executedRequests
        XCTAssertEqual(executed, [messages(model, .user)[0].id], "acted on once, under the same identifier")
        XCTAssertEqual(messages(model, .user)[0].status, .delivered)
        XCTAssertEqual(messages(model, .assistant).count, 1)
        let attempts = await transport.connectAttempts
        XCTAssertEqual(attempts, 2)
    }

    func testARequestNodAcceptedIsNeverSentAgainOnItsOwn() async {
        let model = makeModel()
        model.send("Please disconnect now")
        await finishTurn(model)

        let user = messages(model, .user)[0]
        guard case .uncertain = user.status else { return XCTFail("expected the outcome to be marked unknown, got \(user.status)") }
        XCTAssertTrue(model.canRetry(user))
        XCTAssertEqual(tools(model).map(\.state), [.unknown])
        var executed = await transport.executedRequests
        XCTAssertEqual(executed.count, 1)
        var repeated = await transport.repeatedRequests
        XCTAssertTrue(repeated.isEmpty, "the app did not resend it by itself")

        // The user decides to send it again: same identifier, so it is recognised as a repeat.
        model.retry(messageID: user.id)
        await finishTurn(model)
        executed = await transport.executedRequests
        repeated = await transport.repeatedRequests
        XCTAssertEqual(executed, [user.id])
        XCTAssertEqual(repeated, [user.id])
        XCTAssertEqual(messages(model, .user)[0].status, .delivered)
        XCTAssertEqual(messages(model, .assistant).last?.text, "I already have this request and did not run it again.")
    }

    func testGivingUpLeavesTheMessageReadyToSendAgain() async {
        let model = makeModel(turnRetry: RetryPolicy(maxRetries: 2))
        await transport.failNextConnects(3)
        model.send("What is on my calendar?")
        await finishTurn(model)

        let user = messages(model, .user)[0]
        XCTAssertEqual(user.status, .failed("Could not reach Nod."))
        let executed = await transport.executedRequests
        XCTAssertTrue(executed.isEmpty)
        XCTAssertTrue(model.activity.contains { $0.kind == .problem })

        // It reconnects in the background, and the retry then goes through.
        await until("the background reconnect") { model.connection == .connected }
        model.retry(messageID: user.id)
        await finishTurn(model)
        XCTAssertEqual(messages(model, .user)[0].status, .delivered)
        XCTAssertEqual(messages(model, .assistant).count, 1)
    }

    func testStartKeepsTryingUntilItConnects() async {
        let model = makeModel()
        await transport.failNextConnects(3)
        model.start()
        await until("the connection") { model.connection == .connected }
        let attempts = await transport.connectAttempts
        XCTAssertEqual(attempts, 4)
    }

    // MARK: Listening

    func testASpokenRequestShowsALiveTranscriptAndIsSent() async {
        let input = ScriptedSpeechInput(phrases: ["what is on my calendar today please"], wordDelay: 0.01)
        let model = makeModel(speechInput: input)
        model.startListening()
        XCTAssertTrue(model.isListening)
        await until("a partial transcript") { !model.liveTranscript.isEmpty }
        XCTAssertTrue("what is on my calendar today please".hasPrefix(model.liveTranscript))

        await until("listening to end") { !model.isListening }
        await finishTurn(model)
        let user = messages(model, .user)[0]
        XCTAssertEqual(user.text, "what is on my calendar today please")
        XCTAssertEqual(user.inputMode, .spoken)
        XCTAssertEqual(model.liveTranscript, "")
        XCTAssertEqual(messages(model, .assistant).count, 1)
    }

    func testFinishingEarlySendsWhatWasHeardSoFar() async {
        let input = ScriptedSpeechInput(phrases: ["one two three four five six seven eight nine ten"], wordDelay: 0.02)
        let model = makeModel(speechInput: input)
        model.startListening()
        await until("two words") { model.liveTranscript.split(separator: " ").count >= 2 }
        model.finishListening()
        await until("listening to end") { !model.isListening }
        await finishTurn(model)

        let text = messages(model, .user)[0].text
        XCTAssertTrue("one two three four five six seven eight nine ten".hasPrefix(text))
        XCTAssertLessThan(text.split(separator: " ").count, 10)
    }

    func testListeningStopsPlaybackAtOnceAndCancellingSendsNothing() async {
        let input = ScriptedSpeechInput(phrases: ["hello there"], wordDelay: 0.05)
        let model = makeModel(speechInput: input)
        model.startListening()
        XCTAssertEqual(speech.stopCount, 1)
        model.cancelListening()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isListening)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testWithoutARecogniserListeningDoesNotStart() async {
        let model = makeModel()
        XCTAssertEqual(model.speechInputAvailability, .unavailable(NoSpeechInput.reason))
        model.startListening()
        XCTAssertFalse(model.isListening)
    }

    // MARK: Dialogue

    private func dialogueInput(_ phrases: [String], wordDelay: Double = 0, pause: Double = 0) -> ScriptedSpeechInput {
        ScriptedSpeechInput(phrases: phrases, wordDelay: wordDelay, pauseBetweenPhrases: pause, loops: false)
    }

    func testADialogueSendsEveryUtteranceAndSpeaksEveryReply() async {
        let model = makeModel(speechInput: dialogueInput(["what is on my calendar", "오늘 일정 알려 줘"], pause: 0.05))
        model.speaksReplies = false   // a dialogue is spoken whatever this setting says
        model.startDialogue()
        XCTAssertTrue(model.isDialogueActive)
        XCTAssertEqual(model.dialogueState, .listening)

        await until("both utterances to be answered") { self.messages(model, .assistant).count == 2 && model.phase == .idle }
        let user = messages(model, .user)
        XCTAssertEqual(user.map(\.text), ["what is on my calendar", "오늘 일정 알려 줘"])
        XCTAssertEqual(user.map(\.inputMode), [.spoken, .spoken])
        XCTAssertEqual(Set(speech.spoken.map(\.language)), ["en", "ko"])

        XCTAssertTrue(model.isDialogueActive, "the dialogue goes on until the user leaves it")
        model.stopDialogue()
        XCTAssertEqual(model.dialogueState, .off)
        XCTAssertEqual(model.liveTranscript, "")
    }

    func testTalkingOverAReplyStopsTheVoiceAndTheNextUtteranceIsFollowedInstead() async {
        let input = dialogueInput(["what is on my calendar", "what is on my calendar"], wordDelay: 0.01, pause: 0.4)
        let model = makeModel(timing: .init(thinking: 0, tool: 0, word: 0.05), speechInput: input)
        model.startDialogue()

        // The second utterance arrives while the first reply is being written and spoken.
        await until("two requests") { self.messages(model, .user).count == 2 }
        await until("the second reply") { self.messages(model, .assistant).last?.text.hasSuffix("12:30.") == true && model.phase == .idle }

        let replies = messages(model, .assistant)
        XCTAssertEqual(replies.count, 2)
        XCTAssertLessThan(replies[0].text.count, replies[1].text.count, "the first reply was left unfinished")
        XCTAssertGreaterThanOrEqual(speech.pauseCount, 1, "the voice falls silent as soon as something is heard")
        XCTAssertGreaterThanOrEqual(speech.stopCount, 2, "and stays silent once it is the user's words")
        XCTAssertEqual(speech.resumeCount, 0)
        let cancelled = await transport.cancelledRequests
        XCTAssertTrue(cancelled.isEmpty, "talking over a reply does not stop Nod's work")
        model.stopDialogue()
    }

    func testHearingItsOwnVoiceTheAppGoesOnSpeakingAndSendsNothing() async {
        // The second "utterance" is the reply itself coming back through the microphone.
        let input = dialogueInput(["what is on my calendar", "you have two things today"], wordDelay: 0.01, pause: 0.3)
        let model = makeModel(timing: .init(thinking: 0, tool: 0, word: 0.005), speechInput: input)
        model.startDialogue()

        await until("the echo to be recognised") { model.activity.contains { $0.title == "Heard its own voice" } }

        XCTAssertEqual(messages(model, .user).map(\.text), ["what is on my calendar"], "the echo was not sent as a request")
        XCTAssertEqual(speech.pauseCount, 1)
        XCTAssertEqual(speech.resumeCount, 1, "the voice goes on where it fell silent")
        XCTAssertEqual(speech.stopCount, 1, "only the stop before the first request")
        XCTAssertFalse(model.userIsSpeaking)
        model.stopDialogue()
    }

    func testInADialogueSpeechIsHeldBackWhileAnApprovalIsOpen() async {
        let input = dialogueInput(["send an email to alex", "yes send it"], wordDelay: 0.01, pause: 0.3)
        let model = makeModel(timing: .init(thinking: 0, tool: 0, word: 0.01), speechInput: input)
        model.startDialogue()

        await until("the approval") { !model.pendingApprovals.isEmpty }
        await until("the second utterance to be heard and dropped") { model.activity.contains { $0.title == "Not sent: an approval is waiting" } }

        XCTAssertEqual(messages(model, .user).count, 1)
        XCTAssertEqual(model.dialogueState, .waitingForApproval)
        let sent = await transport.emailsSent
        XCTAssertEqual(sent, 0)
        model.stopDialogue()
    }

    func testTheDialogueStateFollowsWhatIsHappening() async {
        let input = dialogueInput(["what is on my calendar today please"], wordDelay: 0.02, pause: 0.02)
        let model = makeModel(timing: .init(thinking: 0.05, tool: 0.05, word: 0.01), speechInput: input)
        var seen: [ConversationModel.DialogueState] = []
        model.startDialogue()
        for _ in 0..<1500 {
            if seen.last != model.dialogueState { seen.append(model.dialogueState) }
            if messages(model, .assistant).first?.status == .delivered { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(Array(seen.prefix(3)), [.listening, .hearing, .thinking], "\(seen)")
        XCTAssertTrue(seen.contains(.speaking), "\(seen)")
        model.stopDialogue()
        XCTAssertEqual(model.dialogueState, .off)
    }

    func testAnUtteranceWithNoWordsIsNotSent() async {
        let model = makeModel(speechInput: dialogueInput([""], pause: 0.01))
        model.startDialogue()
        // The start of speech and the empty result arrive together.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.userIsSpeaking)
        XCTAssertEqual(speech.stopCount, 0, "a sound without words does not end the voice")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.isDialogueActive)
        model.stopDialogue()
    }

    func testLeavingTheDialogueStopsListeningAndTheVoice() async {
        let input = ScriptedSpeechInput(phrases: ["hello there"], wordDelay: 0.05, pauseBetweenPhrases: 0.05, loops: true)
        let model = makeModel(speechInput: input)
        model.startDialogue()
        await until("the user to be heard") { model.userIsSpeaking }
        let stopsBefore = speech.stopCount
        model.stopDialogue()

        XCTAssertFalse(model.isDialogueActive)
        XCTAssertFalse(model.userIsSpeaking)
        XCTAssertGreaterThan(speech.stopCount, stopsBefore)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.items.isEmpty, "nothing heard after leaving is sent")
        // Tap-to-talk still works afterwards.
        model.startListening()
        XCTAssertTrue(model.isListening)
        model.cancelListening()
    }

    func testADialogueDoesNotStartWithoutARecogniser() async {
        let model = makeModel()
        model.startDialogue()
        XCTAssertFalse(model.isDialogueActive)
        XCTAssertEqual(model.dialogueState, .off)
    }
}
