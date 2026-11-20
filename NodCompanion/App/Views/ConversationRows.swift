import NodCore
import SwiftUI

struct MessageRow: View {
    @Environment(ConversationModel.self) private var conversation
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if !message.attachments.isEmpty {
                VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        AttachmentView(attachment: attachment)
                    }
                }
            }
            if !message.text.isEmpty {
                HStack {
                    if isUser { Spacer(minLength: 48) }
                    Group {
                        // What Nod writes is Markdown; what the user typed is shown as typed.
                        if isUser { Text(message.text) } else { MarkdownText(text: message.text) }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 18))
                    .foregroundStyle(isUser ? .white : .primary)
                    if !isUser { Spacer(minLength: 24) }
                }
            }
            footnote
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder private var footnote: some View {
        switch message.status {
        case .sending:
            note("Sending…")
        case .interrupted:
            note(isUser ? "Not sent" : "Stopped")
        case .failed(let reason):
            problem(reason, action: "Try Again")
        case .uncertain(let reason):
            problem(reason, action: "Send Again")
        case .delivered where isUser && message.inputMode == .spoken:
            Label("Spoken", systemImage: "mic.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .delivered, .streaming:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func problem(_ reason: String, action: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
            Button(action) { conversation.retry(messageID: message.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

struct ToolRow: View {
    let tool: ToolActivity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch tool.state {
                case .running: ProgressView().controlSize(.small)
                case .succeeded: Image(systemName: "checkmark.circle")
                case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red)
                case .cancelled: Image(systemName: "stop.circle")
                case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name).font(.footnote.monospaced())
                Text(caption).font(.caption)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        switch tool.state {
        case .running: return tool.detail ?? "Running"
        case .succeeded: return tool.summary ?? tool.detail ?? "Done"
        case .failed: return tool.summary ?? "Failed"
        case .cancelled: return "Stopped by you"
        case .unknown: return "Connection lost. It may or may not have finished."
        }
    }
}

/// A sensitive action waiting for the user's decision. Content layer: a plain card whose two
/// buttons are the only way the action can go ahead.
struct ApprovalCard: View {
    @Environment(ConversationModel.self) private var conversation
    let approval: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.title, systemImage: symbol)
                .font(.headline)
            Text(approval.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let problem = approval.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            outcome
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(approval.isPending ? AnyShapeStyle(.orange) : AnyShapeStyle(.separator), lineWidth: 1)
        }
    }

    @ViewBuilder private var outcome: some View {
        switch approval.state {
        case .pending:
            HStack(spacing: 12) {
                Button("Deny", role: .cancel) { decide(.denied) }
                    .buttonStyle(.bordered)
                Button("Approve") { decide(.approved) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .submitting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending your decision…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .decided(.approved):
            Label("Approved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline.weight(.semibold))
        case .decided(.denied):
            Label("Denied", systemImage: "xmark.circle.fill").foregroundStyle(.secondary).font(.subheadline.weight(.semibold))
        case .expired:
            Label("Closed without a decision. Nothing was done.", systemImage: "minus.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func decide(_ decision: ApprovalRequest.Decision) {
        Task { await conversation.decide(approvalID: approval.id, decision) }
    }

    private var symbol: String {
        switch approval.kind {
        case .email: return "envelope"
        case .purchase: return "cart"
        case .cancellation: return "xmark.bin"
        case .financial: return "banknote"
        case .submission: return "doc.badge.arrow.up"
        case .other: return "hand.raised"
        }
    }
}
