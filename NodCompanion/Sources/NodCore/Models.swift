import Foundation

/// A photo or file that goes with a message.
public struct Attachment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    /// The content, for what is being sent from this device. Nod's record of the conversation
    /// carries names only.
    public var data: Data?

    public init(id: UUID = UUID(), name: String, mimeType: String, byteCount: Int? = nil, data: Data? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount ?? data?.count ?? 0
        self.data = data
    }

    public var isImage: Bool { mimeType.hasPrefix("image/") }

    /// The content is not compared: it can be megabytes, and the identifier stands for it.
    public static func == (first: Attachment, second: Attachment) -> Bool {
        first.id == second.id && first.name == second.name && first.mimeType == second.mimeType
            && first.byteCount == second.byteCount && (first.data == nil) == (second.data == nil)
    }
}

/// One message of the conversation.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public enum InputMode: String, Sendable { case typed, spoken }

    public enum Status: Sendable, Equatable {
        /// User message on its way; Nod has not acknowledged it.
        case sending
        /// User message acknowledged by Nod, or assistant message complete.
        case delivered
        /// Assistant message still arriving.
        case streaming
        /// Assistant message cut off, or user message withdrawn, by the user.
        case interrupted
        /// User message that never reached Nod. Sending it again is safe.
        case failed(String)
        /// The connection broke after Nod accepted the message. Nod may have acted on it.
        case uncertain(String)
    }

    /// For a user message this is also the request identifier sent to Nod.
    public let id: UUID
    public var role: Role
    public var text: String
    public var attachments: [Attachment]
    public var status: Status
    public var inputMode: InputMode
    public var createdAt: Date

    public init(id: UUID = UUID(), role: Role, text: String, attachments: [Attachment] = [], status: Status, inputMode: InputMode = .typed, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.status = status
        self.inputMode = inputMode
        self.createdAt = createdAt
    }
}

/// A tool Nod ran, or is running, during a turn.
public struct ToolActivity: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running, succeeded, failed
        /// Stopped because the user interrupted the turn.
        case cancelled
        /// The connection broke while it ran; whether it finished is not known.
        case unknown
    }

    public let id: String
    public var name: String
    public var detail: String?
    public var state: State
    public var summary: String?
    public var startedAt: Date

    public init(id: String, name: String, detail: String? = nil, state: State = .running, summary: String? = nil, startedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.summary = summary
        self.startedAt = startedAt
    }
}

/// A sensitive action Nod will not take until the user approves it.
public struct ApprovalRequest: Identifiable, Sendable, Equatable {
    /// The kinds of action the product brief requires explicit approval for.
    public enum Kind: String, Sendable, CaseIterable {
        case email, purchase, cancellation, financial, submission, other
    }

    public enum Decision: String, Sendable { case approved, denied }

    public enum State: Sendable, Equatable {
        case pending
        /// The decision is on its way to Nod.
        case submitting(Decision)
        case decided(Decision)
        /// The turn ended before a decision was made. Nod did not act.
        case expired
    }

    public let id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var state: State
    /// Why the last attempt to send a decision failed.
    public var problem: String?
    public var requestedAt: Date

    public init(id: String, kind: Kind, title: String, detail: String, state: State = .pending, problem: String? = nil, requestedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.problem = problem
        self.requestedAt = requestedAt
    }

    public var isPending: Bool { state == .pending }
}

/// One entry of the conversation, in the order it happened.
public enum ConversationItem: Identifiable, Sendable, Equatable {
    case message(ChatMessage)
    case tool(ToolActivity)
    case approval(ApprovalRequest)

    public var id: String {
        switch self {
        case .message(let message): return "message-\(message.id.uuidString)"
        case .tool(let tool): return "tool-\(tool.id)"
        case .approval(let approval): return "approval-\(approval.id)"
        }
    }
}

/// What Nod is doing with the current request.
public enum AssistantPhase: Sendable, Equatable {
    case idle
    case sending
    case thinking
    case usingTool(String)
    case waitingForApproval
    case responding

    public var isBusy: Bool { self != .idle }
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    /// The last attempt failed; the next one starts after `seconds`.
    case waitingToRetry(attempt: Int, seconds: Double)
    /// Nod refused the connection, for example because of the key. Trying again unchanged
    /// would not help, so nothing is tried until the user sends something or changes the setup.
    case refused(String)
}

/// A line of the action history: what Nod did and what the user decided.
public struct ActivityEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case tool, approvalRequested, approved, denied, interrupted, connection, problem
    }

    public let id: UUID
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var date: Date

    public init(id: UUID = UUID(), kind: Kind, title: String, detail: String? = nil, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.date = date
    }
}
