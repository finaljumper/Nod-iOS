import XCTest
@testable import ASRBenchCore

final class LatencyMetricsTests: XCTestCase {
    func testMedianAndPercentile() {
        let distribution = Distribution([3, 1, 2])!
        XCTAssertEqual(distribution.median, 2)
        XCTAssertEqual(distribution.p95, 2.9, accuracy: 1e-12)
        XCTAssertEqual(distribution.min, 1)
        XCTAssertEqual(distribution.max, 3)
        XCTAssertEqual(distribution.count, 3)
    }

    func testSingleValueAndEmpty() {
        XCTAssertEqual(Distribution([5])?.p95, 5)
        XCTAssertNil(Distribution([]))
    }

    func testEvenCountMedianInterpolates() {
        XCTAssertEqual(Distribution([1, 2, 3, 4])!.median, 2.5)
    }

    func testRealTimeFactor() {
        let timing = BatchTiming(decodeSeconds: 0.1, preprocessSeconds: 0.2, inferenceSeconds: 0.5, audioSeconds: 4)
        XCTAssertEqual(timing.realTimeFactor, 0.125)
        XCTAssertNil(BatchTiming(decodeSeconds: 0, preprocessSeconds: 0, inferenceSeconds: 1, audioSeconds: 0).realTimeFactor)
    }

    func testStreamingLatencyFromEvents() {
        var collector = StreamingLatencyCollector()
        collector.record(.replayStarted(hostTime: 100))
        collector.record(.partial(PartialTranscript(text: "", stableText: "", hostTime: 100.4)))       // empty: ignored
        collector.record(.partial(PartialTranscript(text: "turn", stableText: "", hostTime: 101.0)))   // first partial
        collector.record(.partial(PartialTranscript(text: "turn on", stableText: "turn", hostTime: 102.5))) // first stable
        collector.record(.replayFinished(hostTime: 104))
        collector.record(.final(RecognitionResult(text: "turn on the lights", inferenceSeconds: 4.6), hostTime: 104.6))

        let bounds = SpeechBounds(startSeconds: 0.5, endSeconds: 3.5, source: "manifest")
        let latency = collector.latency(bounds: bounds, audioSeconds: 4, replayMaxLateness: 0.002)!
        XCTAssertEqual(latency.timeToFirstPartial!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(latency.firstPartialAfterSpeechStart!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(latency.timeToFirstStable, 2.5, accuracy: 1e-9)
        XCTAssertTrue(latency.stableBeforeFinal)
        XCTAssertEqual(latency.timeToFinal, 4.6, accuracy: 1e-9)
        XCTAssertEqual(latency.endOfAudioToFinal, 0.6, accuracy: 1e-9)
        XCTAssertEqual(latency.endOfSpeechToFinal, 1.1, accuracy: 1e-9)
        XCTAssertEqual(latency.partialCount, 3)
        XCTAssertEqual(latency.speechBoundsSource, "manifest")
    }

    func testStableFallsBackToFinalWhenNothingWasCommitted() {
        var collector = StreamingLatencyCollector()
        collector.record(.replayStarted(hostTime: 10))
        collector.record(.replayFinished(hostTime: 12))
        collector.record(.final(RecognitionResult(text: "ok", inferenceSeconds: 2.3), hostTime: 12.3))
        let latency = collector.latency(bounds: SpeechBounds(startSeconds: 0, endSeconds: 2, source: "file-bounds"), audioSeconds: 2, replayMaxLateness: 0)!
        XCTAssertNil(latency.timeToFirstPartial)
        XCTAssertFalse(latency.stableBeforeFinal)
        XCTAssertEqual(latency.timeToFirstStable, latency.timeToFinal)
    }

    func testNoLatencyWithoutFinalResult() {
        var collector = StreamingLatencyCollector()
        collector.record(.replayStarted(hostTime: 1))
        XCTAssertNil(collector.latency(bounds: SpeechBounds(startSeconds: 0, endSeconds: 1, source: "x"), audioSeconds: 1, replayMaxLateness: 0))
    }
}
