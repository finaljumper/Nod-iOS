import NodCore
import PhotosUI
import SwiftUI

/// The card at the bottom: the message on top, and below it a row with attach on the left and
/// dictation and the main button on the right. The main button opens the hands-free dialogue
/// while the card is empty, sends once there is something to send, and stops Nod while it works.
///
/// Functional layer: the card is one piece of glass. Everything on it is a fill or a plain
/// symbol, not more glass. Pinned with safeAreaInset rather than safeAreaBar, because
/// @FocusState does not work inside safeAreaBar on iOS 26.1.
struct Composer: View {
    /// Opens the hands-free dialogue.
    var onTalk: () -> Void

    @Environment(ConversationModel.self) private var conversation
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var isLoadingAttachments = false
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var problem: String?
    @State private var problemTitle = ""
    @FocusState private var fieldFocused: Bool

    private var canStop: Bool { conversation.phase.isBusy || conversation.isSpeaking }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if conversation.isListening {
                listening
            } else {
                if !attachments.isEmpty || isLoadingAttachments {
                    pendingAttachments
                }
                TextField("Ask Nod", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($fieldFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            }
            controls
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .contentShape(.rect)
        .onTapGesture { if !conversation.isListening { fieldFocused = true } }
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .animation(.snappy, value: conversation.isListening)
        .animation(.snappy, value: mainAction)
        .animation(.snappy, value: canStop && canSend)
        .animation(.snappy, value: attachments)
        .photosPicker(isPresented: $showsPhotos, selection: $pickedPhotos, maxSelectionCount: 6, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            load(items)
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                do { attachments.append(try AttachmentLoader.file(url)) } catch { report(error) }
            }
        }
        .alert(problemTitle, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: The row of buttons

    private var controls: some View {
        HStack(spacing: 4) {
            if conversation.isListening {
                symbolButton("xmark", label: "Cancel Dictation") { conversation.cancelListening() }
            } else {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotos = true }
                    Button("Choose Files", systemImage: "folder") { showsFiles = true }
                } label: {
                    symbol("plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Photos or Files")
            }

            Spacer(minLength: 0)

            if !conversation.isListening {
                symbolButton("mic", label: "Dictate a Message", action: listen)
                if canStop && canSend {
                    // The main button sends now; stopping stays within reach.
                    symbolButton("stop.circle", label: "Stop Nod") { conversation.interrupt() }
                        .foregroundStyle(.red)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            mainButton
        }
    }

    /// What the main button does right now.
    private enum MainAction: Equatable {
        case sendDictation, send, stop, talk
    }

    private var mainAction: MainAction {
        if conversation.isListening { return .sendDictation }
        if canSend { return .send }
        return canStop ? .stop : .talk
    }

    private var mainButton: some View {
        let action = mainAction
        return Button {
            switch action {
            case .sendDictation: conversation.finishListening()
            case .send: send()
            case .stop: conversation.interrupt()
            case .talk: onTalk()
            }
        } label: {
            Image(systemName: Self.symbolName(for: action))
                .contentTransition(.symbolEffect(.replace))
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                // A fill on the card's glass, not more glass.
                .background(action == .stop ? AnyShapeStyle(.red) : AnyShapeStyle(.tint), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.label(for: action))
    }

    private static func symbolName(for action: MainAction) -> String {
        switch action {
        case .sendDictation, .send: return "arrow.up"
        case .stop: return "stop.fill"
        case .talk: return "waveform"
        }
    }

    private static func label(for action: MainAction) -> String {
        switch action {
        case .sendDictation: return "Send what I said"
        case .send: return "Send"
        case .stop: return "Stop Nod"
        case .talk: return "Talk with Nod"
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3.weight(.medium))
            .frame(width: 36, height: 36)
            .contentShape(.rect)
    }

    private func symbolButton(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { symbol(name) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    // MARK: What is in the card

    private var listening: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative)
                .accessibilityHidden(true)
            Text(conversation.liveTranscript.isEmpty ? "Listening…" : conversation.liveTranscript)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var pendingAttachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentView(attachment: attachment, side: 64)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(.black.opacity(0.6), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                        .transition(.scale.combined(with: .opacity))
                }
                if isLoadingAttachments {
                    ProgressView()
                        .frame(width: 64, height: 64)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 4)
    }

    // MARK: Actions

    private func load(_ items: [PhotosPickerItem]) {
        isLoadingAttachments = true
        Task {
            for item in items {
                do {
                    let number = attachments.filter(\.isImage).count + 1
                    attachments.append(try await AttachmentLoader.photo(item, number: number))
                } catch {
                    report(error)
                }
            }
            isLoadingAttachments = false
        }
    }

    private func report(_ error: any Error) {
        problemTitle = "Cannot attach"
        problem = (error as? AttachmentLoader.Problem)?.message ?? "A file could not be read."
    }

    private func send() {
        guard canSend else { return }
        let text = draft, files = attachments
        draft = ""
        attachments = []
        conversation.send(text, attachments: files)
        // The keyboard's Send key ends editing; keep the field ready for the next message.
        fieldFocused = true
    }

    private func listen() {
        if case .unavailable(let reason) = conversation.speechInputAvailability {
            problemTitle = "Cannot listen"
            problem = reason
            return
        }
        fieldFocused = false
        conversation.startListening()
    }
}
