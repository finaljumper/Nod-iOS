@preconcurrency import AVFoundation
import Foundation
import SherpaOnnxC

/// Tells whether a block of microphone audio contains a voice, as opposed to other sound.
protocol VoiceDetecting: AnyObject {
    func hasVoice(_ buffer: AVAudioPCMBuffer) -> Bool
}

/// The Silero voice detector, run by sherpa-onnx. It listens to 32 ms at a time and answers
/// with the probability that someone is speaking. A door, a keyboard, music without singing
/// or traffic score low however loud they are.
///
/// It cannot tell whose voice it hears: the app's own voice coming back through the
/// microphone is a voice too. That is what the playback level and the text check are for.
public final class SileroVoiceDetector: VoiceDetecting {
    private let detector: OpaquePointer
    private let converter: BufferConverter

    /// The model that `Scripts/fetch-vad.sh` puts into the app, if this build has it.
    public static func bundledModel(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "silero_vad", withExtension: "onnx", subdirectory: "SileroVAD")
    }

    /// - Parameter threshold: the probability from which a moment counts as speech.
    public init?(model: URL, threshold: Float = 0.5) {
        guard FileManager.default.fileExists(atPath: model.path),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { return nil }
        converter = BufferConverter(target: format)
        let created: OpaquePointer? = model.path.withCString { path in
            "cpu".withCString { provider in
                var config = SherpaOnnxVadModelConfig()
                config.silero_vad.model = path
                config.silero_vad.threshold = threshold
                // Short, so that the answer follows the voice closely; where an utterance
                // starts and ends is decided by the endpointer.
                config.silero_vad.min_silence_duration = 0.3
                config.silero_vad.min_speech_duration = 0.1
                config.silero_vad.window_size = 512
                config.silero_vad.max_speech_duration = 60
                config.sample_rate = 16_000
                config.num_threads = 1
                config.provider = provider
                config.debug = 0
                return SherpaOnnxCreateVoiceActivityDetector(&config, 30)
            }
        }
        guard let created else { return nil }
        detector = created
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(detector)
    }

    func hasVoice(_ buffer: AVAudioPCMBuffer) -> Bool {
        // Audio that cannot be converted is not held back: loudness alone decides then.
        guard let converted = converter.convert(buffer), let samples = converted.floatChannelData?[0] else { return true }
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, samples, Int32(converted.frameLength))
        // The detector also collects whole utterances; they are not needed here.
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 { SherpaOnnxVoiceActivityDetectorPop(detector) }
        return SherpaOnnxVoiceActivityDetectorDetected(detector) == 1
    }
}
