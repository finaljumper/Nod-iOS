import Foundation
@testable import ASRBenchCore

/// Counts transcriptions that are in flight at the same time, across all mock engines.
final class ConcurrencyMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func enter() {
        lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
    }

    func leave() {
        lock.lock(); inFlight -= 1; lock.unlock()
    }
}

/// A scripted engine for runner tests. It performs no recognition.
final class MockEngine: SpeechRecognitionEngine, @unchecked Sendable {
    struct Call: Equatable {
        var kind: String           // prepare, unload, transcribe, stream
        var fingerprint: String?
        var hint: String?
    }

    let id: String
    var languages: Set<String>
    var detectsLanguage: Bool
    var streamingSupport: CapabilitySupport = .native
    var needsDownload: Set<String> = []
    var prepareError: EngineError?
    var transcribeDelay: Double = 0
    /// Returns the transcript for a call, or throws.
    var respond: @Sendable (_ fingerprint: String, _ hint: String?) throws -> String = { _, _ in "" }
    var format = EngineAudioFormat(sampleRate: 16_000, encoding: .float32)
    let calls = Collected<Call>()
    let monitor: ConcurrencyMonitor
    let receivedAudio = Collected<EngineAudio>()

    init(id: String, languages: Set<String>, detectsLanguage: Bool = false, monitor: ConcurrencyMonitor = ConcurrencyMonitor()) {
        self.id = id
        self.languages = languages
        self.detectsLanguage = detectsLanguage
        self.monitor = monitor
    }

    func descriptor() async -> EngineDescriptor {
        EngineDescriptor(
            id: id, displayName: id, family: "mock", engineVersion: "1", modelIdentifier: "mock-model",
            capabilities: EngineCapabilities(
                streaming: streamingSupport,
                partialResults: .native,
                segmentTimestamps: .unsupported("mock"),
                wordTimestamps: .unsupported("mock"),
                languageDetection: detectsLanguage ? .native : .unsupported("needs a language hint"),
                codeSwitching: .unsupported("mock"),
                modelStorageMeasurable: .unsupported("mock"),
                explicitUnload: .native
            )
        )
    }

    func supportedLocales() async -> [String] { languages.sorted() }

    func availability(forLanguage language: String?) async -> EngineAvailability {
        guard let language else {
            return detectsLanguage ? .available : .unavailable("\(id) cannot detect the language.")
        }
        if needsDownload.contains(language) { return .needsDownload("Assets for \(language) are not installed.") }
        return languages.contains(language) ? .available : .unavailable("\(id) does not support \(language).")
    }

    func requiredAudioFormat(forLanguage language: String?) async throws -> EngineAudioFormat { format }

    func prepare(languages: [String], allowDownload: Bool, progress: (@Sendable (Double, String) -> Void)?) async throws -> PreparationMetrics {
        calls.append(Call(kind: allowDownload ? "prepare-with-download" : "prepare", fingerprint: nil, hint: languages.joined(separator: ",")))
        if let prepareError { throw prepareError }
        return PreparationMetrics(loadSeconds: 0.01)
    }

    func unload() async {
        calls.append(Call(kind: "unload", fingerprint: nil, hint: nil))
    }

    func transcribe(audio: EngineAudio, languageHint: String?) async throws -> RecognitionResult {
        calls.append(Call(kind: "transcribe", fingerprint: audio.sourceFingerprint, hint: languageHint))
        receivedAudio.append(audio)
        monitor.enter()
        defer { monitor.leave() }
        if transcribeDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(transcribeDelay * 1_000_000_000))
        }
        let text = try respond(audio.sourceFingerprint, languageHint)
        return RecognitionResult(text: text, detectedLanguage: languageHint == nil ? "en" : nil, languageUsed: languageHint, inferenceSeconds: transcribeDelay)
    }

    func streamTranscribe(audio: EngineAudio, languageHint: String?, options: StreamingOptions) -> AsyncThrowingStream<RecognitionEvent, Error> {
        calls.append(Call(kind: options.realTime ? "stream" : "stream-fast", fingerprint: audio.sourceFingerprint, hint: languageHint))
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                monitor.enter()
                defer { monitor.leave() }
                do {
                    let text = try respond(audio.sourceFingerprint, languageHint)
                    let replay = AudioReplay(sampleCount: audio.samples.count, sampleRate: audio.format.sampleRate, options: options)
                    let timeline = try await replay.run(
                        onStart: { continuation.yield(.replayStarted(hostTime: $0)) },
                        deliver: { chunk in
                            if chunk.index == 1 {
                                continuation.yield(.partial(PartialTranscript(text: "partial", stableText: "", hostTime: MonotonicClock.now())))
                            }
                        }
                    )
                    continuation.yield(.replayFinished(hostTime: timeline.endHostTime))
                    let result = RecognitionResult(
                        text: text, languageUsed: languageHint, inferenceSeconds: timeline.endHostTime - timeline.startHostTime,
                        engineTimings: [EngineTimingKey.replayMaxLateness: timeline.maxLatenessSeconds]
                    )
                    continuation.yield(.final(result, hostTime: MonotonicClock.now()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Builds a temporary dataset of synthetic tones. The tones stand in for audio files only;
/// transcripts are scripted by `MockEngine`.
struct TestDataset {
    let dataset: BenchmarkDataset
    let directory: URL
    /// Fingerprint of each recording's decoded audio, by recording id.
    let fingerprints: [String: String]

    init(_ recordings: [Recording], seconds: Double = 0.2, missing: Set<String> = []) throws {
        directory = try TestSignal.temporaryDirectory()
        var fingerprints: [String: String] = [:]
        for (index, recording) in recordings.enumerated() where !missing.contains(recording.id) {
            // A different frequency per recording gives every file a distinct fingerprint.
            let samples = TestSignal.sine(frequency: 200 + Double(index) * 50, sampleRate: 16_000, seconds: seconds)
            let data = WAVWriter.pcm16Data(samples: samples, sampleRate: 16_000)
            let url = directory.appendingPathComponent(recording.audioFile)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            fingerprints[recording.id] = try WAVDecoder.decode(data: data).fingerprint
        }
        self.fingerprints = fingerprints
        dataset = BenchmarkDataset(manifest: BenchmarkManifest(name: "test", recordings: recordings), baseURL: directory)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func recording(_ id: String, _ languages: [String], _ transcript: String, category: RecordingCategory = .conversational, keyTerms: [String]? = nil) -> Recording {
        Recording(id: id, audioFile: "audio/\(id).wav", transcript: transcript, languages: languages, category: category, speaker: "spk1", keyTerms: keyTerms)
    }
}
