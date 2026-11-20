import Foundation
import NodCore
import NodSpeech
import Observation

/// Sends speech to whichever voice is selected, so the voice can be changed while the app runs.
@MainActor
final class VoiceRouter: SpeechOutput {
    var onSpeakingChanged: (@MainActor @Sendable (Bool) -> Void)?

    var active: any SpeechOutput {
        didSet {
            oldValue.stop()
            oldValue.onSpeakingChanged = nil
            connect()
        }
    }

    init(active: any SpeechOutput) {
        self.active = active
        connect()
    }

    private func connect() {
        active.onSpeakingChanged = { [weak self] speaking in self?.onSpeakingChanged?(speaking) }
    }

    func speak(_ segment: SpeechSegment) { active.speak(segment) }
    func stop() { active.stop() }
    func pause() { active.pause() }
    func resume() { active.resume() }
}

/// The app's long-lived objects and the settings that are remembered between launches.
@MainActor
@Observable
final class AppState {
    enum VoiceEngine: String, CaseIterable, Identifiable {
        case supertonic, phonon, system
        var id: String { rawValue }

        var name: String {
            switch self {
            case .supertonic: return "Supertonic 3"
            case .phonon: return "Phonon"
            case .system: return "System Voices"
            }
        }
    }

    /// Languages with a system voice to choose, a name for Settings and a sentence for trying a voice.
    static let languages: [(code: String, name: String, sample: String)] = [
        ("en", "English", "Hello, this is how I sound."),
        ("ko", "Korean", "안녕하세요, 제 목소리는 이렇게 들립니다."),
        ("ru", "Russian", "Здравствуйте, так звучит мой голос."),
    ]

    /// Languages the user can speak to Nod in. Which of them a recogniser offers is its own matter.
    static let spokenLanguageNames = ["en": "English", "ko": "한국어"]

    let systemSpeech = SystemSpeechOutput()
    /// Speaks with the neural voices; which ones depends on the chosen voice.
    let neuralSpeech = RenderedSpeechOutput()
    /// Nil when the Supertonic model was not bundled into this build.
    let supertonic: SupertonicSynthesizer?
    let phonon = PhononVoice()
    let liveInput = LiveSpeechInput()
    let volume = VolumeMonitor()
    /// The conversation with whatever answers: Nod when a connection is set up, otherwise the
    /// stand-in inside the app. It is replaced when the connection is set up or removed.
    private(set) var conversation: ConversationModel
    private let voice: VoiceRouter

    var voiceEngine: VoiceEngine {
        didSet {
            defaults.set(voiceEngine.rawValue, forKey: Key.voiceEngine)
            applyVoiceEngine()
        }
    }

    /// Which of Supertonic's ten voices speaks, 0 to 9.
    var supertonicVoice: Int {
        didSet {
            defaults.set(supertonicVoice, forKey: Key.supertonicVoice)
            applyVoices()
        }
    }

    /// Which of Phonon's speakers is used, by its name in the model.
    var phononVoice: String {
        didSet {
            defaults.set(phononVoice, forKey: Key.phononVoice)
            phonon.voice = phononVoice
        }
    }

    /// The recogniser that turns speech into text.
    var recogniserID: String {
        didSet {
            defaults.set(recogniserID, forKey: Key.recogniser)
            conversation.stopDialogue()
            conversation.cancelListening()
            liveInput.engine = recogniser
            // A recogniser that does not know the current language starts with its first one.
            if !recogniser.languages.contains(spokenLanguage) { spokenLanguage = recogniser.languages.first ?? "en" }
        }
    }

    /// Where Nod is, once the user has set the connection up.
    private(set) var nodAddress: URL?
    /// Whether a key for Nod is in the Keychain.
    private(set) var hasNodKey = false
    private let nodKey = KeychainStore()

    /// Whether replies come from Nod and not from the stand-in inside the app.
    var isConnectedToNod: Bool { nodAddress != nil && hasNodKey }

    /// Saves the address and the key, and talks to Nod from now on. The key goes to the
    /// Keychain, never to the settings. Call this after both were checked against Nod.
    func saveConnection(address: URL, key: String) throws {
        try nodKey.save(key)
        // Another address or key can be another conversation.
        Self.conversationStore.remove()
        defaults.set(address.absoluteString, forKey: Key.nodAddress)
        nodAddress = address
        hasNodKey = true
        replaceConversation()
    }

    /// Forgets the address and the key and goes back to the stand-in.
    func removeConnection() {
        nodKey.remove()
        Self.conversationStore.remove()
        defaults.removeObject(forKey: Key.nodAddress)
        nodAddress = nil
        hasNodKey = false
        replaceConversation()
    }

    private func replaceConversation() {
        conversation.shutDown()
        conversation = Self.makeConversation(
            address: nodAddress,
            key: nodKey.read(),
            voice: voice,
            speechInput: simulatedMicrophone ? ScriptedSpeechInput() : liveInput
        )
        conversation.speaksReplies = speaksReplies
        conversation.listeningLanguages = [spokenLanguage]
        conversation.start()
    }

    private static func makeConversation(address: URL?, key: String?, voice: VoiceRouter, speechInput: any SpeechInput) -> ConversationModel {
        let transport: any NodTransport
        var store: ConversationStore?
        if let address, let key, !key.isEmpty {
            transport = NodHTTPTransport(client: NodClient(baseURL: address, key: key))
            store = conversationStore
        } else {
            transport = DemoTransport()
        }
        return ConversationModel(transport: transport, speech: voice, speechInput: speechInput, store: store)
    }

    /// The conversation with Nod as it was last shown, kept in the app's own folder so that
    /// the app opens with it. Removed together with the connection.
    private static let conversationStore = ConversationStore(
        file: URL.applicationSupportDirectory.appending(path: "Conversation/conversation.json"))

    /// Whether Phonon's model is on the device and loaded.
    private(set) var phononStatus: PhononVoice.State = .idle

    var recogniser: RecognitionEngine { RecognitionEngine.engine(id: recogniserID) }

    /// The languages the current recogniser lets the user speak, with their names.
    var spokenLanguages: [(code: String, name: String)] {
        recogniser.languages.map { ($0, Self.spokenLanguageNames[$0] ?? $0) }
    }

    var speaksReplies: Bool {
        didSet {
            defaults.set(speaksReplies, forKey: Key.speaksReplies)
            conversation.speaksReplies = speaksReplies
            if !speaksReplies { conversation.stopSpeaking() }
        }
    }

    /// Speaking speed relative to each voice's normal pace.
    var speechRate: Double {
        didSet {
            defaults.set(speechRate, forKey: Key.speechRate)
            applySpeechRate()
        }
    }

    /// Chosen system voice per language code; a language without an entry uses the default voice.
    var voiceIdentifiers: [String: String] {
        didSet {
            defaults.set(voiceIdentifiers, forKey: Key.voices)
            systemSpeech.voiceIdentifiers = voiceIdentifiers
        }
    }

    /// The language the user speaks to Nod in.
    var spokenLanguage: String {
        didSet {
            defaults.set(spokenLanguage, forKey: Key.spokenLanguage)
            conversation.listeningLanguages = [spokenLanguage]
        }
    }

    /// Whether talking over the app's voice interrupts it. Off, the app does not listen while
    /// it speaks, which is the way out when it keeps hearing itself.
    var voiceInterruption: Bool {
        didSet {
            defaults.set(voiceInterruption, forKey: Key.voiceInterruption)
            liveInput.endpointing.interruptWhileOutputPlays = voiceInterruption
        }
    }

    /// More text while the user is still talking, sooner and rougher. Only Apple's recogniser has it.
    var fastRecognition: Bool {
        didSet {
            defaults.set(fastRecognition, forKey: Key.fastRecognition)
            liveInput.liveText = fastRecognition
        }
    }

    /// Development aid: the microphone "hears" fixed phrases instead of the user.
    var simulatedMicrophone: Bool {
        didSet {
            defaults.set(simulatedMicrophone, forKey: Key.simulatedMicrophone)
            conversation.stopDialogue()
            conversation.cancelListening()
            conversation.speechInput = simulatedMicrophone ? ScriptedSpeechInput() : liveInput
        }
    }

    var isSupertonicAvailable: Bool { supertonic != nil }

    /// The voices a choice in Settings can lead to on this build.
    var availableVoiceEngines: [VoiceEngine] {
        VoiceEngine.allCases.filter { $0 != .supertonic || isSupertonicAvailable }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let voiceEngine = "voiceEngine"
        static let supertonicVoice = "supertonicVoice"
        static let phononVoice = "phononVoice"
        static let recogniser = "recogniser"
        static let voiceInterruption = "voiceInterruption"
        static let nodAddress = "nodAddress"
        static let speaksReplies = "speaksReplies"
        static let speechRate = "speechRate"
        static let voices = "voiceIdentifiers"
        static let spokenLanguage = "spokenLanguage"
        static let fastRecognition = "fastRecognition"
        static let simulatedMicrophone = "simulatedMicrophone"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let supertonic = SupertonicSynthesizer.bundledModelDirectory().map(SupertonicSynthesizer.init(modelDirectory:))
        let storedEngine = defaults.string(forKey: Key.voiceEngine).flatMap(VoiceEngine.init(rawValue:))
        var voiceEngine = storedEngine ?? (supertonic == nil ? .system : .supertonic)
        if voiceEngine == .supertonic, supertonic == nil { voiceEngine = .system }
        let supertonicVoice = min(max(defaults.integer(forKey: Key.supertonicVoice), 0), SupertonicSynthesizer.voiceCount - 1)
        let storedPhononVoice = defaults.string(forKey: Key.phononVoice)
        let phononVoice = PhononVoice.voices.contains(storedPhononVoice ?? "") ? storedPhononVoice! : PhononVoice.voices[0]
        let recogniserID = RecognitionEngine.engine(id: defaults.string(forKey: Key.recogniser) ?? "").id
        let speaksReplies = defaults.object(forKey: Key.speaksReplies) as? Bool ?? true
        let speechRate = defaults.object(forKey: Key.speechRate) as? Double ?? 1
        let voiceIdentifiers = defaults.dictionary(forKey: Key.voices) as? [String: String] ?? [:]
        let languages = RecognitionEngine.engine(id: recogniserID).languages
        let storedLanguage = defaults.string(forKey: Key.spokenLanguage) ?? ""
        let spokenLanguage = languages.contains(storedLanguage) ? storedLanguage : (languages.first ?? "en")
        let fastRecognition = defaults.bool(forKey: Key.fastRecognition)
        let voiceInterruption = defaults.object(forKey: Key.voiceInterruption) as? Bool ?? true
        let simulatedMicrophone = defaults.bool(forKey: Key.simulatedMicrophone)

        self.supertonic = supertonic
        self.voiceEngine = voiceEngine
        self.supertonicVoice = supertonicVoice
        self.phononVoice = phononVoice
        self.recogniserID = recogniserID
        self.speaksReplies = speaksReplies
        self.speechRate = speechRate
        self.voiceIdentifiers = voiceIdentifiers
        self.spokenLanguage = spokenLanguage
        self.fastRecognition = fastRecognition
        self.voiceInterruption = voiceInterruption
        self.simulatedMicrophone = simulatedMicrophone
        let nodAddress = defaults.string(forKey: Key.nodAddress).flatMap(URL.init(string:))
        let storedKey = KeychainStore().read()
        self.nodAddress = nodAddress
        hasNodKey = storedKey != nil

        neuralSpeech.fallback = systemSpeech
        let voice = VoiceRouter(active: voiceEngine == .system ? systemSpeech : neuralSpeech)
        self.voice = voice
        liveInput.engine = RecognitionEngine.engine(id: recogniserID)
        conversation = Self.makeConversation(
            address: nodAddress,
            key: storedKey,
            voice: voice,
            speechInput: simulatedMicrophone ? ScriptedSpeechInput() : liveInput
        )
        conversation.speaksReplies = speaksReplies
        conversation.listeningLanguages = [spokenLanguage]
        liveInput.liveText = fastRecognition
        liveInput.endpointing.interruptWhileOutputPlays = voiceInterruption
        phonon.voice = phononVoice
        systemSpeech.voiceIdentifiers = voiceIdentifiers
        supertonic?.preload()
        Task.detached(priority: .utility) { RecognitionEngine.removeLeftoverModels() }
        applyVoices()
        if voiceEngine == .phonon { preparePhonon() }
        neuralSpeech.onProblem = { [weak self] problem in self?.voiceProblem = problem }
    }

    private func applyVoiceEngine() {
        conversation.stopSpeaking()
        applyVoices()
        if voiceEngine == .system {
            voice.active = systemSpeech
        } else {
            voice.active = neuralSpeech
        }
        if voiceEngine == .phonon { preparePhonon() }
    }

    /// Starts Phonon's one-time download and loading now rather than at the first sentence.
    func preparePhonon() {
        guard phononStatus != .ready, phononStatus != .preparing else { return }
        phononStatus = .preparing
        Task { [phonon] in
            do {
                try await phonon.prepare()
                phononStatus = .ready
            } catch {
                phononStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Sets which neural voices speak. Phonon reads English only, so Supertonic stands behind
    /// it for everything else.
    private func applyVoices() {
        // 1.05 is the pace Supertonic's own examples use.
        let supertonicVoice = supertonic.map {
            SupertonicVoice(synthesizer: $0, speaker: self.supertonicVoice, speed: Float(1.05 * speechRate))
        }
        var voices: [any SpeechRendering] = voiceEngine == .phonon ? [phonon] : []
        if let supertonicVoice { voices.append(supertonicVoice) }
        neuralSpeech.voices = voices
    }

    private func applySpeechRate() {
        systemSpeech.rateMultiplier = Float(speechRate)
        applyVoices()
    }

    /// The language of the sample that was started last. Whether it is still being spoken is
    /// what `conversation.isSpeaking` says.
    private(set) var sampleLanguage: String?
    /// Why the neural voice could not speak the last sentence, if it could not.
    private(set) var voiceProblem: String?

    /// Speaks the sample sentence of a language with the current voice.
    func playSample(language: String) {
        guard let entry = Self.languages.first(where: { $0.code == language }) else { return }
        conversation.stopSpeaking()
        sampleLanguage = language
        volume.refresh()
        voice.speak(SpeechSegment(text: entry.sample, language: language))
    }

    func stopSample() {
        conversation.stopSpeaking()
        sampleLanguage = nil
    }
}
