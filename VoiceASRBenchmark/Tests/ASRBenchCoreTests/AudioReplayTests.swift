import XCTest
@testable import ASRBenchCore

/// Synthetic test tones. These exercise the audio pipeline only and are never used as
/// benchmark recordings.
enum TestSignal {
    static func sine(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    /// Amplitude of one frequency component (single-bin DFT).
    static func amplitude(of frequency: Double, in samples: ArraySlice<Float>, sampleRate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (offset, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(offset) / sampleRate
            re += Double(sample) * cos(phase)
            im += Double(sample) * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(samples.count)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("asrbench-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A clock that advances only when asked to sleep.
final class FakeReplayClock: ReplayClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double
    private(set) var sleeps: [Double] = []

    init(start: Double = 1000) { time = start }

    func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        return time
    }

    func sleep(until deadline: Double) async throws {
        recordSleep(until: deadline)
    }

    private func recordSleep(until deadline: Double) {
        lock.lock()
        sleeps.append(deadline)
        if deadline > time { time = deadline }
        lock.unlock()
    }

    func advance(_ seconds: Double) {
        lock.lock(); time += seconds; lock.unlock()
    }
}

final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class WAVDecoderTests: XCTestCase {
    func testPCM16RoundTrip() throws {
        let samples = TestSignal.sine(frequency: 440, sampleRate: 16_000, seconds: 0.5)
        let data = WAVWriter.pcm16Data(samples: samples, sampleRate: 16_000)
        let decoded = try WAVDecoder.decode(data: data)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.sourceChannels, 1)
        XCTAssertEqual(decoded.sourceFormat, "pcm_s16le")
        XCTAssertEqual(decoded.samples.count, samples.count)
        XCTAssertEqual(decoded.durationSeconds, 0.5, accuracy: 1e-9)
        for (a, b) in zip(decoded.samples, samples) {
            XCTAssertEqual(a, b, accuracy: 1.0 / 16_384)
        }
    }

    func testDecodingIsDeterministic() throws {
        let data = WAVWriter.pcm16Data(samples: TestSignal.sine(frequency: 300, sampleRate: 16_000, seconds: 0.2), sampleRate: 16_000)
        let first = try WAVDecoder.decode(data: data)
        let second = try WAVDecoder.decode(data: data)
        XCTAssertEqual(first.samples, second.samples)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint.count, 16)
    }

    func testFingerprintChangesWithContent() {
        XCTAssertNotEqual(AudioFingerprint.hex(of: [0, 0.5, 0]), AudioFingerprint.hex(of: [0, 0.5, 0.001]))
    }

    private func wav(formatTag: UInt16, channels: UInt16, sampleRate: UInt32, bits: UInt16, payload: [UInt8], extensible: Bool = false, extraChunk: Bool = false) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(0); data.append(contentsOf: Array("WAVE".utf8))
        if extraChunk {
            // Odd-sized chunk before fmt: the decoder must skip it and its pad byte.
            data.append(contentsOf: Array("LIST".utf8)); u32(3); data.append(contentsOf: [1, 2, 3, 0])
        }
        data.append(contentsOf: Array("fmt ".utf8))
        let blockAlign = channels * bits / 8
        if extensible {
            u32(40); u16(0xFFFE); u16(channels); u32(sampleRate); u32(sampleRate * UInt32(blockAlign)); u16(blockAlign); u16(bits)
            u16(22); u16(bits); u32(0)
            u16(formatTag); data.append(contentsOf: [UInt8](repeating: 0, count: 14))
        } else {
            u32(16); u16(formatTag); u16(channels); u32(sampleRate); u32(sampleRate * UInt32(blockAlign)); u16(blockAlign); u16(bits)
        }
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(payload.count)); data.append(contentsOf: payload)
        return data
    }

    func testStereoIsDownmixedByAveraging() throws {
        // Two frames: (L=+16384, R=0) and (L=-16384, R=-16384).
        let payload: [UInt8] = [0x00, 0x40, 0x00, 0x00, 0x00, 0xC0, 0x00, 0xC0]
        let decoded = try WAVDecoder.decode(data: wav(formatTag: 1, channels: 2, sampleRate: 48_000, bits: 16, payload: payload))
        XCTAssertEqual(decoded.sourceChannels, 2)
        XCTAssertEqual(decoded.samples, [0.25, -0.5])
    }

    func test24BitAndSignExtension() throws {
        // +0.5 (0x400000) and -0.5 (0xC00000) as 24-bit little endian.
        let payload: [UInt8] = [0x00, 0x00, 0x40, 0x00, 0x00, 0xC0]
        let decoded = try WAVDecoder.decode(data: wav(formatTag: 1, channels: 1, sampleRate: 44_100, bits: 24, payload: payload))
        XCTAssertEqual(decoded.sourceFormat, "pcm_s24le")
        XCTAssertEqual(decoded.samples, [0.5, -0.5])
    }

    func testFloat32AndExtensibleHeaderAndSkippedChunk() throws {
        var payload: [UInt8] = []
        for value in [Float(0.25), Float(-0.75)] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { payload.append(contentsOf: $0) }
        }
        let decoded = try WAVDecoder.decode(data: wav(formatTag: 3, channels: 1, sampleRate: 16_000, bits: 32, payload: payload, extensible: true, extraChunk: true))
        XCTAssertEqual(decoded.sourceFormat, "pcm_f32le")
        XCTAssertEqual(decoded.samples, [0.25, -0.75])
    }

    func testCompressedFormatIsRejected() {
        XCTAssertThrowsError(try WAVDecoder.decode(data: wav(formatTag: 0x55, channels: 1, sampleRate: 16_000, bits: 16, payload: [0, 0]))) { error in
            guard case AudioDecodingError.unsupportedFormat = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try WAVDecoder.decode(data: Data("not a wav file at all".utf8)))
        XCTAssertThrowsError(try WAVDecoder.decode(data: Data()))
    }

    func testHeaderOnlyRead() throws {
        let data = WAVWriter.pcm16Data(samples: [Float](repeating: 0, count: 8_000), sampleRate: 16_000)
        let header = try WAVDecoder.readHeader(data: data)
        XCTAssertEqual(header.frameCount, 8_000)
        XCTAssertEqual(header.durationSeconds, 0.5)
        XCTAssertEqual(header.channels, 1)
    }

    func testLoaderReportsMissingFileAndUnknownExtension() throws {
        let directory = try TestSignal.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try AudioFileLoader.standard.decode(url: directory.appendingPathComponent("missing.wav"))) { error in
            guard case AudioDecodingError.fileNotFound = error else { return XCTFail("unexpected error \(error)") }
        }
        let other = directory.appendingPathComponent("clip.mp3")
        try Data([0]).write(to: other)
        XCTAssertThrowsError(try AudioFileLoader.standard.decode(url: other)) { error in
            guard case AudioDecodingError.unsupportedFormat = error else { return XCTFail("unexpected error \(error)") }
        }
    }
}

final class AudioNormalizerTests: XCTestCase {
    func testSameRateIsUntouched() {
        let samples = TestSignal.sine(frequency: 200, sampleRate: 16_000, seconds: 0.1)
        XCTAssertEqual(AudioNormalizer.resample(samples, from: 16_000, to: 16_000), samples)
    }

    func testDownsamplingPreservesAToneInBand() {
        let input = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, seconds: 1)
        let output = AudioNormalizer.resample(input, from: 48_000, to: 16_000)
        XCTAssertEqual(output.count, 16_000)
        let middle = output[2_000..<14_000]
        XCTAssertEqual(TestSignal.amplitude(of: 1_000, in: middle, sampleRate: 16_000), 0.5, accuracy: 0.005)
    }

    func testDownsamplingRemovesAToneAboveTheNewNyquist() {
        // 12 kHz cannot be represented at 16 kHz and must not alias into the band.
        let input = TestSignal.sine(frequency: 12_000, sampleRate: 48_000, seconds: 1)
        let output = AudioNormalizer.resample(input, from: 48_000, to: 16_000)
        XCTAssertLessThan(TestSignal.rms(output[2_000..<14_000]), 0.001)
    }

    func testNonIntegerRatio() {
        let input = TestSignal.sine(frequency: 440, sampleRate: 44_100, seconds: 1)
        let output = AudioNormalizer.resample(input, from: 44_100, to: 16_000)
        XCTAssertEqual(output.count, 16_000)
        XCTAssertEqual(TestSignal.amplitude(of: 440, in: output[2_000..<14_000], sampleRate: 16_000), 0.5, accuracy: 0.005)
    }

    func testUpsampling() {
        let input = TestSignal.sine(frequency: 440, sampleRate: 8_000, seconds: 1)
        let output = AudioNormalizer.resample(input, from: 8_000, to: 16_000)
        XCTAssertEqual(output.count, 16_000)
        XCTAssertEqual(TestSignal.amplitude(of: 440, in: output[2_000..<14_000], sampleRate: 16_000), 0.5, accuracy: 0.005)
    }

    func testResamplingIsDeterministic() {
        let input = TestSignal.sine(frequency: 700, sampleRate: 44_100, seconds: 0.3)
        XCTAssertEqual(
            AudioNormalizer.resample(input, from: 44_100, to: 16_000),
            AudioNormalizer.resample(input, from: 44_100, to: 16_000)
        )
    }

    func testInt16ConversionClampsAndRounds() {
        XCTAssertEqual(AudioNormalizer.int16(from: [0, 1, -1, 2, -2, 0.5]), [0, 32767, -32767, 32767, -32768, 16384])
    }

    func testEnginesWithTheSameRateGetIdenticalSamples() {
        let decoded = DecodedAudio(
            samples: TestSignal.sine(frequency: 500, sampleRate: 48_000, seconds: 0.5),
            sampleRate: 48_000, sourceChannels: 1, sourceFormat: "pcm_s16le", decodeSeconds: 0
        )
        let float = AudioNormalizer.normalize(decoded, to: EngineAudioFormat(sampleRate: 16_000, encoding: .float32))
        let integer = AudioNormalizer.normalize(decoded, to: EngineAudioFormat(sampleRate: 16_000, encoding: .int16))
        XCTAssertEqual(float.samples, integer.samples)
        XCTAssertNil(float.int16Samples)
        XCTAssertEqual(integer.int16Samples, AudioNormalizer.int16(from: float.samples))
        XCTAssertEqual(float.sourceFingerprint, decoded.fingerprint)
        XCTAssertEqual(integer.sourceFingerprint, decoded.fingerprint)
        XCTAssertEqual(float.durationSeconds, 0.5, accuracy: 1e-9)
    }

    func testSpeechBoundsEstimate() {
        // 0.5 s silence, 1 s tone, 0.5 s silence.
        let silence = [Float](repeating: 0, count: 8_000)
        let samples = silence + TestSignal.sine(frequency: 300, sampleRate: 16_000, seconds: 1) + silence
        let bounds = SpeechBoundsEstimator.estimate(samples: samples, sampleRate: 16_000)!
        XCTAssertEqual(bounds.startSeconds, 0.5, accuracy: 0.03)
        XCTAssertEqual(bounds.endSeconds, 1.5, accuracy: 0.03)
        XCTAssertNil(SpeechBoundsEstimator.estimate(samples: silence, sampleRate: 16_000))
    }
}

final class AudioReplayTests: XCTestCase {
    func testChunksCoverTheAudioExactlyOnce() {
        let chunks = AudioReplay.makeChunks(sampleCount: 16_000 + 800, sampleRate: 16_000, chunkSeconds: 0.1)
        XCTAssertEqual(chunks.count, 11)
        XCTAssertEqual(chunks.first?.sampleRange, 0..<1_600)
        XCTAssertEqual(chunks.last?.sampleRange, 16_000..<16_800)
        XCTAssertEqual(chunks.filter(\.isLast).count, 1)
        XCTAssertTrue(chunks.last!.isLast)
        var next = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.sampleRange.lowerBound, next)
            next = chunk.sampleRange.upperBound
        }
        XCTAssertEqual(next, 16_800)
        XCTAssertEqual(chunks.last!.endSeconds, 1.05, accuracy: 1e-9)
    }

    func testEmptyAudioHasNoChunks() {
        XCTAssertTrue(AudioReplay.makeChunks(sampleCount: 0, sampleRate: 16_000, chunkSeconds: 0.1).isEmpty)
    }

    func testRealTimeReplayDeliversEachChunkAtItsEndTime() async throws {
        let clock = FakeReplayClock(start: 1000)
        let replay = AudioReplay(sampleCount: 4_800, sampleRate: 16_000, options: StreamingOptions(chunkSeconds: 0.1, realTime: true), clock: clock)
        let delivered = Collected<(Int, Double)>()
        let timeline = try await replay.run { chunk in
            delivered.append((chunk.index, clock.now()))
        }
        XCTAssertEqual(delivered.values.map(\.0), [0, 1, 2])
        let times = delivered.values.map(\.1)
        XCTAssertEqual(times[0], 1000.1, accuracy: 1e-9)
        XCTAssertEqual(times[1], 1000.2, accuracy: 1e-9)
        XCTAssertEqual(times[2], 1000.3, accuracy: 1e-9)
        XCTAssertEqual(timeline.startHostTime, 1000)
        XCTAssertEqual(timeline.endHostTime, 1000.3, accuracy: 1e-9)
        XCTAssertEqual(timeline.maxLatenessSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(timeline.chunkCount, 3)
    }

    func testSlowConsumerIsReportedAsLatenessWithoutDrift() async throws {
        let clock = FakeReplayClock(start: 0)
        let replay = AudioReplay(sampleCount: 4_800, sampleRate: 16_000, options: StreamingOptions(chunkSeconds: 0.1, realTime: true), clock: clock)
        let delivered = Collected<Double>()
        let timeline = try await replay.run { chunk in
            delivered.append(clock.now())
            if chunk.index == 0 { clock.advance(0.15) }   // the engine blocks for 150 ms
        }
        // Chunk 1 was due at 0.2 but arrives at 0.25; chunk 2 is back on schedule at 0.3.
        XCTAssertEqual(delivered.values[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(delivered.values[2], 0.3, accuracy: 1e-9)
        XCTAssertEqual(timeline.maxLatenessSeconds, 0.05, accuracy: 1e-9)
    }

    func testFastReplayDoesNotSleep() async throws {
        let clock = FakeReplayClock()
        let replay = AudioReplay(sampleCount: 16_000, sampleRate: 16_000, options: StreamingOptions(chunkSeconds: 0.1, realTime: false), clock: clock)
        let count = Collected<Int>()
        _ = try await replay.run { count.append($0.index) }
        XCTAssertEqual(count.values.count, 10)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testSystemClockReplayTakesAboutTheAudioDuration() async throws {
        let replay = AudioReplay(sampleCount: 4_800, sampleRate: 16_000, options: StreamingOptions(chunkSeconds: 0.05, realTime: true))
        let start = MonotonicClock.now()
        let timeline = try await replay.run { _ in }
        let elapsed = MonotonicClock.now() - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 0.6)
        XCTAssertEqual(timeline.endHostTime - timeline.startHostTime, elapsed, accuracy: 0.05)
    }

    func testReplayStopsWhenCancelled() async throws {
        let replay = AudioReplay(sampleCount: 160_000, sampleRate: 16_000, options: StreamingOptions(chunkSeconds: 0.1, realTime: true))
        let count = Collected<Int>()
        let task = Task { try await replay.run { count.append($0.index) } }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertLessThan(count.values.count, 10)
    }
}
