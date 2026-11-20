@preconcurrency import AVFoundation
import AnySpeechRecognizer
import Foundation
import Speech

/// Recognises one utterance: audio goes in block by block, text comes out while it is spoken
/// (if the engine can do that) and once more, complete, at the end.
protocol UtteranceRecognizing: AnyObject, Sendable {
    /// Hands over the next block of microphone audio. Any PCM format is accepted.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Ends the utterance and returns its complete text.
    func finish() async throws -> String
    /// Stops without a result.
    func cancel() async
}

/// Builds a recogniser for one utterance. `onPartial` receives the text so far.
typealias RecognizerFactory = @Sendable (_ onPartial: @escaping @Sendable (String) -> Void) async throws -> any UtteranceRecognizing

/// One of the engines that can turn speech into text.
///
/// The app offers several so that they can be compared in use. Everything that differs between
/// them is in this value: its languages, what it has to download, and how it recognises.
public struct RecognitionEngine: Sendable, Identifiable {
    public let id: String
    public let name: String
    /// What the user should know before choosing it.
    public let summary: String
    /// The language codes the user can speak with this engine.
    public let languages: [String]
    public let isAvailable: @Sendable () -> Bool
    /// Gets the engine ready for a language, downloading what is missing, and returns the
    /// builder of its recognisers. `notice` receives sentences for the user while that takes time.
    let prepare: @Sendable (_ localeIdentifier: String, _ liveText: Bool, _ notice: @escaping @Sendable (String) -> Void) async throws -> RecognizerFactory

    public static let all: [RecognitionEngine] = [.apple, .rumble]

    public static func engine(id: String) -> RecognitionEngine {
        all.first { $0.id == id } ?? .apple
    }

    /// Frees the space of models from recognisers the app no longer offers. Parakeet v3 was
    /// one; its files, about 600 MB, were the only thing in this folder.
    public static func removeLeftoverModels() {
        #if os(iOS)
        // Only inside the app's own container. On a Mac the same package shares a cache with
        // other tools, which is not this app's to delete.
        let folder = URL.applicationSupportDirectory.appending(path: "AnySpeechRecognizer", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        #endif
    }

    /// Apple's on-device transcriber, reached through AnySpeechRecognizer.
    public static let apple = RecognitionEngine(
        id: "apple",
        name: "Apple Speech",
        summary: "Built into iOS. English and Korean, one language at a time. Nothing to download beyond the system's speech model. More live text shows words sooner, but rougher.",
        languages: ["en", "ko"],
        isAvailable: { AnySpeechRecognizer.SpeechTranscriber.isAvailable },
        prepare: { localeIdentifier, liveText, notice in
            let requested = Locale(identifier: localeIdentifier)
            guard let locale = await AnySpeechRecognizer.SpeechTranscriber.supportedLocale(equivalentTo: requested),
                  locale.language.languageCode == requested.language.languageCode
            else { throw RecognitionError.unsupportedLanguage(localeIdentifier) }
            // Live text costs nothing extra here; `liveText` adds Apple's faster, rougher results.
            let options: Set<AnySpeechRecognizer.SpeechTranscriber.ReportingOption> = liveText ? [.volatileResults, .fastResults] : [.volatileResults]
            let make: @Sendable () -> AnySpeechRecognizer.SpeechTranscriber = {
                AnySpeechRecognizer.SpeechTranscriber(model: SystemSpeechModel(locale: locale), reportingOptions: options)
            }
            try await AnySpeechUtteranceRecognizer.installAssetsIfNeeded(for: make()) {
                notice("Downloading the speech model. This happens once.")
            }
            return { onPartial in try await AnySpeechUtteranceRecognizer(transcriber: make(), onPartial: onPartial) }
        }
    )

    /// Reson8's Rumble-2-Flash, run on the CPU by sherpa-onnx.
    public static let rumble = RecognitionEngine(
        id: "rumble",
        name: "Rumble-2-Flash",
        summary: "Runs on the CPU through sherpa-onnx. English and Korean, and it can follow a sentence that mixes them. Downloads about 620 MB on first use. No text while you talk until a second or so has been heard.",
        languages: ["en", "ko"],
        isAvailable: { true },
        prepare: { localeIdentifier, _, notice in
            let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? "en"
            guard let language = RumbleSpeechModel.languageNames[code] else {
                throw RecognitionError.unsupportedLanguage(localeIdentifier)
            }
            try await ModelDownloader.ensure(
                repository: RumbleSpeechModel.repository, files: RumbleSpeechModel.files,
                in: RumbleSpeechModel.directory, name: "Rumble-2-Flash", progress: notice)
            notice("Loading Rumble-2-Flash.")
            let model = try await RumbleSpeechModel.shared(in: RumbleSpeechModel.directory)
            return { onPartial in RumbleUtteranceRecognizer(model: model, language: language, onPartial: onPartial) }
        }
    )
}

public enum RecognitionError: Error, Sendable, CustomStringConvertible {
    case unavailable
    case unsupportedLanguage(String)
    case noAudioFormat
    case microphoneDenied
    case modelFailed(String)

    public var description: String {
        switch self {
        case .unavailable: return "On-device speech recognition is not available on this device."
        case .unsupportedLanguage(let language): return "This recogniser does not support \(language)."
        case .noAudioFormat: return "The speech model is not ready."
        case .microphoneDenied: return "Nod is not allowed to use the microphone. Allow it in Settings."
        case .modelFailed(let reason): return reason
        }
    }
}

/// Converts microphone audio to the format a recogniser wants. One converter is kept, because
/// changing the sample rate needs the samples that came before.
final class BufferConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.isEqual(target) { return buffer }
        if converter == nil || source?.isEqual(buffer.format) != true {
            converter = AVAudioConverter(from: buffer.format, to: target)
            source = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// An utterance recognised by an AnySpeechRecognizer transcriber, which is how Apple's is reached.
final class AnySpeechUtteranceRecognizer: UtteranceRecognizing, @unchecked Sendable {
    private let analyzer: AnySpeechRecognizer.SpeechAnalyzer
    private let converter: BufferConverter
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let collector: Task<String, Error>

    /// Installs what a transcriber needs if it is missing. Needs network access then.
    static func installAssetsIfNeeded(for probe: AnySpeechRecognizer.SpeechTranscriber, onDownload: @Sendable () -> Void) async throws {
        guard await AssetInventory.status(forModules: [probe]) < .installed else { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            onDownload()
            try await request.downloadAndInstall()
        }
    }

    init(transcriber: AnySpeechRecognizer.SpeechTranscriber, onPartial: @escaping @Sendable (String) -> Void) async throws {
        let analyzer = AnySpeechRecognizer.SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await AnySpeechRecognizer.SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RecognitionError.noAudioFormat
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        // Apple's AnalyzerInput traps on Float32 buffers (seen on macOS 27.2 with Parakeet,
        // whose preferred format is Float32). The analyzer converts for each engine anyway,
        // so audio is always handed over as 16-bit integers at the engine's sample rate.
        let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate, channels: 1, interleaved: true)
        self.converter = BufferConverter(target: integer ?? format)
        self.input = input

        collector = Task {
            var finalized = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    onPartial(finalized.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    onPartial((finalized + text).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            return finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            collector.cancel()
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws -> String {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func cancel() async {
        input.finish()
        collector.cancel()
        await analyzer.cancelAndFinishNow()
    }
}
