@preconcurrency import AVFoundation
import Foundation
import SherpaOnnx
import SherpaOnnxC

/// Reson8's Rumble-2-Flash speech recognition model, as a community INT8 ONNX conversion run
/// by sherpa-onnx on the CPU. Loaded once and shared.
final class RumbleSpeechModel: @unchecked Sendable {
    static let repository = "TypeWhisper/Rumble-2-Flash-sherpa-onnx-int8"
    static let files = [
        "conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx",
        "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json",
    ]
    /// The model takes a language as its English name.
    static let languageNames = ["en": "English", "ko": "Korean", "ru": "Russian"]

    static var directory: URL {
        ModelDownloader.modelsDirectory.appendingPathComponent("Rumble-2-Flash-sherpa-onnx-int8", isDirectory: true)
    }

    private static let cacheLock = NSLock()
    private static var cached: RumbleSpeechModel?

    /// The loaded model. Loading takes a moment and happens off the caller's thread.
    static func shared(in directory: URL) async throws -> RumbleSpeechModel {
        if let model = cacheLock.withLock({ cached }) { return model }
        let model = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try RumbleSpeechModel(directory: directory) })
            }
        }
        return cacheLock.withLock {
            if let cached { return cached }
            cached = model
            return model
        }
    }

    private let recognizer: OpaquePointer
    /// Every decode runs here, one at a time.
    private let queue = DispatchQueue(label: "Nod.Rumble", qos: .userInitiated)

    private init(directory: URL) throws {
        guard ModelDownloader.isComplete(files: Self.files, in: directory) else {
            throw RecognitionError.modelFailed("The Rumble-2-Flash model is incomplete.")
        }
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        let model = sherpaOnnxOfflineQwen3ASRModelConfig(
            convFrontend: path("conv_frontend.onnx"),
            encoder: path("encoder.int8.onnx"),
            decoder: path("decoder.int8.onnx"),
            tokenizer: path("tokenizer"),
            maxTotalLen: 512,
            maxNewTokens: 256
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(tokens: "", numThreads: 4, provider: "cpu", debug: 0, qwen3Asr: model)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: modelConfig)
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw RecognitionError.modelFailed("The Rumble-2-Flash model could not be loaded.")
        }
        self.recognizer = recognizer
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    /// Transcribes 16 kHz mono samples.
    func transcribe(_ samples: [Float], language: String) async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: transcribeNow(samples, language: language))
            }
        }
    }

    private func transcribeNow(_ samples: [Float], language: String) -> String {
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxOfflineStreamSetOption(stream, "language", language)
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16_000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One utterance recognised by Rumble-2-Flash. The model takes a whole clip at a time, so the
/// audio is collected, transcribed again every so often for text while the user talks, and
/// once more at the end.
final class RumbleUtteranceRecognizer: UtteranceRecognizing, @unchecked Sendable {
    private let model: RumbleSpeechModel
    private let language: String
    private let onPartial: @Sendable (String) -> Void
    private let converter = BufferConverter(
        target: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
    private let lock = NSLock()
    private var samples: [Float] = []
    private var transcribedCount = 0
    private var partial: Task<Void, Never>?
    private var finished = false
    /// Seconds of new audio before the text so far is worked out again.
    private let partialInterval = 1.2

    init(model: RumbleSpeechModel, language: String, onPartial: @escaping @Sendable (String) -> Void) {
        self.model = model
        self.language = language
        self.onPartial = onPartial
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer), let channel = converted.floatChannelData?[0] else { return }
        let snapshot: [Float]? = lock.withLock {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            guard !finished, partial == nil, Double(samples.count - transcribedCount) >= partialInterval * 16_000 else { return nil }
            transcribedCount = samples.count
            return samples
        }
        guard let snapshot else { return }
        let task = Task { [model, language, onPartial] in
            let text = await model.transcribe(snapshot, language: language)
            if !Task.isCancelled, !text.isEmpty { onPartial(text) }
            self.lock.withLock { self.partial = nil }
        }
        lock.withLock { partial = task }
    }

    func finish() async throws -> String {
        let (all, running) = lock.withLock { () -> ([Float], Task<Void, Never>?) in
            finished = true
            return (samples, partial)
        }
        running?.cancel()
        // Less than a fifth of a second is a click, not speech.
        guard all.count >= 3_200 else { return "" }
        return await model.transcribe(all, language: language)
    }

    func cancel() async {
        lock.withLock {
            finished = true
            partial?.cancel()
        }
    }
}
