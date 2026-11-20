@preconcurrency import AVFoundation
import Foundation
import NodCore

/// A system voice the user can choose.
public struct VoiceOption: Identifiable, Sendable, Equatable {
    public enum Quality: Int, Sendable, Comparable {
        case standard = 1, enhanced = 2, premium = 3

        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .standard: return "Standard"
            case .enhanced: return "Enhanced"
            case .premium: return "Premium"
            }
        }
    }

    /// The system's identifier of the voice.
    public let id: String
    public var name: String
    /// Locale of the voice, such as `ru-RU`.
    public var locale: String
    public var quality: Quality
}

/// The voices installed on this device, by language.
public enum VoiceCatalog {
    /// The locale tried first for each language the assistant speaks.
    public static let preferredLocales = ["en": "en-US", "ru": "ru-RU", "ko": "ko-KR"]

    /// Voices for a language code, best first: higher quality before lower, the preferred
    /// locale before others. Novelty voices are left out.
    public static func voices(for language: String) -> [VoiceOption] {
        let preferred = preferredLocales[language]
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { voice in
                VoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    locale: voice.language,
                    quality: VoiceOption.Quality(rawValue: voice.quality.rawValue) ?? .standard
                )
            }
            .sorted { first, second in
                if first.quality != second.quality { return first.quality > second.quality }
                if (first.locale == preferred) != (second.locale == preferred) { return first.locale == preferred }
                return first.name < second.name
            }
    }

    /// The voice used when the user has not chosen one: an enhanced or premium voice if one is
    /// installed, otherwise the system's own default for the language.
    static func defaultVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let best = voices(for: language).first, best.quality > .standard,
           let voice = AVSpeechSynthesisVoice(identifier: best.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: preferredLocales[language] ?? language)
    }
}

/// Speaks with the voices built into iOS and macOS (`AVSpeechSynthesizer`). Everything runs on
/// the device and nothing has to be downloaded for the standard voices.
@MainActor
public final class SystemSpeechOutput: NSObject, SpeechOutput {
    public var onSpeakingChanged: (@MainActor @Sendable (Bool) -> Void)?
    /// The user's choice of voice per language code. Languages without an entry use the default.
    public var voiceIdentifiers: [String: String] = [:]
    /// Speed relative to the system's normal speaking rate: 1 is normal.
    public var rateMultiplier: Float = 1

    private let synthesizer = AVSpeechSynthesizer()
    /// Utterances handed to the synthesizer that have neither finished nor been cancelled.
    private var active: Set<ObjectIdentifier> = []

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ segment: SpeechSegment) {
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.voice = voice(for: segment.language)
        let rate = AVSpeechUtteranceDefaultSpeechRate * rateMultiplier
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        if active.isEmpty {
            activateAudioSession()
            onSpeakingChanged?(true)
        }
        active.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    public func pause() {
        synthesizer.pauseSpeaking(at: .immediate)
    }

    public func resume() {
        synthesizer.continueSpeaking()
    }

    public func stop() {
        guard !active.isEmpty || synthesizer.isSpeaking else { return }
        // Forget the queue first: the cancellations that the synthesizer reports afterwards
        // must not be counted against utterances queued after this call.
        active.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        onSpeakingChanged?(false)
        deactivateAudioSession()
    }

    private func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let identifier = voiceIdentifiers[language], let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        return VoiceCatalog.defaultVoice(for: language)
    }

    private func ended(_ utterance: ObjectIdentifier) {
        guard active.remove(utterance) != nil, active.isEmpty else { return }
        onSpeakingChanged?(false)
        deactivateAudioSession()
    }

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        // Lets music that was turned down for the reply come back up.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

extension SystemSpeechOutput: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(identifier) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(identifier) }
    }
}
