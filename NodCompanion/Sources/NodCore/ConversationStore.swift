import Foundation

/// Keeps the conversation as it was last shown in a file on the device, so that the app opens
/// with its messages already there, like any messaging app, before Nod has been asked.
///
/// Only what Nod's record holds is kept: messages that arrived, and approvals that are over.
/// A message still on its way, an open approval and a running tool are not, because they
/// are only true for the moment. The content of attachments is not kept either.
public struct ConversationStore: Sendable {
    public let file: URL
    /// Only the newest entries are kept.
    public var limit = 400

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [ConversationItem] {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == Stored.current
        else { return [] }
        return stored.entries.compactMap(\.item)
    }

    public func save(_ items: [ConversationItem]) {
        let entries = items.compactMap(Entry.init).suffix(limit)
        guard let data = try? JSONEncoder().encode(Stored(version: Stored.current, entries: Array(entries))) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable only after the device was unlocked once since it started.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: The file

    private struct Stored: Codable {
        static let current = 1
        var version: Int
        var entries: [Entry]
    }

    private struct Entry: Codable {
        var message: Message?
        var approval: Approval?

        init?(_ item: ConversationItem) {
            switch item {
            case .message(let message):
                guard let stored = Message(message) else { return nil }
                self.message = stored
            case .approval(let approval):
                guard let stored = Approval(approval) else { return nil }
                self.approval = stored
            case .tool:
                return nil
            }
        }

        var item: ConversationItem? {
            if let message { return .message(message.message) }
            if let approval { return approval.request.map(ConversationItem.approval) }
            return nil
        }
    }

    private struct File: Codable {
        var id: UUID
        var name: String
        var mimeType: String
        var byteCount: Int
    }

    private struct Message: Codable {
        var id: UUID
        var fromUser: Bool
        var text: String
        var files: [File]
        var interrupted: Bool
        var spoken: Bool
        var createdAt: Date

        init?(_ message: ChatMessage) {
            switch message.status {
            case .delivered: interrupted = false
            case .interrupted: interrupted = true
            default: return nil
            }
            id = message.id
            fromUser = message.role == .user
            text = message.text
            files = message.attachments.map { File(id: $0.id, name: $0.name, mimeType: $0.mimeType, byteCount: $0.byteCount) }
            spoken = message.inputMode == .spoken
            createdAt = message.createdAt
        }

        var message: ChatMessage {
            ChatMessage(
                id: id, role: fromUser ? .user : .assistant, text: text,
                attachments: files.map { Attachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, byteCount: $0.byteCount) },
                status: interrupted ? .interrupted : .delivered, inputMode: spoken ? .spoken : .typed, createdAt: createdAt)
        }
    }

    private struct Approval: Codable {
        var id: String
        var kind: String
        var title: String
        var detail: String
        /// "approved", "denied" or "expired".
        var outcome: String
        var requestedAt: Date

        init?(_ approval: ApprovalRequest) {
            switch approval.state {
            case .decided(let decision): outcome = decision.rawValue
            case .expired: outcome = "expired"
            case .pending, .submitting: return nil
            }
            id = approval.id
            kind = approval.kind.rawValue
            title = approval.title
            detail = approval.detail
            requestedAt = approval.requestedAt
        }

        var request: ApprovalRequest? {
            guard let kind = ApprovalRequest.Kind(rawValue: kind) else { return nil }
            let state: ApprovalRequest.State = ApprovalRequest.Decision(rawValue: outcome).map { .decided($0) } ?? .expired
            return ApprovalRequest(id: id, kind: kind, title: title, detail: detail, state: state, requestedAt: requestedAt)
        }
    }
}
