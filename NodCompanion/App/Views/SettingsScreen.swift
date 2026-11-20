import NodCore
import NodSpeech
import SwiftUI

/// Settings, arranged like the system's: a short list of areas, each with a page of its own.
struct SettingsScreen: View {
    @Environment(AppState.self) private var app
    @Environment(ConversationModel.self) private var conversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ConnectionSettings()
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(symbol: app.isConnectedToNod ? "bubble.left.and.text.bubble.right.fill" : "testtube.2", color: app.isConnectedToNod ? .blue : .gray, side: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.isConnectedToNod ? "Nod" : "Demo Assistant").font(.title3.weight(.semibold))
                                Text(connectionSummary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    NavigationLink {
                        VoiceSettings()
                    } label: {
                        SettingsRow(title: "Voice", symbol: "speaker.wave.2.fill", color: .pink, value: app.speaksReplies ? app.voiceEngine.name : "Off")
                    }
                    NavigationLink {
                        ListeningSettings()
                    } label: {
                        SettingsRow(title: "Listening", symbol: "mic.fill", color: .orange, value: app.recogniser.name)
                    }
                }

                Section {
                    NavigationLink {
                        DeveloperSettings()
                    } label: {
                        SettingsRow(title: "Developer", symbol: "hammer.fill", color: .gray, value: app.simulatedMicrophone ? "Simulated Microphone" : nil)
                    }
                    NavigationLink {
                        AboutSettings()
                    } label: {
                        SettingsRow(title: "About", symbol: "info", color: .blue, value: nil)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private var connectionSummary: String {
        guard let address = app.nodAddress, app.isConnectedToNod else {
            return "Not connected. Answers come from a stand-in inside the app."
        }
        let host = address.host() ?? address.absoluteString
        switch conversation.connection {
        case .connected: return "Connected to \(host)"
        case .connecting: return "Connecting to \(host)…"
        case .waitingToRetry: return "Cannot reach \(host). Trying again."
        case .refused(let reason): return reason
        case .disconnected: return host
        }
    }
}

// MARK: Parts shared by the pages

/// A symbol on a coloured rounded square, as in the system's Settings.
private struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var side: CGFloat = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.24))
            .accessibilityHidden(true)
    }
}

private struct SettingsRow: View {
    let title: String
    let symbol: String
    let color: Color
    let value: String?

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Plays the sample sentence of a language, and stops it when tapped again.
private struct SampleButton: View {
    @Environment(AppState.self) private var app
    @Environment(ConversationModel.self) private var conversation
    let title: String
    let language: String

    private var isPlaying: Bool { conversation.isSpeaking && app.sampleLanguage == language }

    var body: some View {
        Button {
            if isPlaying { app.stopSample() } else { app.playSample(language: language) }
        } label: {
            Label(isPlaying ? "Stop" : title, systemImage: isPlaying ? "stop.circle.fill" : "play.circle.fill")
        }
    }
}

// MARK: Connection

private struct ConnectionSettings: View {
    @Environment(AppState.self) private var app
    @Environment(ConversationModel.self) private var conversation
    @State private var showsSetup = false
    @State private var confirmsRemoval = false

    var body: some View {
        List {
            if let address = app.nodAddress, app.isConnectedToNod {
                Section {
                    LabeledContent("Status", value: status)
                    LabeledContent("Address", value: address.absoluteString)
                    LabeledContent("Key", value: "In the Keychain")
                } footer: {
                    Text("What you say or type goes to your Nod over HTTPS, with the key from this device's Keychain. Speech is recognised and replies are spoken on this device.")
                }
                Section {
                    Button("Change Address or Key") { showsSetup = true }
                    Button("Remove Connection", role: .destructive) { confirmsRemoval = true }
                        .confirmationDialog("Remove the address and the key from this device?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                            Button("Remove Connection", role: .destructive) { app.removeConnection() }
                        }
                }
            } else {
                Section {
                    LabeledContent("Answers Come From", value: "Demo assistant")
                } footer: {
                    Text("A stand-in inside the app answers, so nothing leaves this device and nothing is really sent.")
                }
                Section {
                    Button("Set Up Connection") { showsSetup = true }
                } footer: {
                    Text("You need the HTTPS address at which you open Nod, and its authentication token (NOD_AUTH_TOKEN). Both are checked against Nod before anything is saved.")
                }
            }
        }
        .navigationTitle("Nod")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsSetup) {
            ConnectionSetupScreen(currentAddress: app.nodAddress)
        }
    }

    private var status: String {
        switch conversation.connection {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .waitingToRetry(_, let seconds): return "Trying again in \(Int(seconds.rounded())) s"
        case .refused: return "Refused"
        case .disconnected: return "Not connected"
        }
    }
}

// MARK: Voice

private struct VoiceSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
            if app.volume.isLow {
                Section {
                    Label(
                        "The volume is at \(Int((app.volume.volume * 100).rounded())) %. Turn it up with the volume buttons to hear the voice.",
                        systemImage: app.volume.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill"
                    )
                    .font(.subheadline)
                }
            }

            Section {
                Toggle("Speak Replies", isOn: $app.speaksReplies)
            } footer: {
                Text("In the hands-free dialogue replies are always spoken.")
            }

            Section {
                Picker("Voice", selection: $app.voiceEngine) {
                    ForEach(app.availableVoiceEngines) { engine in
                        Text(engine.name).tag(engine)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Voice")
            } footer: {
                Text(voiceFootnote)
            }

            Section("Speed") {
                Slider(value: $app.speechRate, in: 0.7...1.3, step: 0.05) {
                    Text("Speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise").accessibilityLabel("Slower")
                } maximumValueLabel: {
                    Image(systemName: "hare").accessibilityLabel("Faster")
                }
            }

            switch app.voiceEngine {
            case .supertonic:
                supertonicSection
            case .phonon:
                Section {
                    Picker("Speaker", selection: $app.phononVoice) {
                        ForEach(PhononVoice.voices, id: \.self) { voice in
                            Text(Self.phononName(voice)).tag(voice)
                        }
                    }
                    LabeledContent("Model", value: phononStatusText)
                    SampleButton(title: "Play English Sample", language: "en")
                } header: {
                    Text("Phonon")
                } footer: {
                    Text("Phonon reads English only. Its model, about 170 MB, is downloaded the first time Phonon is chosen, and English replies wait for it. If it cannot be loaded, the next voice speaks instead.")
                }
                if app.isSupertonicAvailable { supertonicSection }
            case .system:
                ForEach(AppState.languages, id: \.code) { language in
                    SystemVoiceSection(code: language.code, name: language.name)
                }
            }

            if let problem = app.voiceProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } footer: {
                    Text("The last sentence could not be spoken by the chosen voice; another one stepped in.")
                }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.volume.refresh() }
        .onDisappear { app.stopSample() }
    }

    @ViewBuilder private var supertonicSection: some View {
        @Bindable var app = app
        Section {
            Picker("Speaker", selection: $app.supertonicVoice) {
                ForEach(0..<10, id: \.self) { index in
                    Text("Voice \(index + 1)").tag(index)
                }
            }
            if app.voiceEngine == .supertonic {
                SampleButton(title: "Play English Sample", language: "en")
            }
            SampleButton(title: "Play Korean Sample", language: "ko")
        } header: {
            Text("Supertonic 3")
        } footer: {
            Text(app.voiceEngine == .phonon ? "Reads Korean and everything else that Phonon does not." : "The model has ten built-in speakers.")
        }
    }

    private var voiceFootnote: String {
        switch app.voiceEngine {
        case .supertonic:
            return "Replies are spoken on this device. Supertonic 3 is a neural voice that reads English and Korean."
        case .phonon:
            return app.isSupertonicAvailable
                ? "Replies are spoken on this device. Phonon reads English; Korean and other languages are read by Supertonic 3."
                : "Replies are spoken on this device. Phonon reads English; other languages are read by the system voices."
        case .system:
            return app.isSupertonicAvailable
                ? "Replies are spoken on this device with the system's voices, which need no extra model."
                : "The Supertonic 3 model was not included in this build. Run Scripts/fetch-supertonic.sh and build again to add it."
        }
    }

    private var phononStatusText: String {
        switch app.phononStatus {
        case .idle: return "Not loaded"
        case .preparing: return "Downloading and loading…"
        case .ready: return "Ready"
        case .failed: return "Could not be loaded"
        }
    }

    private static func phononName(_ voice: String) -> String {
        switch voice {
        case "default": return "Default"
        default:
            let parts = voice.split(separator: "_")
            let accent = parts.count > 1 && parts[1] == "gb" ? "British" : "American"
            return "\(parts.last.map(String.init) ?? voice) (\(accent))"
        }
    }
}

/// The system voice for one language, with a button to hear it.
private struct SystemVoiceSection: View {
    @Environment(AppState.self) private var app
    let code: String
    let name: String

    var body: some View {
        let voices = VoiceCatalog.voices(for: code)
        Section {
            if voices.isEmpty {
                Label("No \(name) voice is installed on this device.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Voice", selection: selection) {
                    Text("Default").tag("")
                    ForEach(voices) { voice in
                        Text("\(voice.name) · \(voice.quality.label) · \(voice.locale)").tag(voice.id)
                    }
                }
                SampleButton(title: "Play Sample", language: code)
            }
        } header: {
            Text(name)
        } footer: {
            if code == AppState.languages.last?.code {
                Text("Better-sounding Enhanced and Premium voices can be downloaded in the system's accessibility settings for spoken content. They then appear in these lists.")
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { app.voiceIdentifiers[code] ?? "" },
            set: { app.voiceIdentifiers[code] = $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: Listening

private struct ListeningSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                Picker("Recogniser", selection: $app.recogniserID) {
                    ForEach(RecognitionEngine.all) { engine in
                        Text(engine.name).tag(engine.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Recogniser")
            } footer: {
                Text(recogniserFootnote)
            }

            Section {
                Picker("Language You Speak", selection: $app.spokenLanguage) {
                    ForEach(app.spokenLanguages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            } footer: {
                Text("Speech is recognised on this device, in one language at a time.")
            }

            Section {
                Toggle("More Live Text", isOn: $app.fastRecognition)
            } footer: {
                Text("Shows your words sooner while you are still talking, but rougher. Only Apple Speech has this.")
            }

            Section {
                Toggle("Interrupt by Talking", isOn: $app.voiceInterruption)
            } header: {
                Text("Dialogue")
            } footer: {
                Text(app.voiceInterruption
                    ? "Talking over a reply silences it. If the app keeps hearing its own voice, switch this off."
                    : "The app does not listen while it speaks; use Stop to interrupt it.")
            }
        }
        .navigationTitle("Listening")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var recogniserFootnote: String {
        var text = app.recogniser.summary
        if !app.simulatedMicrophone, case .unavailable(let reason) = app.liveInput.availability {
            text += " " + reason
        }
        return text
    }
}

// MARK: Developer and About

private struct DeveloperSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                Toggle("Simulated Microphone", isOn: $app.simulatedMicrophone)
            } footer: {
                Text("A development aid that “hears” a few fixed phrases instead of the microphone. It makes the dictation and the dialogue usable in the iOS Simulator, which has no speech recognition.")
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutSettings: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: Self.version)
            } footer: {
                Text("Nod Voice Companion is a voice and text client for a self-hosted Nod. Speech recognition and the voice run on this device; reasoning, memory and tools stay with Nod.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
