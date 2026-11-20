import NodCore
import SwiftUI

/// The history of what Nod did and what the user decided, newest first.
struct ActivityScreen: View {
    @Environment(ConversationModel.self) private var conversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if conversation.activity.isEmpty {
                    ContentUnavailableView(
                        "Nothing yet",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Tools Nod uses and the approvals you give or refuse are listed here.")
                    )
                } else {
                    List(conversation.activity.reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: symbol(entry.kind))
                                .foregroundStyle(color(entry.kind))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                Text(label(entry.kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let detail = entry.detail {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(entry.date, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func label(_ kind: ActivityEntry.Kind) -> String {
        switch kind {
        case .tool: return "Tool"
        case .approvalRequested: return "Approval requested"
        case .approved: return "You approved"
        case .denied: return "You denied"
        case .interrupted: return "Interrupted"
        case .connection: return "Connection"
        case .problem: return "Problem"
        }
    }

    private func symbol(_ kind: ActivityEntry.Kind) -> String {
        switch kind {
        case .tool: return "wrench.and.screwdriver"
        case .approvalRequested: return "hand.raised"
        case .approved: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .interrupted: return "stop.circle"
        case .connection: return "wifi"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ kind: ActivityEntry.Kind) -> Color {
        switch kind {
        case .approved: return .green
        case .problem: return .orange
        case .approvalRequested: return .orange
        default: return .secondary
        }
    }
}
