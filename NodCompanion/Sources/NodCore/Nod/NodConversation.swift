import Foundation

/// Turns the conversation as Nod holds it into what the app shows.
public enum NodConversation {
    /// The identifier a row is shown under. Nod's identifiers are UUIDs; one that is not gets
    /// a UUID made from its text, the same one every time, so that loading the conversation
    /// again does not turn every row into a new one.
    static func identifier(for id: String) -> UUID {
        if let uuid = UUID(uuidString: id) { return uuid }
        // FNV-1a, twice with different starting values, for 128 bits.
        func hash(_ basis: UInt64) -> UInt64 {
            id.utf8.reduce(basis) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        }
        let high = hash(0xcbf2_9ce4_8422_2325), low = hash(0x8422_2325_cbf2_9ce4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> (8 * UInt64(7 - index)))
            bytes[8 + index] = UInt8(truncatingIfNeeded: low >> (8 * UInt64(7 - index)))
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func items(from state: NodAPI.State) -> [ConversationItem] {
        var items: [ConversationItem] = []
        for message in state.messages {
            let date = message.createdAt.flatMap(date(from:)) ?? Date()
            let text = (message.displayText ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let attachments = (message.attachments ?? []).map { stored in
                Attachment(
                    id: stored.id.map(identifier(for:)) ?? UUID(),
                    name: stored.name ?? "File",
                    mimeType: stored.mimeType ?? "application/octet-stream",
                    byteCount: stored.size
                )
            }
            if !text.isEmpty || !attachments.isEmpty {
                items.append(.message(ChatMessage(
                    id: identifier(for: message.id),
                    role: message.role == "user" ? .user : .assistant,
                    text: text,
                    attachments: attachments,
                    status: .delivered,
                    createdAt: date
                )))
            }
            if let approval = message.approval {
                items.append(.approval(self.approval(approval, requestedAt: date)))
            }
        }
        return items
    }

    public static func approval(_ approval: NodAPI.Approval, requestedAt: Date = Date()) -> ApprovalRequest {
        var lines: [String] = []
        if let app = approval.app, !app.isEmpty { lines.append(app) }
        for field in approval.fields ?? [] { lines.append("\(field.label): \(field.value)") }
        if let body = approval.body, !body.isEmpty { lines.append(body) }

        let state: ApprovalRequest.State
        var problem = approval.failure
        switch approval.state {
        case "pending": state = .pending
        case "working": state = .submitting(.approved)
        case "done": state = .decided(.approved)
        case "declined": state = .decided(.denied)
        case "uncertain":
            state = .decided(.approved)
            problem = problem ?? "Nod does not know whether this action was carried out."
        default: state = .expired
        }
        return ApprovalRequest(
            id: approval.id,
            kind: .other,
            title: approval.title,
            detail: lines.joined(separator: "\n"),
            state: state,
            problem: problem,
            requestedAt: requestedAt
        )
    }

    /// Nod writes times as ISO 8601 with fractions of a second.
    static func date(from text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// The reply Nod has stored for a turn: its assistant messages, in order.
    static func reply(of turnID: String, in state: NodAPI.State) -> String {
        state.messages
            .filter { $0.role == "assistant" && $0.turnId?.lowercased() == turnID }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
