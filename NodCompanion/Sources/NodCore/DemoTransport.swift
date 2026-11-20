import Foundation

/// A stand-in for Nod that runs inside the app, for development and tests.
///
/// It behaves the way the conversation logic expects a real connection to behave: it streams
/// its reply, runs "tools", asks for approval before "sending" an email, can be cancelled, and
/// recognises a repeated request. Nothing leaves the device and nothing is really sent.
///
/// What it answers depends on words in the request: mail, calendar, or "disconnect" to break
/// the connection in the middle of a turn.
public actor DemoTransport: NodTransport {
    /// Pauses that make the demo feel like a real exchange. All zero in tests.
    public struct Timing: Sendable, Equatable {
        public var thinking: Double
        public var tool: Double
        public var word: Double

        public init(thinking: Double = 0.7, tool: Double = 0.9, word: Double = 0.07) {
            self.thinking = thinking
            self.tool = tool
            self.word = word
        }

        public static let instant = Timing(thinking: 0, tool: 0, word: 0)
    }

    private let timing: Timing
    private var connected = false
    private var failingConnects = 0
    private var droppedSends = 0
    private var openApprovals: [String: CheckedContinuation<Bool, Error>] = [:]
    private var approvalOwners: [String: UUID] = [:]

    /// Requests acted on. A repeat of a request does not appear twice.
    public private(set) var executedRequests: [UUID] = []
    /// Requests that arrived again after they had been acted on.
    public private(set) var repeatedRequests: [UUID] = []
    public private(set) var cancelledRequests: [UUID] = []
    public private(set) var emailsSent = 0
    public private(set) var connectAttempts = 0

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    // MARK: Faults, for tests and for trying out the app's error handling

    public func failNextConnects(_ count: Int) { failingConnects = count }

    /// The next `count` requests are lost before the demo assistant has accepted them.
    public func dropNextSends(_ count: Int) { droppedSends = count }

    // MARK: NodTransport

    public func connect() async throws {
        connectAttempts += 1
        if failingConnects > 0 {
            failingConnects -= 1
            throw TransportError.notConnected
        }
        try await pause(timing.thinking / 2)
        connected = true
    }

    public func disconnect() async {
        connected = false
    }

    public nonisolated func send(_ request: TurnRequest) -> AsyncThrowingStream<NodEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(requestID: UUID) async {
        cancelledRequests.append(requestID)
        for (approvalID, owner) in approvalOwners where owner == requestID {
            abandon(approvalID)
        }
    }

    public func resolve(approvalID: String, approved: Bool) async throws {
        guard connected else { throw TransportError.notConnected }
        guard let waiting = openApprovals.removeValue(forKey: approvalID) else {
            throw TransportError.rejected("This approval is no longer open.")
        }
        approvalOwners[approvalID] = nil
        waiting.resume(returning: approved)
    }

    // MARK: The script

    private typealias Output = AsyncThrowingStream<NodEvent, Error>.Continuation

    private func run(_ request: TurnRequest, _ output: Output) async throws {
        guard connected else { throw TransportError.notConnected }
        if droppedSends > 0 {
            droppedSends -= 1
            connected = false
            throw TransportError.connectionLost
        }
        output.yield(.accepted)
        let language = Self.language(of: request.text)

        if executedRequests.contains(request.requestID) {
            repeatedRequests.append(request.requestID)
            try await say(Self.text(.repeated, language), output)
            output.yield(.completed)
            return
        }
        executedRequests.append(request.requestID)
        output.yield(.thinking)
        try await pause(timing.thinking)

        let words = request.text.lowercased()
        if !request.attachments.isEmpty {
            let names = request.attachments.map(\.name).joined(separator: ", ")
            let count = request.attachments.count
            try await say("I received \(count == 1 ? "one attachment" : "\(count) attachments"): \(names). This stand-in cannot look inside; your Nod can.", output)
        } else if Self.mentions(words, ["markdown", "formatting"]) {
            try await say(Self.formattingSample, output)
        } else if Self.mentions(words, ["disconnect", "drop the connection", "обрыв", "연결 끊"]) {
            output.yield(.toolStarted(id: UUID().uuidString, name: "calendar.read", detail: "Reading today's events"))
            try await pause(timing.tool)
            connected = false
            throw TransportError.connectionLost
        } else if Self.mentions(words, ["mail", "письм", "почт", "메일"]) {
            try await emailTurn(request, language, output)
        } else if Self.mentions(words, ["calendar", "schedule", "календар", "расписан", "일정", "캘린더"]) {
            let tool = UUID().uuidString
            output.yield(.toolStarted(id: tool, name: "calendar.read", detail: "Reading today's events"))
            try await pause(timing.tool)
            output.yield(.toolFinished(id: tool, succeeded: true, summary: "2 events today"))
            try await say(Self.text(.calendar, language), output)
        } else {
            try await say(Self.text(.echo, language).replacingOccurrences(of: "%@", with: request.text), output)
        }
        output.yield(.completed)
    }

    private func emailTurn(_ request: TurnRequest, _ language: String, _ output: Output) async throws {
        let draft = UUID().uuidString
        output.yield(.toolStarted(id: draft, name: "mail.compose", detail: "Drafting the email"))
        try await pause(timing.tool)
        output.yield(.toolFinished(id: draft, succeeded: true, summary: "Draft ready"))
        try await say(Self.text(.emailDrafted, language), output)

        let approvalID = UUID().uuidString
        output.yield(.approvalRequested(ApprovalRequest(
            id: approvalID,
            kind: .email,
            title: "Send email to Alex",
            detail: "To: alex@example.com\nSubject: Friday\n\nHi Alex, are we still on for Friday? Let me know what time suits you."
        )))
        let approved = try await waitForApproval(approvalID, owner: request.requestID)
        output.yield(.approvalResolved(id: approvalID, approved: approved))

        if approved {
            let sending = UUID().uuidString
            output.yield(.toolStarted(id: sending, name: "mail.send", detail: "Sending the email"))
            try await pause(timing.tool)
            emailsSent += 1
            output.yield(.toolFinished(id: sending, succeeded: true, summary: "Sent to alex@example.com"))
            try await say(Self.text(.emailSent, language), output)
        } else {
            try await say(Self.text(.emailNotSent, language), output)
        }
    }

    private func waitForApproval(_ approvalID: String, owner: UUID) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                openApprovals[approvalID] = continuation
                approvalOwners[approvalID] = owner
                // Cancellation may have arrived before the continuation was stored.
                if Task.isCancelled { abandon(approvalID) }
            }
        } onCancel: {
            Task { await self.abandon(approvalID) }
        }
    }

    private func abandon(_ approvalID: String) {
        approvalOwners[approvalID] = nil
        openApprovals.removeValue(forKey: approvalID)?.resume(throwing: CancellationError())
    }

    private func say(_ text: String, _ output: Output) async throws {
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            try await pause(timing.word)
            output.yield(.textDelta(word + " "))
        }
    }

    private func pause(_ seconds: Double) async throws {
        if seconds > 0 {
            try await Task.sleep(for: .seconds(seconds))
        } else {
            try Task.checkCancellation()
        }
    }

    // MARK: Wording

    private enum Line { case echo, calendar, emailDrafted, emailSent, emailNotSent, repeated }

    /// Shows what the app makes of formatted text. Ask the demo for "markdown".
    static let formattingSample = """
        ## Today
        You have **two** things and *one* reminder. See [the calendar](https://example.com).

        - Stand-up at `10:00`
        - Lunch with Dmitri
          - bring the notes

        1. Reply to Mina
        2. Book the room

        > Rooms on the third floor are closed.

        | Time | What |
        |---|---|
        | 10:00 | Stand-up |
        | 12:30 | Lunch |

        ```swift
        let free = day.slots.filter { $0.isFree }
        ```
        """

    private static func mentions(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

    /// The language of the first letter of the request: the demo answers in kind.
    static func language(of text: String) -> String {
        for character in text {
            if let language = LanguageSegmenter.language(of: character) { return language }
        }
        return "en"
    }

    private static func text(_ line: Line, _ language: String) -> String {
        switch (line, language) {
        case (.echo, "ru"): return "Это встроенный демо-ассистент, а не Nod. Вы сказали: «%@». Спросите про календарь или попросите отправить письмо."
        case (.echo, "ko"): return "저는 Nod가 아니라 앱에 내장된 데모 어시스턴트입니다. 이렇게 말씀하셨어요: “%@”. 일정이나 메일 보내기를 요청해 보세요."
        case (.echo, _): return "This is the built-in demo assistant, not Nod. You said: “%@”. Ask about your calendar, or ask me to send an email."
        case (.calendar, "ru"): return "Сегодня у вас две встречи. Стендап в 10:00 и обед с Дмитрием в 12:30."
        case (.calendar, "ko"): return "오늘 일정은 두 개입니다. 10시에 스탠드업이 있고, 12시 30분에 드미트리 씨와 점심 약속이 있습니다."
        case (.calendar, _): return "You have two things today. Stand-up at 10:00, and lunch with Dmitri at 12:30."
        case (.emailDrafted, "ru"): return "Я подготовил письмо. Перед отправкой нужно ваше подтверждение."
        case (.emailDrafted, "ko"): return "메일 초안을 작성했습니다. 보내기 전에 승인이 필요합니다."
        case (.emailDrafted, _): return "I drafted the email. It needs your approval before I send it."
        case (.emailSent, "ru"): return "Готово, письмо отправлено."
        case (.emailSent, "ko"): return "메일을 보냈습니다."
        case (.emailSent, _): return "Done. The email is sent."
        case (.emailNotSent, "ru"): return "Хорошо, я не отправил письмо."
        case (.emailNotSent, "ko"): return "알겠습니다. 메일을 보내지 않았습니다."
        case (.emailNotSent, _): return "Okay, I did not send it."
        case (.repeated, "ru"): return "Этот запрос у меня уже есть, повторно я его не выполнял."
        case (.repeated, "ko"): return "이 요청은 이미 받았습니다. 다시 실행하지 않았습니다."
        case (.repeated, _): return "I already have this request and did not run it again."
        }
    }
}
