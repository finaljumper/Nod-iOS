import Foundation

/// Audio in the exact form one engine consumes: mono, at the engine's sample rate and encoding.
public struct EngineAudio: Sendable, Equatable {
    /// Mono float samples at `format.sampleRate`.
    public var samples: [Float]
    /// The same samples as 16-bit integers, present when `format.encoding == .int16`.
    public var int16Samples: [Int16]?
    public var format: EngineAudioFormat
    /// Fingerprint of the canonical decoded audio these samples were derived from.
    public var sourceFingerprint: String
    /// Wall time spent resampling and converting, in seconds. Not part of inference time.
    public var preprocessSeconds: Double

    public init(
        samples: [Float],
        int16Samples: [Int16]? = nil,
        format: EngineAudioFormat,
        sourceFingerprint: String,
        preprocessSeconds: Double
    ) {
        self.samples = samples
        self.int16Samples = int16Samples
        self.format = format
        self.sourceFingerprint = sourceFingerprint
        self.preprocessSeconds = preprocessSeconds
    }

    public var durationSeconds: Double {
        format.sampleRate > 0 ? Double(samples.count) / format.sampleRate : 0
    }
}

/// Converts canonical decoded audio into the format an engine requires.
///
/// Resampling uses one deterministic pure Swift resampler for every engine. Two engines that
/// ask for the same sample rate therefore receive identical samples, and an engine that needs
/// 16-bit integers receives the rounded version of those same samples.
public enum AudioNormalizer {
    public static func normalize(_ audio: DecodedAudio, to format: EngineAudioFormat) -> EngineAudio {
        let start = MonotonicClock.now()
        let resampled = resample(audio.samples, from: audio.sampleRate, to: format.sampleRate)
        let ints = format.encoding == .int16 ? int16(from: resampled) : nil
        return EngineAudio(
            samples: resampled,
            int16Samples: ints,
            format: format,
            sourceFingerprint: audio.fingerprint,
            preprocessSeconds: MonotonicClock.now() - start
        )
    }

    /// Rounds float samples to 16-bit integers, clamping to the valid range.
    public static func int16(from samples: [Float]) -> [Int16] {
        samples.map { sample in
            let scaled = (Double(sample) * 32767.0).rounded()
            return Int16(max(-32768.0, min(32767.0, scaled)))
        }
    }

    /// Number of sinc zero crossings on each side of the kernel centre.
    static let zeroCrossings = 16
    /// Fraction of the Nyquist band that is passed, leaving a transition band for the filter.
    static let rolloff = 0.945
    static let kaiserBeta = 8.6

    /// Band-limited resampling with a Kaiser-windowed sinc kernel.
    ///
    /// Integer sample rates use an exact polyphase filter bank. The output has
    /// `round(count * to / from)` samples. Input outside the signal is treated as silence.
    public static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard sourceRate > 0, targetRate > 0, !input.isEmpty else { return [] }
        if sourceRate == targetRate { return input }

        let ratio = targetRate / sourceRate
        let outputCount = Int((Double(input.count) * ratio).rounded())
        guard outputCount > 0 else { return [] }

        // Cutoff in cycles per input sample.
        let cutoff = 0.5 * min(1.0, ratio) * rolloff
        let halfWidth = Double(zeroCrossings) / (2.0 * cutoff)
        let reach = Int(halfWidth.rounded(.up))
        let tapCount = 2 * reach

        func kernel(_ t: Double) -> Double {
            let x = t / halfWidth
            guard abs(x) < 1 else { return 0 }
            let window = besselI0(kaiserBeta * (1 - x * x).squareRoot()) / besselI0(kaiserBeta)
            let arg = 2.0 * cutoff * t
            let sinc = arg == 0 ? 1.0 : sin(Double.pi * arg) / (Double.pi * arg)
            return 2.0 * cutoff * sinc * window
        }

        /// Taps for an output sample whose position is `fraction` past an input sample.
        /// Tap `k` (0-based) multiplies the input sample at offset `k - reach + 1`.
        func taps(for fraction: Double) -> [Double] {
            var values = [Double](repeating: 0, count: tapCount)
            var sum = 0.0
            for k in 0..<tapCount {
                let offset = Double(k - reach + 1)
                values[k] = kernel(fraction - offset)
                sum += values[k]
            }
            // Unity gain at DC for every phase.
            if sum != 0 { for k in 0..<tapCount { values[k] /= sum } }
            return values
        }

        var output = [Float](repeating: 0, count: outputCount)
        let count = input.count

        func apply(_ taps: [Double], at base: Int) -> Float {
            var acc = 0.0
            let first = base - reach + 1
            let lower = max(0, -first)
            let upper = min(tapCount, count - first)
            if lower < upper {
                for k in lower..<upper {
                    acc += Double(input[first + k]) * taps[k]
                }
            }
            return Float(acc)
        }

        let src = Int(sourceRate), dst = Int(targetRate)
        if Double(src) == sourceRate, Double(dst) == targetRate {
            let divisor = gcd(src, dst)
            let up = dst / divisor       // number of phases
            let down = src / divisor
            var bank = [[Double]?](repeating: nil, count: up)
            for i in 0..<outputCount {
                let position = i * down
                let base = position / up
                let phase = position % up
                if bank[phase] == nil {
                    bank[phase] = taps(for: Double(phase) / Double(up))
                }
                output[i] = apply(bank[phase]!, at: base)
            }
        } else {
            for i in 0..<outputCount {
                let position = Double(i) / ratio
                let base = Int(position.rounded(.down))
                output[i] = apply(taps(for: position - Double(base)), at: base)
            }
        }
        return output
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Modified Bessel function of the first kind, order zero.
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let half = x / 2
        var k = 1.0
        while term > 1e-12 * sum {
            term *= (half / k) * (half / k)
            sum += term
            k += 1
        }
        return sum
    }
}

/// Estimates where speech starts and ends from signal energy.
///
/// Used only when the manifest does not give speech bounds. The estimate is deterministic and
/// identical for all engines, but it is a simple energy gate, not a voice activity detector.
public enum SpeechBoundsEstimator {
    public struct Bounds: Sendable, Equatable {
        public var startSeconds: Double
        public var endSeconds: Double
    }

    /// - Parameters:
    ///   - thresholdDB: Frames louder than the loudest frame plus this (negative) value count as speech.
    public static func estimate(samples: [Float], sampleRate: Double, frameSeconds: Double = 0.02, thresholdDB: Double = -35) -> Bounds? {
        let frame = max(1, Int(sampleRate * frameSeconds))
        guard samples.count >= frame else { return nil }
        var energies: [Double] = []
        var index = 0
        while index + frame <= samples.count {
            var sum = 0.0
            for i in index..<(index + frame) { sum += Double(samples[i]) * Double(samples[i]) }
            energies.append(sum / Double(frame))
            index += frame
        }
        guard let peak = energies.max(), peak > 0 else { return nil }
        let threshold = peak * pow(10.0, thresholdDB / 10.0)
        guard let first = energies.firstIndex(where: { $0 >= threshold }),
              let last = energies.lastIndex(where: { $0 >= threshold })
        else { return nil }
        return Bounds(
            startSeconds: Double(first * frame) / sampleRate,
            endSeconds: Double((last + 1) * frame) / sampleRate
        )
    }
}
