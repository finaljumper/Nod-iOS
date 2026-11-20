#if canImport(Speech)
import ASRBenchCore
import AVFoundation
import CoreMedia
import Foundation
import Speech

// Written against the Speech framework documentation for iOS 26 / macOS 26 (checked 2026-11):
//   SpeechTranscriber.isAvailable, .supportedLocales, .supportedLocale(equivalentTo:)
//   SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:), .results
//   SpeechTranscriber.Result: text, range, isFinal
//   AssetInventory.status(forModules:), .assetInstallationRequest(supporting:), downloadAndInstall()
//   SpeechAnalyzer(modules:options:), .bestAvailableAudioFormat(compatibleWith:),
//   .prepareToAnalyze(in:), .start(inputSequence:), .finalizeAndFinishThroughEndOfInput(),
//   .cancelAndFinishNow(), AnalyzerInput(buffer:)
//   DictationTranscriber(locale:contentHints:transcriptionOptions:reportingOptions:attributeOptions:),
//   .supportedLocales, .supportedLocale(equivalentTo:), .results (checked against the macOS 27.2 SDK)
// Only iOS 26 APIs are used. The iOS 27 helper AnalyzerInputConverter is deliberately avoided,
// because the benchmark converts audio itself so that every engine receives the same samples.

/// The SpeechAnalyzer module that does the transcription.
public enum AppleSpeechModule: String, Sendable, Equatable, CaseIterable {
    /// Apple's current speech-to-text model.
    case speechTranscriber
    /// The dictation model, Apple's fallback for devices and languages SpeechTranscriber does
    /// not cover.
    case dictationTranscriber

    public var typeName: String {
        switch self {
        case .speechTranscriber: return "SpeechTranscriber"
        case .dictationTranscriber: return "DictationTranscriber"
        }
    }
}

/// Settings of the Apple SpeechAnalyzer engine.
public struct AppleSpeechAnalyzerConfiguration: Sendable, Equatable {
    public var module: AppleSpeechModule
    /// Locale requested for each language code. SpeechTranscriber works on locales, not bare
    /// languages; the system may substitute an equivalent supported locale.
    public var localeIdentifiers: [String: String]
    /// Streaming with SpeechTranscriber only: add `.fastResults`, which Apple documents as
    /// biasing the transcriber towards responsiveness at the cost of accuracy.
    /// DictationTranscriber has no such option and ignores this.
    public var fastResults: Bool

    public init(
        module: AppleSpeechModule = .speechTranscriber,
        localeIdentifiers: [String: String] = ["en": "en-US", "ru": "ru-RU", "ko": "ko-KR"],
        fastResults: Bool = false
    ) {
        self.module = module
        self.localeIdentifiers = localeIdentifiers
        self.fastResults = fastResults
    }

    /// Whether `.fastResults` is actually applied.
    public var usesFastResults: Bool { module == .speechTranscriber && fastResults }

    /// Identifier of the engine with these settings, as it appears in results.
    public var engineID: String {
        switch module {
        case .speechTranscriber: return fastResults ? "apple-speechanalyzer/fast-results" : "apple-speechanalyzer"
        case .dictationTranscriber: return "apple-dictationtranscriber"
        }
    }
}

/// Apple's on-device SpeechAnalyzer with the SpeechTranscriber or the DictationTranscriber module.
///
/// SpeechAnalyzer runs on device only; there is no server fallback in this API. A language the
/// module does not support is reported as unavailable.
public actor AppleSpeechAnalyzerEngine: SpeechRecognitionEngine {
    public nonisolated let id: String
    public nonisolated let configuration: AppleSpeechAnalyzerConfiguration

    /// Resolved locale identifier per language code.
    private var resolvedLocales: [String: Locale] = [:]
    private var formats: [String: AVAudioFormat] = [:]
    /// Prepared analyzers kept alive so that the models stay loaded between runs.
    private var keepers: [String: AnyObject] = [:]

    public init(configuration: AppleSpeechAnalyzerConfiguration = AppleSpeechAnalyzerConfiguration()) {
        self.configuration = configuration
        self.id = configuration.engineID
    }

    private nonisolated var module: AppleSpeechModule { configuration.module }
    private nonisolated var moduleName: String { configuration.module.typeName }
    private nonisolated var noDetection: String { "\(moduleName) has no language detection; it needs a locale." }

    private static let osRequirement = "SpeechAnalyzer requires iOS 26, iPadOS 26 or macOS 26."

    private func requestedLocale(for language: String) -> Locale {
        let code = language.languageSubtag
        // A full locale such as ko-KR is used as given; a bare code is mapped.
        let identifier = language.contains("-") ? language : (configuration.localeIdentifiers[code] ?? code)
        return Locale(identifier: identifier)
    }

    // MARK: Description

    public func descriptor() async -> EngineDescriptor {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let displayName: String
        var settings: [String: String] = [
            "module": moduleName,
            "batch.reportingOptions": "none",
            "attributeOptions": "audioTimeRange",
            "modelRetention": "lingering",
            "locales": configuration.localeIdentifiers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "),
        ]
        switch module {
        case .speechTranscriber:
            displayName = configuration.fastResults ? "Apple SpeechTranscriber (fast results)" : "Apple SpeechTranscriber"
            settings["transcriptionOptions"] = "none"
            settings["streaming.reportingOptions"] = configuration.fastResults ? "volatileResults, fastResults" : "volatileResults"
        case .dictationTranscriber:
            displayName = "Apple DictationTranscriber"
            settings["contentHints"] = "none"
            settings["transcriptionOptions"] = "punctuation"
            settings["streaming.reportingOptions"] = "volatileResults"
        }
        return EngineDescriptor(
            id: id,
            displayName: displayName,
            family: "apple-speechanalyzer",
            engineVersion: "Speech framework, OS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            modelIdentifier: "\(moduleName) (system-managed model)",
            capabilities: EngineCapabilities(
                streaming: .native,
                partialResults: .native("Volatile results, enabled in streaming mode."),
                segmentTimestamps: .native,
                wordTimestamps: .native("Time ranges come as attributes on runs of the result text; a run is not always exactly one word."),
                languageDetection: .unsupported("A \(moduleName) is created for one locale. The language must be known in advance."),
                codeSwitching: .unsupported("One locale per transcriber. Speech in another language is transcribed as if it were the configured one."),
                modelStorageMeasurable: .unsupported("Language assets are installed and stored by the system and shared between apps."),
                explicitUnload: .unsupported("Models are managed by the system. Dropping the analyzers lets the system release them, but an app cannot force it. Relaunch the app before a cold-start measurement.")
            ),
            configuration: settings
        )
    }

    public func supportedLocales() async -> [String] {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return [] }
        return await SpeechAnalyzerBackend.supportedLocales(module).map { $0.identifier(.bcp47) }.sorted()
    }

    public func availability(forLanguage language: String?) async -> EngineAvailability {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            return .unavailable(Self.osRequirement)
        }
        guard let language else {
            return .unavailable(noDetection)
        }
        guard SpeechAnalyzerBackend.isAvailable(module) else {
            return .unavailable("This device does not support \(moduleName).")
        }
        guard let locale = await SpeechAnalyzerBackend.resolve(requestedLocale(for: language), module: module) else {
            return .unavailable("\(moduleName) does not support \"\(language)\" on this device.")
        }
        resolvedLocales[language] = locale
        switch await SpeechAnalyzerBackend.assetStatus(module, locale: locale) {
        case .installed:
            return .available
        case .supported, .downloading:
            return .needsDownload("The \(locale.identifier(.bcp47)) speech assets are not installed. Download them in the setup step first.")
        case .unsupported:
            return .unavailable("\(moduleName) cannot be configured for \(locale.identifier(.bcp47)) on this device.")
        @unknown default:
            return .unavailable("Unknown asset status for \(locale.identifier(.bcp47)).")
        }
    }

    public func requiredAudioFormat(forLanguage language: String?) async throws -> EngineAudioFormat {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            throw EngineError.unavailable(Self.osRequirement)
        }
        guard let language else {
            throw EngineError.unsupportedCapability(noDetection)
        }
        let format = try await analyzerFormat(for: language)
        switch format.commonFormat {
        case .pcmFormatInt16:
            return EngineAudioFormat(sampleRate: format.sampleRate, encoding: .int16)
        case .pcmFormatFloat32:
            return EngineAudioFormat(sampleRate: format.sampleRate, encoding: .float32)
        default:
            throw EngineError.unsupportedCapability("SpeechAnalyzer asked for an audio format the benchmark cannot produce: \(format)")
        }
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func locale(for language: String) async throws -> Locale {
        if let locale = resolvedLocales[language] { return locale }
        guard let locale = await SpeechAnalyzerBackend.resolve(requestedLocale(for: language), module: module) else {
            throw EngineError.unavailable("\(moduleName) does not support \"\(language)\" on this device.")
        }
        resolvedLocales[language] = locale
        return locale
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func analyzerFormat(for language: String) async throws -> AVAudioFormat {
        if let format = formats[language] { return format }
        let locale = try await locale(for: language)
        guard let format = await SpeechAnalyzerBackend.bestFormat(module, locale: locale) else {
            throw EngineError.assetsMissing("No audio format is available for \(locale.identifier(.bcp47)); its speech assets are probably not installed.")
        }
        formats[language] = format
        return format
    }

    // MARK: Setup

    public func prepare(
        languages: [String],
        allowDownload: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> PreparationMetrics {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            throw EngineError.unavailable(Self.osRequirement)
        }
        guard SpeechAnalyzerBackend.isAvailable(module) else {
            throw EngineError.unavailable("This device does not support \(moduleName).")
        }

        var downloadSeconds: Double?
        var loadSeconds = 0.0
        var details: [String: Double] = [:]
        var notes = [
            "Storage size is not measurable: speech assets are system-managed.",
            "This load is cold only if no SpeechAnalyzer session ran in this process shortly before; relaunch the app for a cold-start measurement.",
        ]

        for (index, language) in languages.enumerated() {
            let locale = try await locale(for: language)
            let name = locale.identifier(.bcp47)
            let status = await SpeechAnalyzerBackend.assetStatus(module, locale: locale)
            if status == .unsupported {
                throw EngineError.unavailable("\(moduleName) cannot be configured for \(name) on this device.")
            }
            if status != .installed {
                guard allowDownload else {
                    throw EngineError.assetsMissing("The \(name) speech assets are not installed.")
                }
                progress?(Double(index) / Double(max(1, languages.count)), "Downloading \(name) speech assets")
                let start = MonotonicClock.now()
                try await SpeechAnalyzerBackend.installAssets(module, locale: locale)
                downloadSeconds = (downloadSeconds ?? 0) + (MonotonicClock.now() - start)
                formats[language] = nil
            }

            if keepers[language] == nil {
                progress?(Double(index) / Double(max(1, languages.count)), "Loading \(name)")
                let format = try await analyzerFormat(for: language)
                let start = MonotonicClock.now()
                let keeper = try await SpeechAnalyzerBackend.preheat(module, locale: locale, format: format, fastResults: configuration.usesFastResults)
                let elapsed = MonotonicClock.now() - start
                keepers[language] = keeper
                loadSeconds += elapsed
                details["apple.prepareToAnalyze.\(name)"] = elapsed
            } else {
                notes.append("\(name) was already loaded.")
            }
        }
        progress?(1, "Apple \(moduleName) ready")
        return PreparationMetrics(loadSeconds: loadSeconds, downloadSeconds: downloadSeconds, modelStorageBytes: nil, details: details, notes: notes)
    }

    public func unload() async {
        keepers.removeAll()
    }

    // MARK: Transcription

    public func transcribe(audio: EngineAudio, languageHint: String?) async throws -> RecognitionResult {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            throw EngineError.unavailable(Self.osRequirement)
        }
        guard let languageHint else {
            throw EngineError.unsupportedCapability(noDetection)
        }
        let locale = try await locale(for: languageHint)
        let format = try await analyzerFormat(for: languageHint)
        return try await SpeechAnalyzerBackend.run(
            module, audio: audio, format: format, locale: locale, streaming: nil,
            fastResults: configuration.usesFastResults, emit: { _ in }
        )
    }

    public nonisolated func streamTranscribe(
        audio: EngineAudio,
        languageHint: String?,
        options: StreamingOptions
    ) -> AsyncThrowingStream<RecognitionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
                        throw EngineError.unavailable(Self.osRequirement)
                    }
                    guard let languageHint else {
                        throw EngineError.unsupportedCapability(noDetection)
                    }
                    let locale = try await self.locale(for: languageHint)
                    let format = try await self.analyzerFormat(for: languageHint)
                    let result = try await SpeechAnalyzerBackend.run(
                        self.module, audio: audio, format: format, locale: locale, streaming: options,
                        fastResults: self.configuration.usesFastResults,
                        emit: { event in _ = continuation.yield(event) }
                    )
                    _ = continuation.yield(.final(result, hostTime: MonotonicClock.now()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Downloads and installs the speech assets for the given languages. Needs network access.
    public func installAssets(languages: [String], progress: (@Sendable (Double, String) -> Void)?) async throws {
        _ = try await prepare(languages: languages, allowDownload: true, progress: progress)
    }
}

/// The calls into the Speech framework, kept in one place.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum SpeechAnalyzerBackend {
    /// `SpeechTranscriber` can be unavailable on hardware that cannot run its model.
    /// `DictationTranscriber` has no such check; its coverage shows in the supported locales.
    static func isAvailable(_ module: AppleSpeechModule) -> Bool {
        switch module {
        case .speechTranscriber: return SpeechTranscriber.isAvailable
        case .dictationTranscriber: return true
        }
    }

    static func supportedLocales(_ module: AppleSpeechModule) async -> [Locale] {
        switch module {
        case .speechTranscriber: return await SpeechTranscriber.supportedLocales
        case .dictationTranscriber: return await DictationTranscriber.supportedLocales
        }
    }

    static func resolve(_ requested: Locale, module: AppleSpeechModule) async -> Locale? {
        let equivalent: Locale?
        switch module {
        case .speechTranscriber: equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        case .dictationTranscriber: equivalent = await DictationTranscriber.supportedLocale(equivalentTo: requested)
        }
        // The system may return a different region of the same language, never another language.
        guard let locale = equivalent, locale.language.languageCode == requested.language.languageCode else { return nil }
        return locale
    }

    static func makeSpeechTranscriber(locale: Locale, streaming: Bool, fastResults: Bool) -> SpeechTranscriber {
        var reporting: Set<SpeechTranscriber.ReportingOption> = []
        if streaming {
            reporting.insert(.volatileResults)
            if fastResults { reporting.insert(.fastResults) }
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reporting,
            attributeOptions: [.audioTimeRange]
        )
    }

    static func makeDictationTranscriber(locale: Locale, streaming: Bool) -> DictationTranscriber {
        // Punctuation is opt-in for dictation; SpeechTranscriber punctuates without being asked.
        DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: streaming ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func makeModule(_ module: AppleSpeechModule, locale: Locale, streaming: Bool = false, fastResults: Bool = false) -> any SpeechModule {
        switch module {
        case .speechTranscriber: return makeSpeechTranscriber(locale: locale, streaming: streaming, fastResults: fastResults)
        case .dictationTranscriber: return makeDictationTranscriber(locale: locale, streaming: streaming)
        }
    }

    static func assetStatus(_ module: AppleSpeechModule, locale: Locale) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [makeModule(module, locale: locale)])
    }

    static func installAssets(_ module: AppleSpeechModule, locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule(module, locale: locale)]) {
            try await request.downloadAndInstall()
        }
    }

    static func bestFormat(_ module: AppleSpeechModule, locale: Locale) async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule(module, locale: locale)])
    }

    static var analyzerOptions: SpeechAnalyzer.Options {
        SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
    }

    /// Creates an analyzer and loads its resources. The caller keeps the returned object alive
    /// for as long as the models should stay loaded.
    static func preheat(_ module: AppleSpeechModule, locale: Locale, format: AVAudioFormat, fastResults: Bool) async throws -> AnyObject {
        let analyzer = SpeechAnalyzer(modules: [makeModule(module, locale: locale, fastResults: fastResults)], options: analyzerOptions)
        try await analyzer.prepareToAnalyze(in: format)
        return analyzer
    }

    /// Copies a range of mono samples into a buffer in the analyzer's format.
    static func makeBuffer(audio: EngineAudio, range: Range<Int>, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(range.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw EngineError.recognitionFailed("Could not allocate an audio buffer.")
        }
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        // Interleaved data lives in one buffer with a stride; otherwise each channel has its own.
        let planes = format.isInterleaved ? 1 : channels
        let stride = format.isInterleaved ? channels : 1

        switch format.commonFormat {
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData, let source = audio.int16Samples else {
                throw EngineError.recognitionFailed("Audio was not prepared as 16-bit integers.")
            }
            for plane in 0..<planes {
                for offset in 0..<stride {
                    for frame in 0..<range.count {
                        data[plane][frame * stride + offset] = source[range.lowerBound + frame]
                    }
                }
            }
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else {
                throw EngineError.recognitionFailed("Could not access the audio buffer.")
            }
            for plane in 0..<planes {
                for offset in 0..<stride {
                    for frame in 0..<range.count {
                        data[plane][frame * stride + offset] = audio.samples[range.lowerBound + frame]
                    }
                }
            }
        default:
            throw EngineError.unsupportedCapability("Unsupported analyzer audio format: \(format)")
        }
        return buffer
    }

    /// Time ranges of the runs of a result's text. If this does not compile against a future
    /// SDK it can return `nil`; segment time ranges come from `result.range` and are unaffected.
    static func timedRuns(of text: AttributedString) -> [RecognizedWord]? {
        var words: [RecognizedWord] = []
        for run in text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            words.append(RecognizedWord(text: word, startSeconds: timeRange.start.seconds, endSeconds: timeRange.end.seconds))
        }
        return words.isEmpty ? nil : words
    }

    private struct Collected {
        var text = ""
        var segments: [RecognizedSegment] = []
    }

    /// Transcribes one recording. With `streaming` set the audio is replayed in chunks and
    /// volatile results are reported through `emit`; otherwise all audio is supplied at once.
    static func run(
        _ module: AppleSpeechModule,
        audio: EngineAudio,
        format: AVAudioFormat,
        locale: Locale,
        streaming: StreamingOptions?,
        fastResults: Bool,
        emit: @escaping @Sendable (RecognitionEvent) -> Void
    ) async throws -> RecognitionResult {
        switch module {
        case .speechTranscriber:
            let transcriber = makeSpeechTranscriber(locale: locale, streaming: streaming != nil, fastResults: fastResults)
            return try await run(transcriber, text: { $0.text }, audio: audio, format: format, locale: locale, streaming: streaming, emit: emit)
        case .dictationTranscriber:
            let transcriber = makeDictationTranscriber(locale: locale, streaming: streaming != nil)
            return try await run(transcriber, text: { $0.text }, audio: audio, format: format, locale: locale, streaming: streaming, emit: emit)
        }
    }

    /// The two transcribers share no protocol for the text of a result, hence `text`.
    private static func run<Module: SpeechModule>(
        _ transcriber: Module,
        text resultText: @escaping @Sendable (Module.Result) -> AttributedString,
        audio: EngineAudio,
        format: AVAudioFormat,
        locale: Locale,
        streaming: StreamingOptions?,
        emit: @escaping @Sendable (RecognitionEvent) -> Void
    ) async throws -> RecognitionResult {
        let isStreaming = streaming != nil
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let collector = Task { () throws -> Collected in
            var collected = Collected()
            for try await result in transcriber.results {
                let attributed = resultText(result)
                let text = String(attributed.characters)
                if result.isFinal {
                    collected.text += text
                    collected.segments.append(RecognizedSegment(
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        startSeconds: result.range.start.seconds,
                        endSeconds: result.range.end.seconds,
                        words: timedRuns(of: attributed)
                    ))
                    if isStreaming {
                        emit(.partial(PartialTranscript(text: collected.text, stableText: collected.text, hostTime: MonotonicClock.now())))
                    }
                } else if isStreaming {
                    emit(.partial(PartialTranscript(text: collected.text + text, stableText: collected.text, hostTime: MonotonicClock.now())))
                }
            }
            return collected
        }

        do {
            let start = MonotonicClock.now()
            try await analyzer.start(inputSequence: inputSequence)

            // Batch: one-second buffers back to back. Streaming: the requested chunks in real time.
            let replayOptions = streaming ?? StreamingOptions(chunkSeconds: 1.0, realTime: false)
            let replay = AudioReplay(sampleCount: audio.samples.count, sampleRate: audio.format.sampleRate, options: replayOptions)
            let timeline = try await replay.run(
                onStart: { hostTime in if isStreaming { emit(.replayStarted(hostTime: hostTime)) } },
                deliver: { chunk in
                    let buffer = try makeBuffer(audio: audio, range: chunk.sampleRange, format: format)
                    inputBuilder.yield(AnalyzerInput(buffer: buffer))
                }
            )
            // End of input is signalled immediately after the last chunk: the benchmark measures
            // finalization latency, not endpoint detection.
            inputBuilder.finish()
            if isStreaming { emit(.replayFinished(hostTime: MonotonicClock.now())) }

            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let collected = try await collector.value
            let elapsed = MonotonicClock.now() - start

            return RecognitionResult(
                text: collected.text.trimmingCharacters(in: .whitespacesAndNewlines),
                segments: collected.segments,
                detectedLanguage: nil,
                languageUsed: locale.identifier(.bcp47),
                inferenceSeconds: elapsed,
                engineTimings: [EngineTimingKey.replayMaxLateness: timeline.maxLatenessSeconds]
            )
        } catch {
            inputBuilder.finish()
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let engineError = error as? EngineError { throw engineError }
            throw EngineError.recognitionFailed(error.localizedDescription)
        }
    }
}
#endif
