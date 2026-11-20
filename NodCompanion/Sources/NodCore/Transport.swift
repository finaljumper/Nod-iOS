import Foundation

/// One user request to Nod.
public struct TurnRequest: Sendable, Equatable {
    /// Created once per user message and reused on every retry, so that the receiving side can
    /// recognise a repeat and not act twice.
    public let requestID: UUID
    public var conversationID: String
    public var text: String
    /// Photos and files sent with the text. The text may be empty when there are some.
    public var attachments: [Attachment]
    public var inputMode: ChatMessage.InputMode

    public init(requestID: UUID, conversationID: String, text: String, attachments: [Attachment] = [], inputMode: ChatMessage.InputMode) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.text = text
        self.attachments = attachments
        self.inputMode = inputMode
    }
}

/// What Nod reports while it works on a request.
public enum NodEvent: Sendable, Equatable {
    /// Nod has the request. From here on, sending it again could make Nod act twice.
    case accepted
    case thinking
    /// The next piece of the reply text.
    case textDelta(String)
    case toolStarted(id: String, name: String, detail: String?)
    case toolFinished(id: String, succeeded: Bool, summary: String?)
    case approvalRequested(ApprovalRequest)
    /// An approval was settled, here or somewhere else.
    case approvalResolved(id: String, approved: Bool)
    /// The turn is finished. A stream that ends without this was cut off.
    case completed
}

public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConnected
    case connectionLost
    case rejected(String)

    public var description: String {
        switch self {
        case .notConnected: return "Not connected to Nod."
        case .connectionLost: return "The connection to Nod was lost."
        case .rejected(let reason): return reason
        }
    }
}

/// The connection to Nod, as the app needs it.
///
/// `NodHTTPTransport` talks to a real Nod server; `DemoTransport` is a stand-in that runs
/// inside the app.
public protocol NodTransport: Sendable {
    /// Throws `TransportError.rejected` when trying again unchanged cannot help, such as a key
    /// that is not accepted.
    func connect() async throws
    func disconnect() async
    /// Sends a request and reports Nod's progress. The stream finishes after `.completed` and
    /// throws when the connection breaks. Ending the stream early only stops listening: Nod
    /// goes on with the request.
    func send(_ request: TurnRequest) -> AsyncThrowingStream<NodEvent, Error>
    /// Asks Nod to stop working. Only called when the user asks for it.
    func cancel(requestID: UUID) async
    /// Throws `TransportError.rejected` when the approval is no longer open.
    func resolve(approvalID: String, approved: Bool) async throws
    /// The conversation as Nod holds it, or nil for a transport that keeps none.
    func loadConversation() async throws -> [ConversationItem]?
    /// Fires when something changed on Nod's side, by this app or by anything else.
    func updates() -> AsyncStream<Void>
}

extension NodTransport {
    public func loadConversation() async throws -> [ConversationItem]? { nil }
    public func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Waiting times between connection attempts: `base`, then multiplied by `factor` each time,
/// never more than `cap`.
public struct RetryPolicy: Sendable, Equatable {
    public var base: Double
    public var factor: Double
    public var cap: Double
    /// Attempts allowed after the first failure; `nil` for no limit.
    public var maxRetries: Int?

    public init(base: Double = 1, factor: Double = 2, cap: Double = 30, maxRetries: Int? = 4) {
        self.base = base
        self.factor = factor
        self.cap = cap
        self.maxRetries = maxRetries
    }

    /// Seconds to wait before retry number `retry` (1 for the first), or `nil` when the limit
    /// is reached.
    public func delay(beforeRetry retry: Int) -> Double? {
        guard retry >= 1 else { return 0 }
        if let maxRetries, retry > maxRetries { return nil }
        return min(cap, base * pow(factor, Double(retry - 1)))
    }
}
