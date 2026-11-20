@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Gradium's Phonon 31m, an English voice, run on Core ML by FluidAudio. The model is
/// downloaded on first use.
public final class PhononVoice: SpeechRendering, @unchecked Sendable {
    /// English voices of the model that are offered in Settings, by their names in the model.
    public static let voices = ["en_us_Zoey", "en_us_Easton", "en_gb_Maeve", "default"]

    public enum State: Sendable, Equatable {
        case idle, preparing, ready, failed(String)
    }

    private let manager = PocketTtsSmallManager(model: .phonon31m)
    private let lock = NSLock()
    private var preparation: Task<Void, Error>?
    private var _voice: String
    private var _state: State = .idle

    public init(voice: String = "en_us_Zoey") {
        _voice = voice
    }

    /// The model's name of the speaker in use.
    public var voice: String {
        get { lock.withLock { _voice } }
        set { lock.withLock { _voice = newValue } }
    }

    public var state: State { lock.withLock { _state } }

    public static var directory: URL {
        ModelDownloader.modelsDirectory.appendingPathComponent("Phonon", isDirectory: true)
    }

    public func supports(language: String) -> Bool { language == "en" }

    /// Downloads and loads the model if that has not happened yet. Safe to call repeatedly.
    public func prepare() async throws {
        let task = lock.withLock { () -> Task<Void, Error> in
            if let preparation { return preparation }
            _state = .preparing
            let task = Task { [manager] in
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try await manager.initialize(directory: Self.directory)
            }
            preparation = task
            return task
        }
        do {
            try await task.value
            lock.withLock { _state = .ready }
        } catch {
            lock.withLock {
                _state = .failed(String(describing: error))
                preparation = nil
            }
            throw error
        }
    }

    public func render(text: String, language: String) async throws -> RenderedAudio {
        try await prepare()
        let samples = try await manager.synthesizeSamples(text: text, voice: voice)
        return RenderedAudio(samples: samples, sampleRate: 24_000)
    }
}
