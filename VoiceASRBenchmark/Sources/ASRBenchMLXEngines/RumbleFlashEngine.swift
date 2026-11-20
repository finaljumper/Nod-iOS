#if canImport(MLXAudioSTT)
import ASRBenchCore
import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

// Written against mlx-audio-swift at the revision pinned in Package.swift, APIs read in its source:
//   Qwen3ASRModel.fromModelDirectory(_:), .generate(audio:maxTokens:temperature:context:language:...)
//   ModelUtils.resolveOrDownloadModel(client:cache:repoID:requiredExtension:additionalMatchingPatterns:progressHandler:)
//   HubCache(cacheDirectory:), HubClient(cache:), Memory.clearCache(), Memory.peakMemory
// Rumble-2-Flash is Reson8's 0.5B speech recognition model in the Qwen3-ASR architecture. The
// weights used here are a community conversion to MLX, not a release by Reson8.

/// Settings of one Rumble-2-Flash engine instance.
public struct RumbleFlashConfiguration: Sendable, Equatable {
    /// Hugging Face repository of the MLX conversion.
    public var repository: String
    /// The model writes numbers as digits ("7") or as words ("seven") on request. Digits are
    /// the model's own default.
    public var numbersAsDigits: Bool
    /// Simulated streaming: seconds of new audio required before the buffer is decoded again.
    public var streamingMinNewAudioSeconds: Double

    public init(
        repository: String = "TypeWhisper/Rumble-2-Flash-8bit",
        numbersAsDigits: Bool = true,
        streamingMinNewAudioSeconds: Double = 1.0
    ) {
        self.repository = repository
        self.numbersAsDigits = numbersAsDigits
        self.streamingMinNewAudioSeconds = streamingMinNewAudioSeconds
    }

    /// The control tokens Rumble-2-Flash was trained with, placed at the start of the system
    /// prompt: number format, no filler words, repeated words kept. The last two are the
    /// defaults of the model's chat template.
    public var systemPrompt: String {
        (numbersAsDigits ? "<digits>" : "<nodigits>") + "<nofiller><verbatim>"
    }

    /// Identifier of the engine with these settings, as it appears in results.
    public var engineID: String {
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        return "rumble/\(name)" + (numbersAsDigits ? "" : "/number-words")
    }
}

/// The languages of Rumble-2-Flash, as the `support_languages` list of the conversion's
/// `config.json` names them. The model takes a language as its English name.
public enum RumbleLanguages {
    public static let namesByCode: [String: String] = [
        "zh": "Chinese", "en": "English", "yue": "Cantonese", "ar": "Arabic", "de": "German",
        "fr": "French", "es": "Spanish", "pt": "Portuguese", "id": "Indonesian", "it": "Italian",
        "ko": "Korean", "ru": "Russian", "th": "Thai", "vi": "Vietnamese", "ja": "Japanese",
        "tr": "Turkish", "hi": "Hindi", "ms": "Malay", "nl": "Dutch", "sv": "Swedish",
        "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech", "fil": "Filipino",
        "fa": "Persian", "el": "Greek", "ro": "Romanian", "hu": "Hungarian", "mk": "Macedonian",
    ]

    /// English name for a language code or locale such as `ko` or `ko-KR`.
    public static func name(for language: String) -> String? {
        namesByCode[language.languageSubtag]
    }

    /// Language code for a name the model reported, such as `Russian`. The model can report
    /// several languages for one recording; the first one is used.
    public static func code(forReported name: String?) -> String? {
        guard let first = name?.split(whereSeparator: { ",/;".contains($0) }).first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespaces).lowercased()
        return namesByCode.first { $0.value.lowercased() == trimmed }?.key
    }
}

/// Where downloaded MLX models are kept.
public enum RumbleModelStore {
    /// Root of the Hugging Face cache used for MLX models. Application Support rather than
    /// Documents, so that the models do not show up among the user's dataset folders.
    public static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VoiceASRBenchmark/huggingface", isDirectory: true)
    }

    /// Folder a repository is downloaded to. This repeats the layout
    /// `ModelUtils.resolveOrDownloadModel` uses: `<cache>/mlx-audio/<owner>_<name>`.
    public static func modelDirectory(repository: String, cacheRoot: URL = RumbleModelStore.cacheRoot) -> URL {
        cacheRoot
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(repository.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    /// Folder in which the Hub client keeps its own copy of a repository's files:
    /// `<cache>/models--<owner>--<name>`.
    public static func hubCacheDirectory(repository: String, cacheRoot: URL = RumbleModelStore.cacheRoot) -> URL {
        cacheRoot.appendingPathComponent("models--" + repository.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// A model counts as downloaded when its configuration and non-empty weights are on disk.
    public static func isDownloaded(repository: String, cacheRoot: URL = RumbleModelStore.cacheRoot) -> Bool {
        let folder = modelDirectory(repository: repository, cacheRoot: cacheRoot)
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.appendingPathComponent("config.json").path),
              let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return false }
        return files.contains { file in
            file.pathExtension == "safetensors"
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
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

/// Runs Rumble-2-Flash locally through mlx-audio-swift (MLX, on the GPU).
public actor RumbleFlashEngine: SpeechRecognitionEngine {
    public nonisolated let id: String
    public nonisolated let configuration: RumbleFlashConfiguration

    private var model: Qwen3ASRModel?

    public init(configuration: RumbleFlashConfiguration = RumbleFlashConfiguration()) {
        self.configuration = configuration
        self.id = configuration.engineID
    }

    /// MLX needs a Metal GPU, which the iOS Simulator does not provide.
    public static var runsOnThisPlatform: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private static let simulatorReason = "MLX needs a Metal GPU and does not run in the iOS Simulator."
    private static let sampleRate = 16_000.0

    // MARK: Description

    public func descriptor() async -> EngineDescriptor {
        EngineDescriptor(
            id: id,
            displayName: "Rumble-2-Flash · \(configuration.repository)" + (configuration.numbersAsDigits ? "" : " (numbers as words)"),
            family: "mlx-audio",
            engineVersion: "mlx-audio-swift, revision pinned in Package.resolved",
            modelIdentifier: configuration.repository,
            capabilities: EngineCapabilities(
                streaming: .simulated("The model transcribes a whole clip at once. The adapter decodes the growing audio buffer again whenever \(configuration.streamingMinNewAudioSeconds) s of new audio has arrived."),
                partialResults: .simulated("Partial text is the transcript of the audio received so far; the stable part is what two consecutive decodes agree on."),
                segmentTimestamps: .unsupported("The model returns text only. Time ranges need a separate forced-alignment model."),
                wordTimestamps: .unsupported("The model returns text only. Time ranges need a separate forced-alignment model."),
                languageDetection: .native("The model names the language it heard when no language is forced."),
                codeSwitching: .native("Not documented by the publisher. Observed on test clips: the model can write each language of one utterance in its own script, also when a language is forced."),
                modelStorageMeasurable: .native,
                explicitUnload: .native("The weights are released on unload. The first transcription after a load is slow because MLX compiles its GPU kernels.")
            ),
            configuration: [
                "systemPrompt": configuration.systemPrompt,
                "temperature": "0",
                "weights": "community MLX conversion, text decoder quantized to 8 bits",
                "computeUnits": "GPU (MLX)",
                "streamingMinNewAudioSeconds": String(configuration.streamingMinNewAudioSeconds),
            ]
        )
    }

    public func supportedLocales() async -> [String] {
        RumbleLanguages.namesByCode.keys.sorted()
    }

    public func availability(forLanguage language: String?) async -> EngineAvailability {
        guard Self.runsOnThisPlatform else { return .unavailable(Self.simulatorReason) }
        if let language, RumbleLanguages.name(for: language) == nil {
            return .unavailable("Rumble-2-Flash has no language \"\(language.languageSubtag)\".")
        }
        guard RumbleModelStore.isDownloaded(repository: configuration.repository) else {
            return .needsDownload("Model \(configuration.repository) has not been downloaded. Download it in the setup step first.")
        }
        return .available
    }

    public func requiredAudioFormat(forLanguage language: String?) async throws -> EngineAudioFormat {
        EngineAudioFormat(sampleRate: Self.sampleRate, encoding: .float32)
    }

    // MARK: Setup

    /// Downloads the weights. Needs network access; after this the engine runs without it.
    public func downloadModel(progress: (@Sendable (Double, String) -> Void)?) async throws {
        guard Self.runsOnThisPlatform else { throw EngineError.unavailable(Self.simulatorReason) }
        let repository = configuration.repository
        guard let repoID = Repo.ID(rawValue: repository) else {
            throw EngineError.assetsMissing("\"\(repository)\" is not a Hugging Face repository name.")
        }
        let root = RumbleModelStore.cacheRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = HubCache(cacheDirectory: root)
        progress?(0, "Downloading \(repository)")
        do {
            _ = try await ModelUtils.resolveOrDownloadModel(
                client: HubClient(cache: cache),
                cache: cache,
                repoID: repoID,
                requiredExtension: "safetensors",
                progressHandler: { downloadProgress in
                    progress?(downloadProgress.fractionCompleted, "Downloading \(repository)")
                }
            )
        } catch {
            throw EngineError.assetsMissing("Could not download \(repository): \(error.localizedDescription)")
        }
        guard RumbleModelStore.isDownloaded(repository: repository) else {
            throw EngineError.assetsMissing("\(repository) was downloaded but its weights were not found in \(RumbleModelStore.modelDirectory(repository: repository).path).")
        }
        // The Hub client keeps a second copy of every file. The model is loaded from the
        // snapshot folder only, so that copy would just double the space the model takes.
        try? FileManager.default.removeItem(at: RumbleModelStore.hubCacheDirectory(repository: repository))
        progress?(1, "\(repository) is ready")
    }

    public func prepare(
        languages: [String],
        allowDownload: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> PreparationMetrics {
        guard Self.runsOnThisPlatform else { throw EngineError.unavailable(Self.simulatorReason) }
        let repository = configuration.repository
        let folder = RumbleModelStore.modelDirectory(repository: repository)
        if model != nil {
            return PreparationMetrics(
                loadSeconds: 0,
                modelStorageBytes: RumbleModelStore.directorySize(folder),
                notes: ["The model was already loaded."]
            )
        }

        var downloadSeconds: Double?
        if !RumbleModelStore.isDownloaded(repository: repository) {
            guard allowDownload else {
                throw EngineError.assetsMissing("Model \(repository) has not been downloaded.")
            }
            let downloadStart = MonotonicClock.now()
            try await downloadModel(progress: progress)
            downloadSeconds = MonotonicClock.now() - downloadStart
        }

        progress?(0, "Loading \(repository)")
        let start = MonotonicClock.now()
        do {
            model = try await Qwen3ASRModel.fromModelDirectory(folder)
        } catch {
            throw EngineError.recognitionFailed("mlx-audio-swift could not load \(repository): \(error.localizedDescription)")
        }
        let loadSeconds = MonotonicClock.now() - start
        progress?(1, "\(repository) loaded")
        return PreparationMetrics(
            loadSeconds: loadSeconds,
            downloadSeconds: downloadSeconds,
            modelStorageBytes: RumbleModelStore.directorySize(folder),
            notes: ["The first transcription after this load includes MLX's GPU kernel compilation."]
        )
    }

    public func unload() async {
        model = nil
        Memory.clearCache()
    }

    // MARK: Decoding

    private struct Decoded {
        var text: String
        var detectedLanguage: String?
        var seconds: Double
        var generatedTokens: Int
    }

    private func languageName(for hint: String?) throws -> String? {
        guard let hint else { return nil }
        guard let name = RumbleLanguages.name(for: hint) else {
            throw EngineError.unavailable("Rumble-2-Flash has no language \"\(hint.languageSubtag)\".")
        }
        return name
    }

    /// Transcribes a range of the recording. Blocks until the transcript is complete.
    private func decode(_ samples: ArraySlice<Float>, language: String?) throws -> Decoded {
        guard let model else { throw EngineError.notPrepared }
        let start = MonotonicClock.now()
        let output = model.generate(
            audio: MLXArray(Array(samples)),
            temperature: 0,
            context: configuration.systemPrompt,
            language: language
        )
        return Decoded(
            text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: RumbleLanguages.code(forReported: output.language),
            seconds: MonotonicClock.now() - start,
            generatedTokens: output.generationTokens
        )
    }

    public func transcribe(audio: EngineAudio, languageHint: String?) async throws -> RecognitionResult {
        let language = try languageName(for: languageHint)
        let decoded = try decode(audio.samples[...], language: language)
        return RecognitionResult(
            text: decoded.text,
            detectedLanguage: languageHint == nil ? decoded.detectedLanguage : nil,
            languageUsed: languageHint?.languageSubtag ?? decoded.detectedLanguage,
            inferenceSeconds: decoded.seconds,
            engineTimings: [
                "mlx.generatedTokens": Double(decoded.generatedTokens),
                "mlx.peakMemoryBytes": Double(Memory.peakMemory),
            ]
        )
    }

    // MARK: Simulated streaming

    /// The words two transcripts have in common from the start.
    static func commonWordPrefix(_ first: String, _ second: String) -> String {
        let firstWords = first.split(separator: " "), secondWords = second.split(separator: " ")
        var count = 0
        while count < min(firstWords.count, secondWords.count), firstWords[count] == secondWords[count] {
            count += 1
        }
        return firstWords.prefix(count).joined(separator: " ")
    }

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
        guard model != nil else { throw EngineError.notPrepared }
        let language = try languageName(for: languageHint)
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

        var previous = ""
        var decodedCount = 0
        var passes = 0
        var generatedTokens = 0
        var last: Decoded?
        let start = MonotonicClock.now()

        while true {
            try Task.checkCancellation()
            let (available, finished) = arrived.snapshot()
            let newSeconds = Double(available - decodedCount) / sampleRate
            if !finished, newSeconds < configuration.streamingMinNewAudioSeconds {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }

            let decoded = try decode(audio.samples[0..<available], language: language)
            passes += 1
            decodedCount = available
            generatedTokens += decoded.generatedTokens
            last = decoded
            if finished { break }

            let stable = Self.commonWordPrefix(previous, decoded.text)
            previous = decoded.text
            _ = continuation.yield(.partial(PartialTranscript(text: decoded.text, stableText: stable, hostTime: MonotonicClock.now())))
        }

        let timeline = try await replayTask.value
        let finalTime = MonotonicClock.now()
        let result = RecognitionResult(
            text: last?.text ?? "",
            detectedLanguage: languageHint == nil ? last?.detectedLanguage : nil,
            languageUsed: languageHint?.languageSubtag ?? last?.detectedLanguage,
            inferenceSeconds: finalTime - start,
            engineTimings: [
                EngineTimingKey.replayMaxLateness: timeline.maxLatenessSeconds,
                "mlx.streamingDecodePasses": Double(passes),
                "mlx.generatedTokens": Double(generatedTokens),
                "mlx.peakMemoryBytes": Double(Memory.peakMemory),
            ],
            notes: ["Simulated streaming: \(passes) repeated decodes of the growing buffer."]
        )
        _ = continuation.yield(.final(result, hostTime: finalTime))
    }
}
#endif
