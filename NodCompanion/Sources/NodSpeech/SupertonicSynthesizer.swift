import Foundation
import SherpaOnnxC

/// Turns text into audio with Supertonic 3, through sherpa-onnx. Everything runs on the device.
///
/// The model is loaded on first use and kept. Calls into the native engine block, so they run
/// on a queue of their own rather than on a thread of Swift's shared pool.
public final class SupertonicSynthesizer: @unchecked Sendable {
    public struct Audio: Sendable {
        public var samples: [Float]
        public var sampleRate: Double
    }

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case missingFile(String)
        case couldNotLoad
        case couldNotSpeak

        public var description: String {
            switch self {
            case .missingFile(let name): return "The Supertonic voice model is incomplete: \(name) is missing."
            case .couldNotLoad: return "The Supertonic voice model could not be loaded."
            case .couldNotSpeak: return "Supertonic could not speak this text."
            }
        }
    }

    /// The voices built into the model, in the order of its voice file.
    public static let voiceCount = 10

    /// The languages of Supertonic 3, as its own code lists them.
    public static let languages: Set<String> = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr", "hu",
        "id", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi",
    ]

    private static let graphs = ["duration_predictor", "text_encoder", "vector_estimator", "vocoder"]
    private static let resources = ["tts.json", "unicode_indexer.bin", "voice.bin"]

    private let directory: URL
    /// Owns `handle`: every native call and its destruction happen here.
    private let queue = DispatchQueue(label: "Nod.Supertonic", qos: .userInitiated)
    private var handle: OpaquePointer?

    public init(modelDirectory: URL) {
        directory = modelDirectory
    }

    deinit {
        if let handle { SherpaOnnxDestroyOfflineTts(handle) }
    }

    /// The folder with the model inside the app, if every file is there.
    public static func bundledModelDirectory(in bundle: Bundle = .main) -> URL? {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Supertonic3", isDirectory: true),
              (try? paths(in: folder)) != nil
        else { return nil }
        return folder
    }

    /// The seven files the engine needs, in the order of its configuration. A graph may be the
    /// int8 build (`name.int8.onnx`) or the full one (`name.onnx`).
    static func paths(in directory: URL) throws -> [String] {
        let manager = FileManager.default
        var paths: [String] = []
        for graph in graphs {
            let candidates = ["\(graph).int8.onnx", "\(graph).onnx"].map { directory.appendingPathComponent($0).path }
            guard let found = candidates.first(where: manager.fileExists(atPath:)) else {
                throw Failure.missingFile("\(graph).onnx")
            }
            paths.append(found)
        }
        for resource in resources {
            let path = directory.appendingPathComponent(resource).path
            guard manager.fileExists(atPath: path) else { throw Failure.missingFile(resource) }
            paths.append(path)
        }
        return paths
    }

    /// Loads the model now, so that the first sentence does not have to wait for it.
    public func preload() {
        queue.async(qos: .utility) { [self] in _ = try? loaded() }
    }

    public func unload() {
        queue.async { [self] in
            if let handle { SherpaOnnxDestroyOfflineTts(handle) }
            handle = nil
        }
    }

    /// Speaks `text` in one language with one of the built-in voices.
    /// - Parameters:
    ///   - language: a language code the model knows, such as `en` or `ko`.
    ///   - voice: 0 to 9.
    ///   - speed: 1 is the model's normal pace.
    public func render(text: String, language: String, voice: Int, speed: Float) async throws -> Audio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try renderNow(text: text, language: language, voice: voice, speed: speed) })
            }
        }
    }

    private func loaded() throws -> OpaquePointer {
        if let handle { return handle }
        let paths = try Self.paths(in: directory)
        // The engine copies its configuration, so the C strings only have to live until it returns.
        let strings = (paths + ["cpu"]).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw Failure.couldNotLoad }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.num_threads = 2
        config.model.provider = UnsafePointer(strings[7])
        config.model.supertonic.duration_predictor = UnsafePointer(strings[0])
        config.model.supertonic.text_encoder = UnsafePointer(strings[1])
        config.model.supertonic.vector_estimator = UnsafePointer(strings[2])
        config.model.supertonic.vocoder = UnsafePointer(strings[3])
        config.model.supertonic.tts_json = UnsafePointer(strings[4])
        config.model.supertonic.unicode_indexer = UnsafePointer(strings[5])
        config.model.supertonic.voice_style = UnsafePointer(strings[6])
        config.max_num_sentences = 1
        config.silence_scale = 0.2
        guard let created = SherpaOnnxCreateOfflineTts(&config) else { throw Failure.couldNotLoad }
        handle = created
        return created
    }

    private func renderNow(text: String, language: String, voice: Int, speed: Float) throws -> Audio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (0..<Self.voiceCount).contains(voice), speed.isFinite, speed > 0,
              language.allSatisfy({ $0.isLetter && $0.isASCII })
        else { throw Failure.couldNotSpeak }
        let handle = try loaded()
        var config = SherpaOnnxGenerationConfig()
        config.sid = Int32(voice)
        config.speed = speed
        config.num_steps = 6
        config.silence_scale = 0.2
        let audio = trimmed.withCString { textPointer in
            "{\"lang\":\"\(language)\"}".withCString { extraPointer in
                config.extra = extraPointer
                return SherpaOnnxOfflineTtsGenerateWithConfig(handle, textPointer, &config, nil, nil)
            }
        }
        defer { if let audio { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) } }
        guard let audio, audio.pointee.n > 0, audio.pointee.sample_rate > 0, let samples = audio.pointee.samples else {
            throw Failure.couldNotSpeak
        }
        return Audio(
            samples: Array(UnsafeBufferPointer(start: samples, count: Int(audio.pointee.n))),
            sampleRate: Double(audio.pointee.sample_rate)
        )
    }
}
