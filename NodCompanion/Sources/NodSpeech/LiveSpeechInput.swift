@preconcurrency import AVFoundation
import AnySpeechRecognizer
import Foundation
import NodCore

/// Listens to the microphone and turns what the user says into text.
///
/// The microphone signal is watched for the start and the end of each utterance. Every
/// utterance is recognised on its own, so the text of one never runs into the next. Sound
/// counts as the user talking when it is loud enough and a voice detector hears a voice in
/// it. While the app itself is speaking, "loud enough" is measured against how loud the app
/// is playing, because part of its own voice comes back through the microphone.
@MainActor
public final class LiveSpeechInput: SpeechInput {
    /// The recognition engine. Exchange it here to try another one.
    public var engine: RecognitionEngine
    /// Asks the engine for more text while the user is still talking. Apple's engine gives it
    /// sooner and rougher; Rumble has nothing more to give.
    public var liveText = false
    /// The locale used for each language code.
    public var locales = ["en": "en-US", "ko": "ko-KR", "ru": "ru-RU"]
    public var endpointing = UtteranceEndpointer.Settings()

    private let audio: VoiceAudioEngine
    private var task: Task<Void, Never>?
    private let finishRequest = FinishRequest()
    private let echoNote = FinishRequest()

    public init(engine: RecognitionEngine = .apple, audio: VoiceAudioEngine = .shared) {
        self.engine = engine
        self.audio = audio
    }

    public var availability: SpeechInputAvailability {
        #if targetEnvironment(simulator)
        return .unavailable("Speech recognition does not run in the iOS Simulator. Use a real iPhone or iPad, or the simulated microphone.")
        #else
        return engine.isAvailable() ? .ready : .unavailable(RecognitionError.unavailable.description)
        #endif
    }

    public func start(languages: [String], continuous: Bool) -> AsyncThrowingStream<SpeechInputEvent, Error> {
        task?.cancel()
        finishRequest.reset()
        let language = languages.first ?? "en"
        let identifier = locales[language] ?? language
        let engine = self.engine, liveText = self.liveText, endpointing = self.endpointing
        let audio = self.audio, finishRequest = self.finishRequest, echoNote = self.echoNote
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await Self.listen(
                        engine: engine, localeIdentifier: identifier, liveText: liveText,
                        endpointing: endpointing, continuous: continuous, audio: audio,
                        finishRequest: finishRequest, echoNote: echoNote, output: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                audio.stopCapture()
            }
            self.task = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func finish() { finishRequest.request() }

    public func noteEcho() { echoNote.request() }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// A signal set from the main actor and read by the listener: the user tapped to end an
    /// utterance, or an utterance turned out to be the app's own voice.
    private final class FinishRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var requested = false
        func request() { lock.withLock { requested = true } }
        func reset() { lock.withLock { requested = false } }
        func take() -> Bool {
            lock.withLock {
                defer { requested = false }
                return requested
            }
        }
    }

    private static func listen(
        engine: RecognitionEngine,
        localeIdentifier: String,
        liveText: Bool,
        endpointing: UtteranceEndpointer.Settings,
        continuous: Bool,
        audio: VoiceAudioEngine,
        finishRequest: FinishRequest,
        echoNote: FinishRequest,
        output: AsyncThrowingStream<SpeechInputEvent, Error>.Continuation
    ) async throws {
        guard engine.isAvailable() else { throw RecognitionError.unavailable }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecognitionError.microphoneDenied }
        // Without the detector's model in the build, loudness alone decides what is speech.
        let detector = SileroVoiceDetector.bundledModel().flatMap { SileroVoiceDetector(model: $0) }
        try await recognise(
            buffers: { try audio.startCapture() }, outputLevel: { audio.recentOutputLevel() },
            voiceDetector: detector,
            engine: engine, localeIdentifier: localeIdentifier, liveText: liveText,
            endpointing: endpointing, continuous: continuous, finishRequested: { finishRequest.take() },
            echoNoted: { echoNote.take() },
            output: output)
    }

    /// The listening itself, apart from where the audio comes from: finds utterances in a
    /// stream of audio blocks and recognises each one.
    static func recognise(
        buffers: () throws -> AsyncStream<AVAudioPCMBuffer>,
        outputLevel: @Sendable () -> Float? = { nil },
        voiceDetector: (any VoiceDetecting)? = nil,
        engine: RecognitionEngine,
        localeIdentifier: String,
        liveText: Bool,
        endpointing: UtteranceEndpointer.Settings,
        continuous: Bool,
        finishRequested: @Sendable () -> Bool,
        echoNoted: @Sendable () -> Bool = { false },
        output: AsyncThrowingStream<SpeechInputEvent, Error>.Continuation
    ) async throws {
        let factory = try await engine.prepare(localeIdentifier, liveText) { output.yield(.notice($0)) }
        output.yield(.notice(""))

        func makeRecognizer() async throws -> any UtteranceRecognizing {
            try await factory { text in
                if !text.isEmpty { output.yield(.partial(text)) }
            }
        }

        // A recogniser is kept ready before anyone talks, so the first words are not lost
        // while one is being created.
        var recognizer: (any UtteranceRecognizing)? = try await makeRecognizer()
        var endpointer = UtteranceEndpointer(settings: endpointing)
        // Tap-to-talk: the user has already said they are talking.
        var isUtteranceOpen = !continuous
        // The moments before speech was noticed, so that the first syllable is recognised too.
        var preroll: [AVAudioPCMBuffer] = []
        var prerollSeconds = 0.0

        defer { if let recognizer { Task { await recognizer.cancel() } } }

        func closeUtterance() async throws -> Bool {
            let text = try await recognizer?.finish() ?? ""
            recognizer = nil
            output.yield(.final(text))
            guard continuous else { return false }
            isUtteranceOpen = false
            endpointer.reset()
            recognizer = try await makeRecognizer()
            return true
        }

        for await buffer in try buffers() {
            try Task.checkCancellation()
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            var level: Float = -120
            if let channel = buffer.floatChannelData?[0] {
                level = UtteranceEndpointer.level(of: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            // The last utterance was the app's own voice: more of it reaches the microphone
            // than assumed, so it takes more from now on.
            if echoNoted() { endpointer.raiseEchoEstimate() }
            let voice = voiceDetector?.hasVoice(buffer)
            let event = endpointer.process(level: level, duration: seconds, outputLevel: outputLevel(), voice: voice)

            if isUtteranceOpen {
                recognizer?.append(buffer)
                // In tap-to-talk the end comes from the user's tap, or from silence after speech.
                if event == .ended || finishRequested() {
                    guard try await closeUtterance() else { return }
                }
            } else if event == .started {
                isUtteranceOpen = true
                output.yield(.speechStarted)
                preroll.forEach { recognizer?.append($0) }
                recognizer?.append(buffer)
                preroll.removeAll()
                prerollSeconds = 0
            } else {
                preroll.append(buffer)
                prerollSeconds += seconds
                while prerollSeconds > 0.5, let first = preroll.first {
                    prerollSeconds -= Double(first.frameLength) / first.format.sampleRate
                    preroll.removeFirst()
                }
            }
        }
    }
}
