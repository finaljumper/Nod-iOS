import NodCore
import SwiftUI

/// The main screen: the conversation, what Nod is doing, and the composer.
///
/// Functional layer (glass): the navigation bar and its buttons (system), and the composer.
/// Content layer (no glass): messages, tool rows, approval cards and the status line.
struct ConversationScreen: View {
    @Environment(ConversationModel.self) private var conversation
    @Environment(AppState.self) private var app
    @State private var showsSettings = false
    @State private var showsActivity = false
    @State private var showsDialogue = false
    @State private var showsSetup = false
    /// The entries that were on screen before the latest change, and whether the conversation
    /// had been loaded by then: to tell a new message from a whole conversation arriving.
    @State private var settledIDs: [ConversationItem.ID] = []
    @State private var settledLoaded = false
    /// How many of the newest entries are on screen. Earlier ones are added on request.
    @State private var shownCount = ConversationScreen.page
    private static let page = 150
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ids = conversation.items.map(\.id)
        // Until Nod's record has been asked for, an empty conversation says nothing: neither
        // the welcome nor anything else is shown that the record would push aside a moment later.
        let isKnown = conversation.hasLoadedConversation || !ids.isEmpty
        NavigationStack {
            ScrollView {
                // Not a lazy stack: that one guesses the height of rows it has not drawn, and
                // with long and short messages mixed the guess put the end of the conversation
                // somewhere in empty space. With every row laid out the end is exactly known.
                // Only the newest entries are laid out, so that this stays cheap.
                VStack(alignment: .leading, spacing: 12) {
                    if isKnown {
                        if conversation.items.isEmpty {
                            WelcomeView { conversation.send($0) }
                        }
                        if conversation.items.count > shownCount {
                            Button("Show Earlier Messages") { shownCount += Self.page }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(conversation.items.suffix(shownCount)) { item in
                            Group {
                                switch item {
                                case .message(let message): MessageRow(message: message)
                                case .tool(let tool): ToolRow(tool: tool)
                                case .approval(let approval): ApprovalCard(approval: approval)
                                }
                            }
                            .transition(appearance(of: item))
                        }
                    }
                    StatusRow()
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .animation(isArrival(ids) ? (reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.25)) : nil, value: ids)
                .onChange(of: ids, initial: true) { _, new in settledIDs = new }
                .onChange(of: conversation.hasLoadedConversation, initial: true) { _, loaded in settledLoaded = loaded }
            }
            // The end of the conversation is what is shown, at the start and when it grows.
            .defaultScrollAnchor(.bottom)
            #if DEBUG
            // Development aid: with NOD_TRACE_LIST in the environment, where the list stands
            // is written to standard error. Numbers only, never what a message says.
            .onScrollGeometryChange(for: String.self) { geometry in
                "offset \(Int(geometry.contentOffset.y)) content \(Int(geometry.contentSize.height)) window \(Int(geometry.containerSize.height))"
            } action: { _, place in
                Self.trace("list \(place); \(conversation.items.count) entries, loaded \(conversation.hasLoadedConversation), \(conversation.connection)")
            }
            .onChange(of: ids.count, initial: true) { _, count in
                Self.trace("entries \(count), loaded \(conversation.hasLoadedConversation), \(conversation.connection)")
            }
            #endif
            // A new scroll view once the conversation is known, so that it starts at its end
            // instead of being moved there after it appeared.
            .id(isKnown)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Nod")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Activity", systemImage: "list.bullet.clipboard") { showsActivity = true }
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Composer { showsDialogue = true }
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            .sheet(isPresented: $showsSettings) { SettingsScreen() }
            .sheet(isPresented: $showsActivity) { ActivityScreen() }
            .fullScreenCover(isPresented: $showsDialogue) { DialogueScreen() }
            .sheet(isPresented: $showsSetup) { ConnectionSetupScreen(isWelcome: true) }
            // Without a connection the app starts with its setup.
            .task { if !app.isConnectedToNod { showsSetup = true } }
        }
    }

    #if DEBUG
    private static let tracesList = ProcessInfo.processInfo.environment["NOD_TRACE_LIST"] != nil
    private static func trace(_ text: @autoclosure () -> String) {
        guard tracesList else { return }
        FileHandle.standardError.write(Data("[list \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime))] \(text())\n".utf8))
    }
    #endif

    /// Whether the change to the list is a message or two arriving at its end in a
    /// conversation that was already on screen. Only that is animated. A whole conversation,
    /// as when Nod's record is loaded at launch, is simply there, and so is a row that Nod's
    /// record puts in the place of another.
    private func isArrival(_ ids: [ConversationItem.ID]) -> Bool {
        guard settledLoaded, ids.count > settledIDs.count, ids.count - settledIDs.count <= 2 else { return false }
        return ids.starts(with: settledIDs)
    }
}

extension ConversationScreen {
    /// New entries grow in from the side they belong to: the user's from the right, Nod's
    /// from the left. With Reduce Motion they only fade in.
    private func appearance(of item: ConversationItem) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        var fromUser = false
        if case .message(let message) = item { fromUser = message.role == .user }
        let arrival = AnyTransition.scale(scale: 0.85, anchor: fromUser ? .bottomTrailing : .bottomLeading)
            .combined(with: .opacity)
            .combined(with: .offset(y: 14))
        return .asymmetric(insertion: arrival, removal: .opacity)
    }
}

/// Shown before the first message: says what the app is connected to and, for the stand-in,
/// offers things to try.
private struct WelcomeView: View {
    @Environment(AppState.self) private var app
    let send: (String) -> Void

    private let suggestions = [
        "What is on my calendar today?",
        "Send an email to Alex about Friday",
        "Что у меня в календаре?",
        "오늘 일정 알려 줘",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let address = app.nodAddress, app.isConnectedToNod {
                Label("Nod", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.headline)
                Text("Connected to \(address.host() ?? address.absoluteString). What you say or type here goes to your Nod and is acted on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label("Demo assistant", systemImage: "testtube.2")
                    .font(.headline)
                Text("Nod is not connected yet. A stand-in inside the app answers, so nothing leaves this device and nothing is really sent. Set up the connection in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { send(suggestion) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line under the conversation saying what is going on right now.
private struct StatusRow: View {
    @Environment(ConversationModel.self) private var conversation

    var body: some View {
        if let status {
            HStack(spacing: 8) {
                if status.showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: status.symbol)
                        .symbolEffect(.variableColor.iterative, isActive: status.animates)
                }
                Text(status.text)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private struct Status {
        var text: String
        var symbol = "circle"
        var showsProgress = false
        var animates = false
    }

    private var status: Status? {
        switch conversation.connection {
        case .waitingToRetry(let attempt, let seconds):
            return Status(text: "Disconnected. Trying again in \(Int(seconds.rounded())) s (attempt \(attempt + 1)).", symbol: "wifi.slash")
        case .connecting:
            return Status(text: "Connecting…", showsProgress: true)
        case .disconnected where conversation.phase.isBusy:
            return Status(text: "Disconnected.", symbol: "wifi.slash")
        case .refused(let reason):
            return Status(text: reason, symbol: "exclamationmark.triangle")
        default:
            break
        }
        switch conversation.phase {
        case .sending: return Status(text: "Sending…", showsProgress: true)
        case .thinking: return Status(text: "Nod is thinking…", showsProgress: true)
        case .usingTool(let name): return Status(text: "Using \(name)…", showsProgress: true)
        case .waitingForApproval: return Status(text: "Waiting for your approval.", symbol: "hand.raised")
        case .responding, .idle:
            return conversation.isSpeaking ? Status(text: "Speaking", symbol: "waveform", animates: true) : nil
        }
    }
}
