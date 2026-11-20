import Foundation

/// One slice of a recording handed to an engine during a streaming replay.
public struct AudioChunk: Sendable, Equatable {
    public var index: Int
    /// Sample range in the engine audio.
    public var sampleRange: Range<Int>
    /// Position of the first sample in the recording, in seconds.
    public var startSeconds: Double
    /// Position just past the last sample, in seconds. In a real-time replay the chunk is
    /// delivered at this offset from the replay start, as a microphone would deliver it.
    public var endSeconds: Double
    public var isLast: Bool
}

/// Clock used to pace a replay. Tests inject a fake clock.
public protocol ReplayClock: Sendable {
    /// Monotonic seconds, on the same timeline as `MonotonicClock.now()`.
    func now() -> Double
    /// Suspends until `deadline`. Returns immediately if the deadline has passed.
    func sleep(until deadline: Double) async throws
}

public struct SystemReplayClock: ReplayClock {
    public init() {}

    public func now() -> Double { MonotonicClock.now() }

    public func sleep(until deadline: Double) async throws {
        let remaining = deadline - now()
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }
}

/// What actually happened during a replay.
public struct ReplayTimeline: Sendable, Equatable {
    /// Host time of the replay start. The first sample of the recording corresponds to this instant.
    public var startHostTime: Double
    /// Host time at which the last chunk was delivered.
    public var endHostTime: Double
    /// Largest delay between a chunk's scheduled and actual delivery, in seconds. A large value
    /// means the replay could not keep real-time pace (for example because the engine blocked
    /// the delivery), and streaming latencies of that run should be treated with caution.
    public var maxLatenessSeconds: Double
    public var chunkCount: Int
}

/// Deterministic chunked replay of prerecorded audio.
///
/// In real-time mode chunk `i`, covering `[start, end)` seconds of the recording, is delivered at
/// `replayStart + end`: the moment a live microphone would have finished capturing it. Deadlines
/// are computed from the replay start, so pacing errors do not accumulate. In fast mode all
/// chunks are delivered back to back.
public struct AudioReplay: Sendable {
    public let chunks: [AudioChunk]
    public let realTime: Bool
    private let clock: any ReplayClock

    public init(sampleCount: Int, sampleRate: Double, options: StreamingOptions, clock: any ReplayClock = SystemReplayClock()) {
        self.chunks = Self.makeChunks(sampleCount: sampleCount, sampleRate: sampleRate, chunkSeconds: options.chunkSeconds)
        self.realTime = options.realTime
        self.clock = clock
    }

    public static func makeChunks(sampleCount: Int, sampleRate: Double, chunkSeconds: Double) -> [AudioChunk] {
        guard sampleCount > 0, sampleRate > 0 else { return [] }
        let size = max(1, Int((sampleRate * chunkSeconds).rounded()))
        var chunks: [AudioChunk] = []
        var start = 0
        while start < sampleCount {
            let end = min(sampleCount, start + size)
            chunks.append(AudioChunk(
                index: chunks.count,
                sampleRange: start..<end,
                startSeconds: Double(start) / sampleRate,
                endSeconds: Double(end) / sampleRate,
                isLast: end == sampleCount
            ))
            start = end
        }
        return chunks
    }

    /// Runs the replay.
    ///
    /// - Parameters:
    ///   - onStart: Called once with the replay start host time, before the first chunk.
    ///   - deliver: Receives each chunk in order. Should return quickly; time spent here delays
    ///     later chunks and is reported as lateness.
    public func run(
        onStart: @Sendable (Double) -> Void = { _ in },
        deliver: @Sendable (AudioChunk) async throws -> Void
    ) async throws -> ReplayTimeline {
        let start = clock.now()
        onStart(start)
        var maxLateness = 0.0
        var end = start
        for chunk in chunks {
            try Task.checkCancellation()
            if realTime {
                let deadline = start + chunk.endSeconds
                try await clock.sleep(until: deadline)
                maxLateness = max(maxLateness, clock.now() - deadline)
            }
            try await deliver(chunk)
            end = clock.now()
        }
        return ReplayTimeline(startHostTime: start, endHostTime: end, maxLatenessSeconds: maxLateness, chunkCount: chunks.count)
    }
}
