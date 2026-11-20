import Foundation

/// Timings of one offline batch transcription. All values are wall-clock seconds on a
/// monotonic clock.
public struct BatchTiming: Codable, Sendable, Equatable {
    /// Reading and decoding the audio file into mono float samples.
    /// Start: file read begins. End: canonical samples are in memory. Measured once per recording.
    public var decodeSeconds: Double
    /// Resampling and converting the canonical samples into the engine's input format.
    /// Start: normalization begins. End: engine audio is in memory. Measured once per
    /// recording and engine format.
    public var preprocessSeconds: Double
    /// Time to final transcript for the batch mode.
    /// Start: the runner calls `transcribe(audio:languageHint:)` with audio already in memory.
    /// End: the call returns the final transcript. Excludes decoding and preprocessing.
    public var inferenceSeconds: Double
    /// Duration of the recording in seconds.
    public var audioSeconds: Double

    public init(decodeSeconds: Double, preprocessSeconds: Double, inferenceSeconds: Double, audioSeconds: Double) {
        self.decodeSeconds = decodeSeconds
        self.preprocessSeconds = preprocessSeconds
        self.inferenceSeconds = inferenceSeconds
        self.audioSeconds = audioSeconds
    }

    /// Real-time factor: `inferenceSeconds / audioSeconds`. Below 1 is faster than real time.
    public var realTimeFactor: Double? {
        audioSeconds > 0 ? inferenceSeconds / audioSeconds : nil
    }
}

/// Latencies of one real-time streaming transcription, in seconds.
///
/// Notation: `t0` is the replay start, the instant the first sample of the recording is
/// "spoken". A chunk covering `[a, b)` seconds is delivered to the engine at `t0 + b`.
/// Every event time is the monotonic host time at which the adapter received the result
/// from the engine.
public struct StreamingLatency: Codable, Sendable, Equatable {
    /// Time to first partial transcript.
    /// Start: `t0`. End: first event whose hypothesis text is not empty.
    /// `nil` when the engine produced no hypothesis before the final result.
    public var timeToFirstPartial: Double?
    /// The same instant measured from the start of speech instead of the start of the file:
    /// `timeToFirstPartial - speechStartSeconds`.
    public var firstPartialAfterSpeechStart: Double?
    /// Time to first stable transcript.
    /// Start: `t0`. End: first event whose committed (non-volatile) text is not empty.
    /// When the engine commits nothing before the final result this equals `timeToFinal`
    /// and `stableBeforeFinal` is `false`.
    public var timeToFirstStable: Double
    public var stableBeforeFinal: Bool
    /// Time to final transcript. Start: `t0`. End: the final result event.
    public var timeToFinal: Double
    /// Finalization latency.
    /// Start: the last chunk has been delivered and end of input signalled.
    /// End: the final result event.
    public var endOfAudioToFinal: Double
    /// End-of-speech to final-result latency.
    /// Start: `t0 + speechEndSeconds`, the instant the speaker stops. End: the final result event.
    /// Includes any trailing silence in the file, because the benchmark signals end of input at
    /// the end of the file and performs no endpoint detection of its own.
    public var endOfSpeechToFinal: Double
    /// Number of partial events received.
    public var partialCount: Int
    /// Largest delay between a chunk's scheduled and actual delivery. See `ReplayTimeline`.
    public var replayMaxLatenessSeconds: Double
    /// Where the speech bounds came from: `manifest`, `energy-estimate` or `file-bounds`.
    public var speechBoundsSource: String
    public var audioSeconds: Double
}

/// Speech bounds used for latency calculations.
public struct SpeechBounds: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var source: String

    public init(startSeconds: Double, endSeconds: Double, source: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.source = source
    }

    /// Manifest values when present, otherwise an energy estimate, otherwise the whole file.
    public static func resolve(recording: Recording, audio: DecodedAudio) -> SpeechBounds {
        let duration = audio.durationSeconds
        if let start = recording.speechStartSeconds, let end = recording.speechEndSeconds {
            return SpeechBounds(startSeconds: start, endSeconds: min(end, duration), source: "manifest")
        }
        if let estimate = SpeechBoundsEstimator.estimate(samples: audio.samples, sampleRate: audio.sampleRate) {
            return SpeechBounds(
                startSeconds: recording.speechStartSeconds ?? estimate.startSeconds,
                endSeconds: min(recording.speechEndSeconds ?? estimate.endSeconds, duration),
                source: "energy-estimate"
            )
        }
        return SpeechBounds(startSeconds: 0, endSeconds: duration, source: "file-bounds")
    }
}

/// Collects the events of one streaming transcription and derives the latencies.
public struct StreamingLatencyCollector: Sendable {
    public private(set) var replayStart: Double?
    public private(set) var replayEnd: Double?
    public private(set) var firstPartial: Double?
    public private(set) var firstStable: Double?
    public private(set) var finalTime: Double?
    public private(set) var partialCount = 0
    public private(set) var result: RecognitionResult?

    public init() {}

    public mutating func record(_ event: RecognitionEvent) {
        switch event {
        case .replayStarted(let hostTime):
            replayStart = hostTime
        case .replayFinished(let hostTime):
            replayEnd = hostTime
        case .partial(let partial):
            partialCount += 1
            if firstPartial == nil, !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstPartial = partial.hostTime
            }
            if firstStable == nil, !partial.stableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstStable = partial.hostTime
            }
        case .final(let result, let hostTime):
            self.result = result
            finalTime = hostTime
        }
    }

    /// Returns `nil` until the replay start and the final result have both been seen.
    public func latency(bounds: SpeechBounds, audioSeconds: Double, replayMaxLateness: Double) -> StreamingLatency? {
        guard let start = replayStart, let finalTime else { return nil }
        let end = replayEnd ?? (start + audioSeconds)
        let firstPartialOffset = firstPartial.map { $0 - start }
        return StreamingLatency(
            timeToFirstPartial: firstPartialOffset,
            firstPartialAfterSpeechStart: firstPartialOffset.map { $0 - bounds.startSeconds },
            timeToFirstStable: (firstStable ?? finalTime) - start,
            stableBeforeFinal: firstStable != nil,
            timeToFinal: finalTime - start,
            endOfAudioToFinal: finalTime - end,
            endOfSpeechToFinal: finalTime - (start + bounds.endSeconds),
            partialCount: partialCount,
            replayMaxLatenessSeconds: replayMaxLateness,
            speechBoundsSource: bounds.source,
            audioSeconds: audioSeconds
        )
    }
}

/// Median and 95th percentile of a set of measurements.
public struct Distribution: Codable, Sendable, Equatable {
    public var count: Int
    public var median: Double
    public var p95: Double
    public var min: Double
    public var max: Double

    /// `nil` for an empty set.
    public init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        count = sorted.count
        median = Statistics.percentile(sorted: sorted, 0.5)
        p95 = Statistics.percentile(sorted: sorted, 0.95)
        min = sorted[0]
        max = sorted[sorted.count - 1]
    }
}

public enum Statistics {
    /// Percentile by linear interpolation between the two nearest ranks (the common "type 7"
    /// definition). With few samples the 95th percentile is close to the maximum: for three
    /// repetitions it is `0.1 * middle + 0.9 * largest`.
    public static func percentile(sorted: [Double], _ p: Double) -> Double {
        precondition(!sorted.isEmpty)
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
