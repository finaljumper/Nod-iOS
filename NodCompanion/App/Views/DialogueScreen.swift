import NodCore
import SwiftUI
import UIKit

/// Hands-free conversation: the app listens all the time, sends what the user says, and
/// speaks the reply. Talking over a reply stops it.
///
/// Functional layer (glass): the navigation bar (system) and the two buttons at the bottom.
/// Content layer (no glass): the state indicator, the texts and the approval card.
struct DialogueScreen: View {
    @Environment(ConversationModel.self) private var conversation
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    StateIndicator(state: conversation.dialogueState)
                        .padding(.top, 32)
                    if let problem = unavailableReason {
                        ContentUnavailableView {
                            Label("Cannot listen", systemImage: "mic.slash")
                        } description: {
                            Text(problem)
                        }
                    } else {
                        texts
                    }
                    ForEach(conversation.pendingApprovals) { approval in
                        ApprovalCard(approval: approval)
                    }
                }
                .padding(.horizontal)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .navigationTitle("Talk to Nod")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Language you speak", selection: $app.spokenLanguage) {
                        ForEach(app.spokenLanguages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .safeAreaInset(edge: .bottom) {
                controls
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            conversation.startDialogue()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            conversation.stopDialogue()
        }
        .onChange(of: app.spokenLanguage) { _, _ in
            // The recogniser works in one language at a time: start again in the new one.
            conversation.stopDialogue()
            conversation.startDialogue()
        }
    }

    private var unavailableReason: String? {
        guard !conversation.isDialogueActive else { return nil }
        if case .unavailable(let reason) = conversation.speechInputAvailability { return reason }
        return conversation.activity.last(where: { $0.kind == .problem && $0.title == "Listening failed" })?.detail
    }

    @ViewBuilder private var texts: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = conversation.speechInputNotice {
                Label(notice, systemImage: "arrow.down.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if conversation.dialogueState == .hearing {
                Text(conversation.liveTranscript.isEmpty ? "…" : conversation.liveTranscript)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else if let said = lastMessage(.user) {
                Text(said.text)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if conversation.dialogueState != .hearing, let reply = lastReply {
                MarkdownText(text: reply, isLarge: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: conversation.liveTranscript)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                if conversation.phase.isBusy || conversation.isSpeaking {
                    Button {
                        conversation.interrupt()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glass)
                    .tint(.primary)
                }
                Button {
                    dismiss()
                } label: {
                    Label("End", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            }
        }
        .animation(.snappy, value: conversation.phase.isBusy || conversation.isSpeaking)
    }

    private func lastMessage(_ role: ChatMessage.Role) -> ChatMessage? {
        for item in conversation.items.reversed() {
            if case .message(let message) = item, message.role == role { return message }
        }
        return nil
    }

    /// Everything Nod has said since the user last spoke.
    private var lastReply: String? {
        var parts: [String] = []
        for item in conversation.items.reversed() {
            guard case .message(let message) = item else { continue }
            if message.role == .user { break }
            parts.insert(message.text, at: 0)
        }
        // A blank line between messages, so that a list in one does not run into the next.
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

/// A large symbol and one word for what is going on.
private struct StateIndicator: View {
    let state: ConversationModel.DialogueState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 72))
                .symbolEffect(.variableColor.iterative, isActive: state == .listening || state == .speaking)
                .symbolEffect(.pulse, isActive: state == .hearing || state == .thinking)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(state == .hearing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(height: 96)
                .accessibilityHidden(true)
            Text(label)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .off: return "mic.slash"
        case .listening: return "waveform"
        case .hearing: return "mic.fill"
        case .thinking: return "ellipsis"
        case .waitingForApproval: return "hand.raised.fill"
        case .speaking: return "speaker.wave.3.fill"
        }
    }

    private var label: String {
        switch state {
        case .off: return "Not listening"
        case .listening: return "Listening"
        case .hearing: return "Hearing you"
        case .thinking: return "Thinking"
        case .waitingForApproval: return "Waiting for your approval"
        case .speaking: return "Speaking"
        }
    }
}
