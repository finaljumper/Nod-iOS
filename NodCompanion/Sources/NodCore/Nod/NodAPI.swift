import Foundation

/// The parts of Nod's HTTP interface the app uses, in the shapes Nod's server source gives them
/// (github.com/n8n-io/nod, `src/shared/contracts.ts` and `src/server/app.ts`, read at commit
/// 79f194a on 2026-11-20). Nod does not promise this as a stable interface, so everything that
/// is not strictly needed is optional and unknown fields are ignored.
public enum NodAPI {
    /// `GET /api/session`
    public struct Session: Decodable, Sendable, Equatable {
        public struct User: Decodable, Sendable, Equatable {
            public var id: String
            public var name: String?
        }

        public var user: User?
    }

    /// `GET /api/state`
    public struct State: Decodable, Sendable, Equatable {
        public var threadId: String
        public var messages: [Message]
        public var turns: [Turn]
        public var activity: [Activity]

        public init(threadId: String, messages: [Message] = [], turns: [Turn] = [], activity: [Activity] = []) {
            self.threadId = threadId
            self.messages = messages
            self.turns = turns
            self.activity = activity
        }

        private enum CodingKeys: String, CodingKey { case threadId, messages, turns, activity }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            threadId = try container.decode(String.self, forKey: .threadId)
            // One entry in a shape this app does not know must not hide all the others.
            messages = try container.decodeIfPresent(Lossy<Message>.self, forKey: .messages)?.values ?? []
            turns = try container.decodeIfPresent(Lossy<Turn>.self, forKey: .turns)?.values ?? []
            activity = try container.decodeIfPresent(Lossy<Activity>.self, forKey: .activity)?.values ?? []
        }
    }

    public struct Message: Decodable, Sendable, Equatable {
        public var id: String
        public var role: String
        public var text: String
        public var displayText: String?
        public var turnId: String?
        public var createdAt: String?
        public var attachments: [Attachment]?
        public var approval: Approval?

        public init(id: String, role: String, text: String, displayText: String? = nil, turnId: String? = nil, createdAt: String? = nil, attachments: [Attachment]? = nil, approval: Approval? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.displayText = displayText
            self.turnId = turnId
            self.createdAt = createdAt
            self.attachments = attachments
            self.approval = approval
        }
    }

    /// A stored file, as it hangs on a message and as `POST /api/uploads` answers.
    public struct Attachment: Decodable, Sendable, Equatable {
        public var id: String?
        public var name: String?
        public var mimeType: String?
        public var size: Int?
    }

    /// An action Nod will not take until it is approved. It hangs on the assistant message
    /// that asks for it; `state` is pending, working, done, declined, expired or uncertain.
    public struct Approval: Decodable, Sendable, Equatable {
        public struct Field: Decodable, Sendable, Equatable {
            public var label: String
            public var value: String
        }

        public var id: String
        public var state: String
        public var title: String
        public var app: String?
        public var fields: [Field]?
        public var body: String?
        public var failure: String?

        public init(id: String, state: String, title: String, app: String? = nil, fields: [Field]? = nil, body: String? = nil, failure: String? = nil) {
            self.id = id
            self.state = state
            self.title = title
            self.app = app
            self.fields = fields
            self.body = body
            self.failure = failure
        }
    }

    /// One run of the agent. `status` is queued, running, succeeded, waiting, failed or cancelled.
    public struct Turn: Decodable, Sendable, Equatable {
        public var id: String
        public var status: String
        public var error: String?

        public init(id: String, status: String, error: String? = nil) {
            self.id = id
            self.status = status
            self.error = error
        }

        /// Nothing more will come from this turn.
        public var isOver: Bool { ["succeeded", "failed", "cancelled"].contains(status) }
    }

    /// What a turn is doing right now. `doing` is queued, model or tool.
    public struct Activity: Decodable, Sendable, Equatable {
        public var turnId: String
        public var title: String?
        public var step: String?
        public var site: String?
        public var doing: String?
        public var tool: String?
        public var background: Bool?

        public init(turnId: String, title: String? = nil, step: String? = nil, site: String? = nil, doing: String? = nil, tool: String? = nil, background: Bool? = nil) {
            self.turnId = turnId
            self.title = title
            self.step = step
            self.site = site
            self.doing = doing
            self.tool = tool
            self.background = background
        }
    }

    /// The answer to `POST /api/messages`.
    public struct Submitted: Decodable, Sendable, Equatable {
        public var threadId: String?
        public var turnId: String?
        public var messageId: String?
    }

    /// The body of an error answer.
    public struct Failure: Decodable, Sendable, Equatable {
        public var error: String?
        public var code: String?
    }

    /// A piece of reply text. Pieces are appended; `done` closes the stream they belong to.
    public struct Delta: Decodable, Sendable, Equatable {
        public var threadId: String
        public var turnId: String
        public var text: String?
        public var streamId: String?
        public var done: Bool?

        public init(threadId: String, turnId: String, text: String? = nil, streamId: String? = nil, done: Bool? = nil) {
            self.threadId = threadId
            self.turnId = turnId
            self.text = text
            self.streamId = streamId
            self.done = done
        }
    }

    /// One frame of `GET /api/events`.
    public enum Event: Sendable, Equatable {
        /// Something changed; read the state again.
        case refresh
        case activity([Activity])
        case delta(Delta)
        /// A frame of a kind this app does not know.
        case unknown

        public init(payload: String) {
            struct Kind: Decodable { var type: String }
            struct Items: Decodable { var items: Lossy<Activity> }
            let data = Data(payload.utf8)
            let decoder = JSONDecoder()
            guard let kind = try? decoder.decode(Kind.self, from: data) else {
                self = .unknown
                return
            }
            switch kind.type {
            case "refresh":
                self = .refresh
            case "activity":
                self = (try? decoder.decode(Items.self, from: data)).map { .activity($0.items.values) } ?? .unknown
            case "delta":
                self = (try? decoder.decode(Delta.self, from: data)).map { .delta($0) } ?? .unknown
            default:
                self = .unknown
            }
        }
    }

    /// An array that keeps the entries it can read and drops the others.
    struct Lossy<Element: Decodable & Sendable>: Decodable, Sendable {
        var values: [Element] = []

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd {
                if let value = try? container.decode(Element.self) {
                    values.append(value)
                } else {
                    _ = try? container.decode(Anything.self)
                }
            }
        }
    }
}

/// Stands for a value whose shape does not matter, so that it can be skipped.
private struct Anything: Decodable {}

/// Reads a `text/event-stream` line by line.
public struct SSEParser: Sendable {
    private var data: [String] = []

    public init() {}

    /// Takes one line without its line ending. Returns the data of a frame when the line
    /// completes one: a frame ends at an empty line, and lines that start with a colon are
    /// comments (Nod sends ": keepalive").
    public mutating func feed(_ line: String) -> String? {
        if line.isEmpty {
            defer { data = [] }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts[0] == "data" else { return nil }
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        data.append(value)
        return nil
    }
}
