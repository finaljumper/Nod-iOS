import SwiftUI

@main
struct NodCompanionApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ConversationScreen()
                .environment(app)
                // The conversation is replaced when the connection to Nod is set up or removed.
                .environment(app.conversation)
                .task { app.conversation.start() }
                #if DEBUG
                .task { await playSampleIfAsked() }
                #endif
        }
    }

    #if DEBUG
    /// Development aid: with `NOD_PLAY_SAMPLE` set to a language code in the environment, the
    /// app speaks that language's sample after launch and writes to standard error whether it
    /// is speaking. Together with `NOD_AUDIO_TRACE` it shows what a device does with the voice
    /// without anyone touching it.
    private func playSampleIfAsked() async {
        guard let language = ProcessInfo.processInfo.environment["NOD_PLAY_SAMPLE"] else { return }
        func note(_ text: String) { FileHandle.standardError.write(Data("[app] \(text)\n".utf8)) }
        try? await Task.sleep(for: .seconds(3))
        note("voice=\(app.voiceEngine.rawValue) volume=\(app.volume.volume)")
        app.playSample(language: language)
        for second in 1...6 {
            try? await Task.sleep(for: .seconds(1))
            note("t+\(second)s speaking=\(app.conversation.isSpeaking) problem=\(app.voiceProblem ?? "none")")
        }
    }
    #endif
}
