#if canImport(WhisperKit)
import ASRBenchCore
import CoreML
import Foundation
import WhisperKit

// Written against WhisperKit 1.1.x (package `argmax-oss-swift`), APIs checked in its source:
//   WhisperKit.download(variant:downloadBase:useBackgroundSession:from:token:endpoint:progressCallback:)
//   WhisperKit(WhisperKitConfig(model:modelFolder:verbose:logLevel:prewarm:load:download:))
//   WhisperKit.transcribe(audioArray:decodeOptions:callback:) -> [TranscriptionResult]
//   WhisperKit.unloadModels(), WhisperKit.recommendedModels(), Constants.languageCodes

/// Settings of one WhisperKit engine instance.
public struct WhisperKitEngineConfiguration: Sendable, Equatable {
    /// Model variant as named in the model repository, for example
    /// `openai_whisper-large-v3-v20240930_turbo_632MB`.
    public var model: String
    /// Hugging Face repository the model is downloaded from during setup.
    public var modelRepo: String
    /// Compute word-level timestamps. Off by default because it adds decoding work that the
    /// Apple engine's default configuration does not do.
    public var wordTimestamps: Bool
    /// Simulated streaming: seconds of new audio required before the buffer is decoded again.
    public var streamingMinNewAudioSeconds: Double
    /// Simulated streaming: number of trailing segments that stay unconfirmed.
    public var streamingUnconfirmedSegments: Int

    public init(
        model: String,
        modelRepo: String = "argmaxinc/whisperkit-coreml",
        wordTimestamps: Bool = false,
        streamingMinNewAudioSeconds: Double = 1.0,
        streamingUnconfirmedSegments: Int = 2
    ) {
        self.model = model
        self.modelRepo = modelRepo
        self.wordTimestamps = wordTimestamps
        self.streamingMinNewAudioSeconds = streamingMinNewAudioSeconds
        self.streamingUnconfirmedSegments = streamingUnconfirmedSegments
    }
}

/// Lists WhisperKit models suitable for this benchmark.
public enum WhisperKitModelCatalog {
    /// English-only variants (`.en`) and distilled English models cannot transcribe Russian or
    /// Korean and are excluded.
    public static func isMultilingual(_ model: String) -> Bool {
        !model.contains(".en") && !model.lowercased().contains("distil")
    }

    /// Multilingual models WhisperKit recommends for this device, and its default among them.
    public static func multilingualModels() -> (recommended: String?, supported: [String]) {
        let support = WhisperKit.recommendedModels()
        let supported = support.supported.filter(isMultilingual)
        let recommended = isMultilingual(support.default) ? support.default : supported.last
        return (recommended, supported)
    }

    private static func defaultsKey(_ model: String) -> String { "asrbench.whisperkit.modelFolder.\(model)" }

    /// Marks a stored path as relative to the app's home directory.
    private static let homePrefix = "~/"

    /// Folder of a model that was downloaded earlier, if it is still on disk.
    public static func downloadedFolder(for model: String) -> URL? {
        guard let stored = UserDefaults.standard.string(forKey: defaultsKey(model)) else { return nil }
        let path = resolve(stored, home: NSHomeDirectory())
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func remember(folder: URL, for model: String) {
        UserDefaults.standard.set(portable(folder.path, home: NSHomeDirectory()), forKey: defaultsKey(model))
    }

    /// The app container's absolute path changes whenever the app is reinstalled or updated, so
    /// a path inside it is stored relative to the home directory.
    static func portable(_ path: String, home: String) -> String {
        let root = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(root) ? homePrefix + path.dropFirst(root.count) : path
    }

    static func resolve(_ stored: String, home: String) -> String {
        guard stored.hasPrefix(homePrefix) else { return stored }
        return (home as NSString).appendingPathComponent(String(stored.dropFirst(homePrefix.count)))
    }

    public static func isDownloaded(_ model: String) -> Bool {
        downloadedFolder(for: model) != nil
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

/// Runs Whisper models locally through WhisperKit (Core ML).
public actor WhisperKitEngine: SpeechRecognitionEngine {
    public nonisolated let id: String
    public nonisolated let configuration: WhisperKitEngineConfiguration

    private var kit: WhisperKit?
    private var modelFolder: URL?

    public init(configuration: WhisperKitEngineConfiguration) {
        self.configuration = configuration
        self.id = "whisperkit/\(configuration.model)"
    }

    private nonisolated var isEnglishOnly: Bool {
        !WhisperKitModelCatalog.isMultilingual(configuration.model)
    }

    // MARK: Description

    public func descriptor() async -> EngineDescriptor {
        let detection: CapabilitySupport = isEnglishOnly
            ? .unsupported("This is an English-only model.")
            : .native("Whisper predicts one language per 30 second window.")
        return EngineDescriptor(
            id: id,
            displayName: "WhisperKit · \(configuration.model)",
            family: "whisperkit",
            engineVersion: "argmax-oss-swift (WhisperKit), version pinned in Package.resolved",
            modelIdentifier: "\(configuration.modelRepo)/\(configuration.model)",
            capabilities: EngineCapabilities(
                streaming: .simulated("Whisper is not an incremental model. The adapter decodes the growing audio buffer again whenever \(configuration.streamingMinNewAudioSeconds) s of new audio has arrived, the same scheme WhisperKit's AudioStreamTranscriber uses for microphone input."),
                partialResults: .simulated("Partial text is the decoder's token-by-token progress within each repeated decode, plus segments that are not yet confirmed."),
                segmentTimestamps: .native,
                wordTimestamps: configuration.wordTimestamps ? .native : .native("Available, disabled in this configuration."),
                languageDetection: detection,
                codeSwitching: .unsupported("Whisper conditions each window on a single language token. Mixed-language speech is outside what the model is trained to transcribe: the other language may be translated, transliterated or dropped."),
                modelStorageMeasurable: .native,
                explicitUnload: .native("Models can be unloaded, but Core ML's on-disk specialization cache cannot be cleared by an app, so a cold load here is not a first-ever load.")
            ),
            configuration: [
                "temperature": "0 with fallback",
                "task": "transcribe",
                "chunkingStrategy": "vad (batch), none (streaming)",
                "wordTimestamps": String(configuration.wordTimestamps),
                "computeUnits": "WhisperKit defaults",
                "streamingMinNewAudioSeconds": String(configuration.streamingMinNewAudioSeconds),
                "streamingUnconfirmedSegments": String(configuration.streamingUnconfirmedSegments),
            ]
        )
    }

    public func supportedLocales() async -> [String] {
        isEnglishOnly ? ["en"] : Constants.languageCodes.sorted()
    }

    public func availability(forLanguage language: String?) async -> EngineAvailability {
        if let language {
            let code = language.languageSubtag
            if isEnglishOnly, code != "en" {
                return .unavailable("\(configuration.model) is an English-only model.")
            }
            guard Constants.languageCodes.contains(code) else {
                return .unavailable("Whisper has no language \"\(code)\".")
            }
        } else if isEnglishOnly {
            return .unavailable("\(configuration.model) is an English-only model and cannot detect languages.")
        }
        guard WhisperKitModelCatalog.isDownloaded(configuration.model) else {
            return .needsDownload("Model \(configuration.model) has not been downloaded. Download it in the setup step first.")
        }
        return .available
    }

    public func requiredAudioFormat(forLanguage language: String?) async throws -> EngineAudioFormat {
        EngineAudioFormat(sampleRate: Double(WhisperKit.sampleRate), encoding: .float32)
    }

    // MARK: Setup

    /// Downloads the model, then loads it once so that the tokenizer is fetched and Core ML
    /// specializes the model for this device. After this the engine runs without network access.
    public func downloadModel(progress: (@Sendable (Double, String) -> Void)?) async throws {
        let model = configuration.model
        progress?(0, "Downloading \(model)")
        let folder = try await WhisperKit.download(
            variant: model,
            from: configuration.modelRepo,
            progressCallback: { downloadProgress in
                progress?(downloadProgress.fractionCompleted * 0.9, "Downloading \(model)")
            }
        )
        WhisperKitModelCatalog.remember(folder: folder, for: model)
        progress?(0.9, "Loading \(model) for the first time")
        let whisperKit = try await WhisperKit(WhisperKitConfig(
            model: model,
            modelFolder: folder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        ))
        await whisperKit.unloadModels()
        progress?(1, "\(model) is ready")
    }

    public func prepare(
        languages: [String],
        allowDownload: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> PreparationMetrics {
        if kit != nil {
            return PreparationMetrics(
                loadSeconds: 0,
                modelStorageBytes: modelFolder.map(WhisperKitModelCatalog.directorySize),
                notes: ["The model was already loaded."]
            )
        }

        var downloadSeconds: Double?
        if !WhisperKitModelCatalog.isDownloaded(configuration.model) {
            guard allowDownload else {
                throw EngineError.assetsMissing("Model \(configuration.model) has not been downloaded.")
            }
            let downloadStart = MonotonicClock.now()
            try await downloadModel(progress: progress)
            downloadSeconds = MonotonicClock.now() - downloadStart
        }
        guard let folder = WhisperKitModelCatalog.downloadedFolder(for: configuration.model) else {
            throw EngineError.assetsMissing("Model \(configuration.model) has not been downloaded.")
        }

        progress?(0, "Loading \(configuration.model)")
        let start = MonotonicClock.now()
        let whisperKit: WhisperKit
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(
                model: configuration.model,
                modelFolder: folder.path,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            ))
        } catch {
            throw EngineError.recognitionFailed("WhisperKit could not load \(configuration.model): \(error.localizedDescription)")
        }
        let loadSeconds = MonotonicClock.now() - start
        kit = whisperKit
        modelFolder = folder
        progress?(1, "\(configuration.model) loaded")

        let timings = whisperKit.currentTimings
        return PreparationMetrics(
            loadSeconds: loadSeconds,
            downloadSeconds: downloadSeconds,
            modelStorageBytes: WhisperKitModelCatalog.directorySize(folder),
            details: [
                "whisperkit.modelLoading": timings.modelLoading,
                "whisperkit.encoderLoad": timings.encoderLoadTime,
                "whisperkit.decoderLoad": timings.decoderLoadTime,
                "whisperkit.tokenizerLoad": timings.tokenizerLoadTime,
                "whisperkit.encoderSpecialization": timings.encoderSpecializationTime,
                "whisperkit.decoderSpecialization": timings.decoderSpecializationTime,
            ]
        )
    }

    public func unload() async {
        if let kit {
            await kit.unloadModels()
        }
        kit = nil
    }

    // MARK: Decoding

    private func decodingOptions(languageHint: String?, streaming: Bool) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageHint?.languageSubtag,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: languageHint == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: configuration.wordTimestamps,
            chunkingStrategy: streaming ? ChunkingStrategy.none : .vad
        )
    }

    private static func clean(_ text: String) -> String {
        // Progress text can still contain special tokens such as <|en|> or <|0.00|>.
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func join(_ parts: [String]) -> String {
        parts.map(clean).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func segments(from whisperSegments: [TranscriptionSegment]) -> [RecognizedSegment] {
        whisperSegments.map { segment in
            RecognizedSegment(
                text: clean(segment.text),
                startSeconds: Double(segment.start),
                endSeconds: Double(segment.end),
                words: segment.words?.map {
                    RecognizedWord(
                        text: $0.word.trimmingCharacters(in: .whitespaces),
                        startSeconds: Double($0.start),
                        endSeconds: Double($0.end),
                        confidence: Double($0.probability)
                    )
                }
            )
        }
    }

    private static func timings(_ results: [TranscriptionResult]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for result in results {
            let timings = result.timings
            totals["whisperkit.audioProcessing", default: 0] += timings.audioProcessing
            totals["whisperkit.logmels", default: 0] += timings.logmels
            totals["whisperkit.encoding", default: 0] += timings.encoding
            totals["whisperkit.decodingLoop", default: 0] += timings.decodingLoop
            totals["whisperkit.fullPipeline", default: 0] += timings.fullPipeline
            totals["whisperkit.decodingFallbacks", default: 0] += timings.totalDecodingFallbacks
        }
        return totals
    }

    public func transcribe(audio: EngineAudio, languageHint: String?) async throws -> RecognitionResult {
        guard let kit else { throw EngineError.notPrepared }
        let options = decodingOptions(languageHint: languageHint, streaming: false)
        let start = MonotonicClock.now()
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioArray: audio.samples, decodeOptions: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineError.recognitionFailed(error.localizedDescription)
        }
        let elapsed = MonotonicClock.now() - start
        let language = results.first?.language
        return RecognitionResult(
            text: Self.join(results.map(\.text)),
            segments: Self.segments(from: results.flatMap(\.segments)),
            detectedLanguage: languageHint == nil ? language : nil,
            languageUsed: language,
            inferenceSeconds: elapsed,
            engineTimings: Self.timings(results)
        )
    }

    // MARK: Simulated streaming

    /// How much of the recording has "arrived" so far during a replay.
    private final class ArrivedAudio: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var finished = false

        func advance(to sampleCount: Int) {
            lock.lock(); count = sampleCount; lock.unlock()
        }

        func finish() {
            lock.lock(); finished = true; lock.unlock()
        }

        func snapshot() -> (count: Int, finished: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (count, finished)
        }
    }

    public nonisolated func streamTranscribe(
        audio: EngineAudio,
        languageHint: String?,
        options: StreamingOptions
    ) -> AsyncThrowingStream<RecognitionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(audio: audio, languageHint: languageHint, options: options, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        audio: EngineAudio,
        languageHint: String?,
        options: StreamingOptions,
        continuation: AsyncThrowingStream<RecognitionEvent, Error>.Continuation
    ) async throws {
        guard let kit else { throw EngineError.notPrepared }
        let sampleRate = audio.format.sampleRate
        let arrived = ArrivedAudio()
        let replay = AudioReplay(sampleCount: audio.samples.count, sampleRate: sampleRate, options: options)

        // The replay only marks audio as arrived. Decoding happens in the loop below, so a slow
        // decode never delays the delivery of later audio.
        let replayTask = Task { () -> ReplayTimeline in
            let timeline = try await replay.run(
                onStart: { hostTime in _ = continuation.yield(.replayStarted(hostTime: hostTime)) },
                deliver: { chunk in arrived.advance(to: chunk.sampleRange.upperBound) }
            )
            arrived.finish()
            _ = continuation.yield(.replayFinished(hostTime: timeline.endHostTime))
            return timeline
        }
        defer { replayTask.cancel() }

        var confirmed: [TranscriptionSegment] = []
        var lastConfirmedEnd: Float = 0
        var decodedCount = 0
        var passes = 0
        var detectedLanguage: String?
        var engineTimings: [String: Double] = [:]
        let start = MonotonicClock.now()

        while true {
            try Task.checkCancellation()
            let (available, finished) = arrived.snapshot()
            let newSeconds = Double(available - decodedCount) / sampleRate
            if !finished, newSeconds < configuration.streamingMinNewAudioSeconds {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }

            let confirmedText = Self.join(confirmed.map(\.text))
            var decodeOptions = decodingOptions(languageHint: languageHint, streaming: true)
            decodeOptions.clipTimestamps = [lastConfirmedEnd]
            let buffer = Array(audio.samples[0..<available])

            let results: [TranscriptionResult]
            do {
                let onProgress: TranscriptionCallback = { progress in
                    let volatile = Self.clean(progress.text)
                    if !volatile.isEmpty {
                        let text = confirmedText.isEmpty ? volatile : confirmedText + " " + volatile
                        _ = continuation.yield(.partial(PartialTranscript(text: text, stableText: confirmedText, hostTime: MonotonicClock.now())))
                    }
                    return nil
                }
                results = try await kit.transcribe(audioArray: buffer, decodeOptions: decodeOptions, callback: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw EngineError.recognitionFailed(error.localizedDescription)
            }
            passes += 1
            decodedCount = available
            for (key, value) in Self.timings(results) { engineTimings[key, default: 0] += value }
            if detectedLanguage == nil { detectedLanguage = results.first?.language }
            let segments = results.flatMap(\.segments)

            if finished {
                // This pass saw the whole recording: everything it produced is final.
                confirmed.append(contentsOf: segments)
                break
            }

            let keep = max(0, configuration.streamingUnconfirmedSegments)
            if segments.count > keep {
                let newlyConfirmed = Array(segments.prefix(segments.count - keep))
                confirmed.append(contentsOf: newlyConfirmed)
                if let end = newlyConfirmed.last?.end, end > lastConfirmedEnd { lastConfirmedEnd = end }
            }
            let stable = Self.join(confirmed.map(\.text))
            let volatile = Self.join(segments.suffix(min(keep, segments.count)).map(\.text))
            let text = [stable, volatile].filter { !$0.isEmpty }.joined(separator: " ")
            _ = continuation.yield(.partial(PartialTranscript(text: text, stableText: stable, hostTime: MonotonicClock.now())))
        }

        let timeline = try await replayTask.value
        let finalTime = MonotonicClock.now()
        engineTimings[EngineTimingKey.replayMaxLateness] = timeline.maxLatenessSeconds
        engineTimings["whisperkit.streamingDecodePasses"] = Double(passes)
        let result = RecognitionResult(
            text: Self.join(confirmed.map(\.text)),
            segments: Self.segments(from: confirmed),
            detectedLanguage: languageHint == nil ? detectedLanguage : nil,
            languageUsed: languageHint?.languageSubtag ?? detectedLanguage,
            inferenceSeconds: finalTime - start,
            engineTimings: engineTimings,
            notes: ["Simulated streaming: \(passes) repeated decodes of the growing buffer."]
        )
        _ = continuation.yield(.final(result, hostTime: finalTime))
    }
}
#endif
