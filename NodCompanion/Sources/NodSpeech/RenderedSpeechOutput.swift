import Foundation
import NodCore

/// Audio produced for one piece of text.
public struct RenderedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// A neural voice: turns text in a language it knows into audio.
public protocol SpeechRendering: Sendable {
    func supports(language: String) -> Bool
    func render(text: String, language: String) async throws -> RenderedAudio
}

/// Speaks with neural voices. Sentences are synthesised one after another and queued for
/// playback as soon as each is ready, so the next one is usually prepared while the current
/// one is still being heard.
///
/// Several voices can be listed. Each piece of text goes to the first one that knows its
/// language, which is how an English-only voice is combined with one that also reads Korean.
/// All of them feed one queue, so the pieces are heard in the order they were written.
@MainActor
public final class RenderedSpeechOutput: SpeechOutput {
    public var onSpeakingChanged: (@MainActor @Sendable (Bool) -> Void)?
    /// The voices, in order of preference.
    public var voices: [any SpeechRendering]
    /// Used for text no voice can speak, and when a voice fails.
    public var fallback: (any SpeechOutput)?
    /// The last problem, for display in Settings.
    public private(set) var lastProblem: String? {
        didSet { onProblem?(lastProblem) }
    }
    /// Called when a voice failed, with the reason, and with nil once speaking works again.
    public var onProblem: (@MainActor (String?) -> Void)?

    private let audio: VoiceAudioEngine
    private var generation = 0
    private var pending = 0
    private var lastRender: Task<Void, Never>?

    public init(voices: [any SpeechRendering] = [], audio: VoiceAudioEngine = .shared) {
        self.voices = voices
        self.audio = audio
    }

    public func speak(_ segment: SpeechSegment) {
        pending += 1
        if pending == 1 { onSpeakingChanged?(true) }
        let generation = self.generation
        let previous = lastRender
        // A voice that fails (its model could not be downloaded, say) hands over to the next.
        let candidates = voices.filter { $0.supports(language: segment.language) }
        lastRender = Task { [weak self, audio] in
            // One sentence at a time, in order.
            await previous?.value
            guard let self, self.generation == generation else { return }
            for voice in candidates {
                do {
                    let rendered = try await voice.render(text: segment.text, language: segment.language)
                    guard self.generation == generation else { return }
                    if self.lastProblem != nil { self.lastProblem = nil }
                    audio.play(samples: rendered.samples, sampleRate: rendered.sampleRate) { [weak self] failure in
                        Task { @MainActor in self?.played(segment, generation: generation, failure: failure) }
                    }
                    return
                } catch {
                    guard self.generation == generation else { return }
                    self.lastProblem = String(describing: error)
                }
            }
            self.fallback?.speak(segment)
            self.finished(generation)
        }
    }

    public func stop() {
        generation += 1
        lastRender = nil
        audio.stopPlayback()
        fallback?.stop()
        if pending > 0 {
            pending = 0
            onSpeakingChanged?(false)
        }
    }

    public func pause() {
        audio.pausePlayback()
        fallback?.pause()
    }

    public func resume() {
        audio.resumePlayback()
        fallback?.resume()
    }

    /// A piece was heard to the end, or the audio engine could not play it. Then the system
    /// voice says it, which has its own way to the loudspeaker.
    private func played(_ segment: SpeechSegment, generation: Int, failure: (any Error)?) {
        guard self.generation == generation else { return }
        if let failure {
            lastProblem = "The audio could not be played: \(String(describing: failure))"
            fallback?.speak(segment)
        }
        finished(generation)
    }

    private func finished(_ generation: Int) {
        guard self.generation == generation, pending > 0 else { return }
        pending -= 1
        if pending == 0 { onSpeakingChanged?(false) }
    }
}

/// Supertonic 3 with one of its ten speakers, at one speed.
public struct SupertonicVoice: SpeechRendering {
    public var synthesizer: SupertonicSynthesizer
    /// 0 to 9.
    public var speaker: Int
    /// 1 is the model's normal pace.
    public var speed: Float

    public init(synthesizer: SupertonicSynthesizer, speaker: Int = 0, speed: Float = 1.05) {
        self.synthesizer = synthesizer
        self.speaker = speaker
        self.speed = speed
    }

    public func supports(language: String) -> Bool {
        SupertonicSynthesizer.languages.contains(language)
    }

    public func render(text: String, language: String) async throws -> RenderedAudio {
        let audio = try await synthesizer.render(text: text, language: language, voice: speaker, speed: speed)
        return RenderedAudio(samples: audio.samples, sampleRate: audio.sampleRate)
    }
}
