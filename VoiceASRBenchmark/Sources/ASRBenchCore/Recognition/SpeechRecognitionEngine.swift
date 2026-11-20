import Foundation

/// How well an engine supports one capability.
///
/// `simulated` means the benchmark adapter emulates the feature on top of an engine that has no
/// native support for it (for example streaming built from repeated batch decodes). Simulated
/// features are always reported as such and never presented as native.
public struct CapabilitySupport: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable {
        case native
        case simulated
        case unsupported
    }

    public var level: Level
    /// Why the capability is simulated or unsupported, or a caveat about native support.
    public var note: String?

    public init(_ level: Level, note: String? = nil) {
        self.level = level
        self.note = note
    }

    public static let native = CapabilitySupport(.native)
    public static func native(_ note: String) -> CapabilitySupport { .init(.native, note: note) }
    public static func simulated(_ note: String) -> CapabilitySupport { .init(.simulated, note: note) }
    public static func unsupported(_ note: String) -> CapabilitySupport { .init(.unsupported, note: note) }

    public var isAvailable: Bool { level != .unsupported }
}

/// What an engine can and cannot do. Recorded in every export so that a missing metric can be
/// traced back to "the engine does not offer this" rather than "the measurement failed".
public struct EngineCapabilities: Codable, Sendable, Equatable {
    /// Incremental recognition while audio is still arriving.
    public var streaming: CapabilitySupport
    /// Tentative (volatile) hypotheses that may still change.
    public var partialResults: CapabilitySupport
    /// Segment or phrase level time ranges.
    public var segmentTimestamps: CapabilitySupport
    /// Word level time ranges.
    public var wordTimestamps: CapabilitySupport
    /// Automatic detection of the spoken language without a hint.
    public var languageDetection: CapabilitySupport
    /// More than one language inside a single utterance.
    public var codeSwitching: CapabilitySupport
    /// On-disk size of the model can be measured by the app.
    public var modelStorageMeasurable: CapabilitySupport
    /// The model can be unloaded on demand, which a cold-start measurement needs.
    public var explicitUnload: CapabilitySupport

    public init(
        streaming: CapabilitySupport,
        partialResults: CapabilitySupport,
        segmentTimestamps: CapabilitySupport,
        wordTimestamps: CapabilitySupport,
        languageDetection: CapabilitySupport,
        codeSwitching: CapabilitySupport,
        modelStorageMeasurable: CapabilitySupport,
        explicitUnload: CapabilitySupport
    ) {
        self.streaming = streaming
        self.partialResults = partialResults
        self.segmentTimestamps = segmentTimestamps
        self.wordTimestamps = wordTimestamps
        self.languageDetection = languageDetection
        self.codeSwitching = codeSwitching
        self.modelStorageMeasurable = modelStorageMeasurable
        self.explicitUnload = explicitUnload
    }
}

/// Static description of an engine configuration, stored with every result.
public struct EngineDescriptor: Codable, Sendable, Equatable {
    /// Stable identifier, unique per engine configuration (for example `whisperkit/openai_whisper-small`).
    public var id: String
    public var displayName: String
    /// Engine family: `apple-speechanalyzer` or `whisperkit`.
    public var family: String
    /// Version of the engine library or of the OS that provides it.
    public var engineVersion: String
    /// Model identifier. For system-managed models this names the API module, not a file.
    public var modelIdentifier: String
    public var capabilities: EngineCapabilities
    /// Free-form configuration that affects results (decoding options, presets, compute units).
    public var configuration: [String: String]

    public init(
        id: String,
        displayName: String,
        family: String,
        engineVersion: String,
        modelIdentifier: String,
        capabilities: EngineCapabilities,
        configuration: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.engineVersion = engineVersion
        self.modelIdentifier = modelIdentifier
        self.capabilities = capabilities
        self.configuration = configuration
    }
}

/// Whether an engine can transcribe a given language on this device right now.
public enum EngineAvailability: Sendable, Equatable {
    /// Ready to run offline.
    case available
    /// Supported, but models or language assets must be downloaded first.
    case needsDownload(String)
    /// Not supported on this device, OS or for this language. This is not a recognition failure.
    case unavailable(String)

    public var isRunnable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .available: return nil
        case .needsDownload(let reason), .unavailable(let reason): return reason
        }
    }
}

/// Sample encoding an engine wants its input in.
public enum SampleEncoding: String, Codable, Sendable {
    case float32
    case int16
}

/// Audio format an engine requires. All benchmark audio is mono.
public struct EngineAudioFormat: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var encoding: SampleEncoding

    public init(sampleRate: Double, encoding: SampleEncoding) {
        self.sampleRate = sampleRate
        self.encoding = encoding
    }
}

/// Timings and sizes observed while an engine was prepared.
public struct PreparationMetrics: Codable, Sendable, Equatable {
    /// Wall time of `prepare`, in seconds. Start: call to `prepare`. End: `prepare` returns with
    /// the model loaded and ready to accept audio. Excludes any network download time, which is
    /// reported separately in `downloadSeconds`.
    public var loadSeconds: Double
    /// Wall time spent downloading models or assets, if a download happened.
    public var downloadSeconds: Double?
    /// On-disk size of the model in bytes, when the app can measure it.
    public var modelStorageBytes: Int64?
    /// Engine-reported breakdown (for example encoder and decoder load times).
    public var details: [String: Double]
    /// Things that could not be measured, with the reason.
    public var notes: [String]

    public init(
        loadSeconds: Double,
        downloadSeconds: Double? = nil,
        modelStorageBytes: Int64? = nil,
        details: [String: Double] = [:],
        notes: [String] = []
    ) {
        self.loadSeconds = loadSeconds
        self.downloadSeconds = downloadSeconds
        self.modelStorageBytes = modelStorageBytes
        self.details = details
        self.notes = notes
    }
}

/// Options for one streaming transcription.
public struct StreamingOptions: Sendable, Equatable {
    /// Duration of each replayed audio chunk in seconds.
    public var chunkSeconds: Double
    /// `true` replays chunks at wall-clock speed, `false` delivers them as fast as possible
    /// (used by tests; real streaming benchmarks always replay in real time).
    public var realTime: Bool

    public init(chunkSeconds: Double = 0.1, realTime: Bool = true) {
        self.chunkSeconds = chunkSeconds
        self.realTime = realTime
    }
}

/// Errors every engine adapter uses, so the runner can tell "cannot run here" from "ran and failed".
public enum EngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The engine, the OS API or the language is not supported on this device.
    case unavailable(String)
    /// Models or language assets are missing and downloading was not allowed.
    case assetsMissing(String)
    /// The requested capability does not exist for this engine.
    case unsupportedCapability(String)
    /// `prepare` has not been called, or the engine was unloaded.
    case notPrepared
    /// The engine ran and failed.
    case recognitionFailed(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): return "Unavailable: \(reason)"
        case .assetsMissing(let reason): return "Assets missing: \(reason)"
        case .unsupportedCapability(let reason): return "Unsupported capability: \(reason)"
        case .notPrepared: return "Engine is not prepared"
        case .recognitionFailed(let reason): return "Recognition failed: \(reason)"
        }
    }

    /// `true` when the error means the combination cannot run, as opposed to a recognition failure.
    public var meansUnavailable: Bool {
        switch self {
        case .unavailable, .assetsMissing, .unsupportedCapability: return true
        case .notPrepared, .recognitionFailed: return false
        }
    }
}

/// Common interface of all speech recognition engines in the benchmark.
///
/// Engines receive already decoded and normalized audio (`EngineAudio`) rather than a file URL,
/// so that both engines are guaranteed to see the same samples and so that file decoding and
/// resampling time is measured separately from inference time. `transcribe(audioURL:)` in the
/// protocol extension is a convenience for use outside the benchmark.
///
/// An engine is used by one caller at a time. The runner never runs two transcriptions concurrently.
public protocol SpeechRecognitionEngine: Sendable {
    /// Stable identifier of this engine configuration.
    var id: String { get }

    /// Describes the engine, its model and its capabilities.
    func descriptor() async -> EngineDescriptor

    /// Locales or language codes the engine can transcribe on this device, as BCP 47 identifiers.
    func supportedLocales() async -> [String]

    /// Whether `language` (a BCP 47 language code such as `ru`) can be transcribed offline right now.
    /// `nil` asks about automatic language detection.
    func availability(forLanguage language: String?) async -> EngineAvailability

    /// The audio format the engine wants for `language`.
    func requiredAudioFormat(forLanguage language: String?) async throws -> EngineAudioFormat

    /// Loads models and language assets.
    ///
    /// - Parameters:
    ///   - languages: Languages that will be transcribed.
    ///   - allowDownload: When `false` the engine must not touch the network and throws
    ///     `EngineError.assetsMissing` if something is not installed.
    ///   - progress: Reports download or load progress from 0 to 1.
    func prepare(
        languages: [String],
        allowDownload: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> PreparationMetrics

    /// Releases loaded models so that the next `prepare` measures a cold load.
    func unload() async

    /// Transcribes a complete recording as fast as possible.
    func transcribe(audio: EngineAudio, languageHint: String?) async throws -> RecognitionResult

    /// Transcribes audio while it is replayed in chunks, emitting partial and final events.
    ///
    /// The engine starts the replay itself and stamps the events, see `RecognitionEvent`.
    /// Cancelling the consuming task cancels recognition.
    func streamTranscribe(
        audio: EngineAudio,
        languageHint: String?,
        options: StreamingOptions
    ) -> AsyncThrowingStream<RecognitionEvent, Error>
}

public extension SpeechRecognitionEngine {
    /// Convenience for callers outside the benchmark: decode, normalize and transcribe a file.
    func transcribe(
        audioURL: URL,
        languageHint: String?,
        decoder: AudioDecoding = AudioFileLoader.standard
    ) async throws -> RecognitionResult {
        let decoded = try decoder.decode(url: audioURL)
        let format = try await requiredAudioFormat(forLanguage: languageHint)
        let audio = AudioNormalizer.normalize(decoded, to: format)
        return try await transcribe(audio: audio, languageHint: languageHint)
    }
}
