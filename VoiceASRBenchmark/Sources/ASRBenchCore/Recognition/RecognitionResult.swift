import Foundation

/// A recognized word with its position in the source audio.
public struct RecognizedWord: Codable, Sendable, Equatable {
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var confidence: Double?

    public init(text: String, startSeconds: Double, endSeconds: Double, confidence: Double? = nil) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }
}

/// A recognized phrase or segment.
public struct RecognizedSegment: Codable, Sendable, Equatable {
    public var text: String
    /// Position in the source audio in seconds, when the engine reports it.
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var words: [RecognizedWord]?

    public init(text: String, startSeconds: Double? = nil, endSeconds: Double? = nil, words: [RecognizedWord]? = nil) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.words = words
    }
}

/// The final outcome of one transcription.
public struct RecognitionResult: Codable, Sendable, Equatable {
    /// Full transcript exactly as the engine produced it, before any normalization.
    public var text: String
    public var segments: [RecognizedSegment]
    /// Language the engine detected, when it detects languages.
    public var detectedLanguage: String?
    /// Language or locale the engine actually used (for example the resolved locale `ko-KR`).
    public var languageUsed: String?
    /// Wall time the engine spent inside its own inference call, in seconds. Start: the adapter
    /// hands the first audio to the engine. End: the engine delivers its last result.
    public var inferenceSeconds: Double
    /// Engine-reported internal timings (for example encoder and decoder time), in seconds.
    public var engineTimings: [String: Double]
    /// Capabilities that were requested but not delivered in this run, with reasons.
    public var notes: [String]

    public init(
        text: String,
        segments: [RecognizedSegment] = [],
        detectedLanguage: String? = nil,
        languageUsed: String? = nil,
        inferenceSeconds: Double,
        engineTimings: [String: Double] = [:],
        notes: [String] = []
    ) {
        self.text = text
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.languageUsed = languageUsed
        self.inferenceSeconds = inferenceSeconds
        self.engineTimings = engineTimings
        self.notes = notes
    }
}

/// One hypothesis emitted while streaming.
public struct PartialTranscript: Sendable, Equatable {
    /// Full hypothesis so far: stable text followed by volatile text.
    public var text: String
    /// The part of `text` the engine has committed to and will not change.
    public var stableText: String
    /// Monotonic host time when the adapter received this hypothesis, see `MonotonicClock`.
    public var hostTime: Double

    public init(text: String, stableText: String, hostTime: Double) {
        self.text = text
        self.stableText = stableText
        self.hostTime = hostTime
    }
}

/// Events of a streaming transcription. Every event carries a monotonic host timestamp taken by
/// the adapter at the moment the engine delivered it, so latency does not depend on how quickly
/// the consumer reads the stream.
public enum RecognitionEvent: Sendable {
    /// The first audio chunk was handed to the engine. Latencies are measured from here.
    case replayStarted(hostTime: Double)
    /// A tentative or partially committed hypothesis.
    case partial(PartialTranscript)
    /// The last audio chunk was handed to the engine and end of input was signalled.
    case replayFinished(hostTime: Double)
    /// The final transcript. Always the last event.
    case final(RecognitionResult, hostTime: Double)
}

/// Monotonic clock shared by all latency measurements.
public enum MonotonicClock {
    /// Seconds on a monotonic clock with an arbitrary origin. Only differences are meaningful.
    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
