import Foundation

/// Decides from the loudness of the microphone signal when the user starts and stops talking.
///
/// It keeps a running estimate of the room's noise and calls a frame "speech" when it is
/// clearly louder than that. An utterance starts after enough speech in a row and ends after
/// enough quiet in a row, so a breath between words does not end the turn and a door slam
/// does not start one.
///
/// The noise estimate is taken from the first moments of audio, drops at once when the room
/// gets quieter, and rises slowly when it gets louder. A sound that stays loud is therefore
/// taken for the room after a while, and a noise that starts suddenly can be mistaken for an
/// utterance until then.
///
/// While the app itself is speaking, some of its voice comes back through the microphone
/// even with echo cancellation. The endpointer is told how loud the app is playing and learns
/// how much of that arrives at the microphone. Only what is clearly louder than that counts
/// as the user talking.
public struct UtteranceEndpointer: Sendable {
    public struct Settings: Sendable, Equatable {
        /// Speech must be this many decibels above the estimated noise.
        public var marginAboveNoise: Float
        /// Nothing below this level counts as speech, however quiet the room is.
        public var minimumLevel: Float
        /// Seconds of speech that start an utterance.
        public var startDuration: Double
        /// Seconds of quiet that end an utterance.
        public var endSilence: Double
        /// An utterance is cut off after this many seconds.
        public var maximumUtterance: Double
        /// While the app itself is talking, speech must be this much louder still and last
        /// this much longer, because what the loudspeaker leaks into the microphone must not
        /// count as the user interrupting.
        public var extraMarginWhileOutputPlays: Float
        public var extraStartDurationWhileOutputPlays: Double
        /// Whether the user can interrupt the app's voice by talking. When false, nothing
        /// heard while the app speaks starts an utterance.
        public var interruptWhileOutputPlays: Bool
        /// While the app is talking, speech must be this many decibels above the level its
        /// own voice is expected to have at the microphone.
        public var echoMargin: Float
        /// Seconds of the app's first speech that are only used to measure how much of it
        /// reaches the microphone.
        public var echoCalibration: Double
        /// How fast that measure may rise and fall, in decibels per second. It rises faster
        /// than it falls, so that it settles near the loudest the echo gets; it does not jump,
        /// so that the user's voice starting up is not taken for a louder echo.
        public var echoRise: Float
        public var echoDecay: Float
        /// Seconds of audio at the start that are only used to measure the room.
        public var calibration: Double
        /// How fast the noise estimate may rise, in decibels per second, while nobody talks
        /// and during an utterance.
        public var noiseRiseWhileIdle: Float
        public var noiseRiseWhileSpeaking: Float

        public init(
            marginAboveNoise: Float = 12,
            minimumLevel: Float = -45,
            startDuration: Double = 0.2,
            endSilence: Double = 0.8,
            maximumUtterance: Double = 30,
            extraMarginWhileOutputPlays: Float = 8,
            extraStartDurationWhileOutputPlays: Double = 0.2,
            interruptWhileOutputPlays: Bool = true,
            echoMargin: Float = 8,
            echoCalibration: Double = 0.3,
            echoRise: Float = 20,
            echoDecay: Float = 1,
            calibration: Double = 0.3,
            noiseRiseWhileIdle: Float = 6,
            noiseRiseWhileSpeaking: Float = 1.5
        ) {
            self.marginAboveNoise = marginAboveNoise
            self.minimumLevel = minimumLevel
            self.startDuration = startDuration
            self.endSilence = endSilence
            self.maximumUtterance = maximumUtterance
            self.extraMarginWhileOutputPlays = extraMarginWhileOutputPlays
            self.extraStartDurationWhileOutputPlays = extraStartDurationWhileOutputPlays
            self.interruptWhileOutputPlays = interruptWhileOutputPlays
            self.echoMargin = echoMargin
            self.echoCalibration = echoCalibration
            self.echoRise = echoRise
            self.echoDecay = echoDecay
            self.calibration = calibration
            self.noiseRiseWhileIdle = noiseRiseWhileIdle
            self.noiseRiseWhileSpeaking = noiseRiseWhileSpeaking
        }
    }

    public enum Event: Sendable, Equatable {
        case started
        case ended
    }

    public var settings: Settings
    public private(set) var isSpeaking = false
    /// The estimated level of the room when nobody talks, in decibels relative to full scale.
    public private(set) var noiseFloor: Float

    /// How much quieter the app's own voice is at the microphone than at the loudspeaker, in
    /// decibels (the microphone level minus the playback level), once it has been measured.
    public private(set) var echoCoupling: Float?
    private var echoMeasured = 0.0

    private var speechRun = 0.0
    private var quietRun = 0.0
    private var utteranceLength = 0.0
    private var calibrated: Double
    private var calibrationSum: Float = 0

    /// - Parameter initialNoiseFloor: a known room level. When given, nothing is measured at
    ///   the start.
    public init(settings: Settings = Settings(), initialNoiseFloor: Float? = nil) {
        self.settings = settings
        self.noiseFloor = initialNoiseFloor ?? -60
        self.calibrated = initialNoiseFloor == nil ? 0 : settings.calibration
    }

    /// The level of a block of samples in decibels relative to full scale; silence is -120.
    public static func level(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }

    /// Takes the level of the next block of audio and says whether an utterance started or ended.
    /// - Parameters:
    ///   - level: decibels relative to full scale, as returned by `level(of:)`.
    ///   - duration: length of the block in seconds.
    ///   - outputLevel: how loud the app is playing speech at this moment, in the same
    ///     unit, or nil when it is silent.
    ///   - voice: whether a voice detector hears a voice in the block, or nil without one.
    ///     Sound that is loud enough but is not a voice does not count as speech.
    public mutating func process(level: Float, duration: Double, outputLevel: Float? = nil, voice: Bool? = nil) -> Event? {
        let outputPlaying = outputLevel != nil
        if calibrated < settings.calibration {
            // The first moments measure the room; anyone already talking is heard right after.
            calibrationSum += level * Float(duration)
            calibrated += duration
            noiseFloor = max(-90, calibrationSum / Float(calibrated))
            return nil
        }
        followNoise(level: level, duration: duration, outputPlaying: outputPlaying)
        let margin = settings.marginAboveNoise + (outputPlaying && !isSpeaking ? settings.extraMarginWhileOutputPlays : 0)
        var threshold = max(settings.minimumLevel, noiseFloor + margin)

        if let outputLevel, !isSpeaking {
            guard settings.interruptWhileOutputPlays else {
                speechRun = 0
                return nil
            }
            // Only sound that stands out from the room says anything about the echo.
            let audible = level > noiseFloor + 6
            let ratio = level - outputLevel
            if let coupling = echoCoupling, echoMeasured >= settings.echoCalibration {
                threshold = max(threshold, outputLevel + coupling + settings.echoMargin)
                if level <= threshold {
                    // Still the app's own voice. The measure follows it, up faster than down.
                    echoCoupling = audible && ratio > coupling
                        ? min(ratio, coupling + settings.echoRise * Float(duration))
                        : max(-90, coupling - settings.echoDecay * Float(duration))
                }
            } else if audible {
                // The app's first words show how much of its voice the microphone picks up.
                echoMeasured += duration
                echoCoupling = max(echoCoupling ?? ratio, ratio)
                speechRun = 0
                return nil
            }
        }
        let isSpeech = level > threshold && voice != false

        if isSpeaking {
            utteranceLength += duration
            quietRun = isSpeech ? 0 : quietRun + duration
            if quietRun >= settings.endSilence || utteranceLength >= settings.maximumUtterance {
                isSpeaking = false
                speechRun = 0
                quietRun = 0
                utteranceLength = 0
                return .ended
            }
            return nil
        }

        if isSpeech {
            speechRun += duration
            quietRun = 0
            let needed = settings.startDuration + (outputPlaying ? settings.extraStartDurationWhileOutputPlays : 0)
            if speechRun >= needed {
                isSpeaking = true
                utteranceLength = speechRun
                speechRun = 0
                return .started
            }
        } else {
            // A short dip does not reset the count; after that it runs back down at the rate
            // it ran up, so that speech with gaps between syllables still adds up.
            quietRun += duration
            if quietRun > 0.1 { speechRun = max(0, speechRun - duration) }
        }
        return nil
    }

    private mutating func followNoise(level: Float, duration: Double, outputPlaying: Bool) {
        // What the loudspeaker leaks into the microphone says nothing about the room.
        guard !outputPlaying else { return }
        if level < noiseFloor {
            noiseFloor = max(-90, level)
        } else {
            let rate = isSpeaking ? settings.noiseRiseWhileSpeaking : settings.noiseRiseWhileIdle
            noiseFloor = min(level, noiseFloor + rate * Float(duration))
        }
    }

    /// An utterance that started while the app was speaking turned out to be the app's own
    /// voice: more of it reaches the microphone than was assumed.
    public mutating func raiseEchoEstimate(by decibels: Float = 6) {
        if let echoCoupling { self.echoCoupling = echoCoupling + decibels }
    }

    public mutating func reset() {
        isSpeaking = false
        speechRun = 0
        quietRun = 0
        utteranceLength = 0
    }
}
