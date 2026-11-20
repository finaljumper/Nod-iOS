import Foundation

/// A decoded recording: mono 32-bit float samples at the file's native sample rate.
///
/// This is the single canonical representation every engine's input is derived from.
public struct DecodedAudio: Sendable, Equatable {
    /// Mono samples in the range -1...1.
    public var samples: [Float]
    public var sampleRate: Double
    /// Channel count of the source file before the downmix.
    public var sourceChannels: Int
    /// Sample format of the source file, for the record (for example `pcm_s16le`).
    public var sourceFormat: String
    /// Wall time spent reading and decoding the file, in seconds.
    public var decodeSeconds: Double

    public init(samples: [Float], sampleRate: Double, sourceChannels: Int, sourceFormat: String, decodeSeconds: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sourceChannels = sourceChannels
        self.sourceFormat = sourceFormat
        self.decodeSeconds = decodeSeconds
    }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// 64-bit FNV-1a hash of the sample bytes. Stored with every result so that two runs can be
    /// shown to have used identical audio.
    public var fingerprint: String {
        AudioFingerprint.hex(of: samples)
    }
}

public enum AudioFingerprint {
    public static func hex(of samples: [Float]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for sample in samples {
            var bits = sample.bitPattern
            for _ in 0..<4 {
                hash ^= UInt64(bits & 0xff)
                hash = hash &* 0x0000_0100_0000_01b3
                bits >>= 8
            }
        }
        return String(hash, radix: 16).leftPadded(to: 16)
    }
}

extension String {
    func leftPadded(to length: Int, with pad: Character = "0") -> String {
        count >= length ? self : String(repeating: pad, count: length - count) + self
    }
}

public enum AudioDecodingError: Error, Sendable, Equatable, CustomStringConvertible {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): return "Audio file not found: \(path)"
        case .unsupportedFormat(let reason): return "Unsupported audio format: \(reason)"
        case .malformed(let reason): return "Malformed audio file: \(reason)"
        }
    }
}

/// Decodes an audio file into `DecodedAudio`.
public protocol AudioDecoding: Sendable {
    /// Whether this decoder handles the file at `url`.
    func canDecode(url: URL) -> Bool
    func decode(url: URL) throws -> DecodedAudio
}

/// Tries a list of decoders in order.
public struct AudioFileLoader: AudioDecoding {
    public var decoders: [any AudioDecoding]

    public init(decoders: [any AudioDecoding]) {
        self.decoders = decoders
    }

    /// WAV only. The app adds an AVFoundation decoder for other lossless containers.
    public static let standard = AudioFileLoader(decoders: [WAVDecoder()])

    public func canDecode(url: URL) -> Bool {
        decoders.contains { $0.canDecode(url: url) }
    }

    public func decode(url: URL) throws -> DecodedAudio {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioDecodingError.fileNotFound(url.path)
        }
        guard let decoder = decoders.first(where: { $0.canDecode(url: url) }) else {
            throw AudioDecodingError.unsupportedFormat("no decoder for .\(url.pathExtension)")
        }
        return try decoder.decode(url: url)
    }
}

/// Pure Swift RIFF/WAVE decoder.
///
/// Decoding is done here rather than by a platform converter so that the samples are bit-for-bit
/// reproducible on every device and OS version. Supports uncompressed PCM (8, 16, 24 and 32 bit
/// integer) and IEEE float (32 and 64 bit), including `WAVE_FORMAT_EXTENSIBLE`. Multichannel
/// files are downmixed to mono by averaging the channels.
public struct WAVDecoder: AudioDecoding {
    public init() {}

    public func canDecode(url: URL) -> Bool {
        ["wav", "wave"].contains(url.pathExtension.lowercased())
    }

    public func decode(url: URL) throws -> DecodedAudio {
        let start = MonotonicClock.now()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AudioDecodingError.fileNotFound(url.path)
        }
        var decoded = try Self.decode(data: data)
        decoded.decodeSeconds = MonotonicClock.now() - start
        return decoded
    }

    /// Header fields of a WAV file, read without decoding the samples.
    public struct Header: Sendable, Equatable {
        public var formatTag: UInt16
        public var channels: Int
        public var sampleRate: Double
        public var bitsPerSample: Int
        public var frameCount: Int
        public var durationSeconds: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    }

    private struct Layout {
        var header: Header
        var dataRange: Range<Int>
    }

    public static func readHeader(data: Data) throws -> Header {
        try layout(of: data).header
    }

    public static func readHeader(url: URL) throws -> Header {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw AudioDecodingError.fileNotFound(url.path)
        }
        return try readHeader(data: data)
    }

    private static func layout(of data: Data) throws -> Layout {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count == 12,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE"
        else {
            throw AudioDecodingError.malformed("missing RIFF/WAVE header")
        }

        var offset = 12
        var formatTag: UInt16?
        var channels = 0
        var sampleRate = 0.0
        var bitsPerSample = 0
        var blockAlign = 0
        var dataRange: Range<Int>?

        let count = data.count
        func u16(_ at: Int) -> UInt16 {
            UInt16(data[data.startIndex + at]) | UInt16(data[data.startIndex + at + 1]) << 8
        }
        func u32(_ at: Int) -> UInt32 {
            UInt32(u16(at)) | UInt32(u16(at + 2)) << 16
        }

        while offset + 8 <= count {
            let idBytes = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + 4)])
            let id = String(decoding: idBytes, as: UTF8.self)
            var size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                guard size >= 16, body + 16 <= count else {
                    throw AudioDecodingError.malformed("truncated fmt chunk")
                }
                var tag = u16(body)
                channels = Int(u16(body + 2))
                sampleRate = Double(u32(body + 4))
                blockAlign = Int(u16(body + 12))
                bitsPerSample = Int(u16(body + 14))
                if tag == 0xFFFE {
                    // WAVE_FORMAT_EXTENSIBLE: the real format is the first two bytes of the SubFormat GUID.
                    guard size >= 40, body + 26 <= count else {
                        throw AudioDecodingError.malformed("truncated extensible fmt chunk")
                    }
                    tag = u16(body + 24)
                }
                formatTag = tag
            } else if id == "data" {
                // Streamed files may carry a zero or maximal size; use the rest of the file then.
                if size == 0 || size == 0xFFFF_FFFF || body + size > count {
                    size = count - body
                }
                dataRange = body..<(body + size)
                break
            }
            offset = body + size + (size & 1)
        }

        guard let formatTag else { throw AudioDecodingError.malformed("no fmt chunk") }
        guard let dataRange else { throw AudioDecodingError.malformed("no data chunk") }
        guard channels > 0, sampleRate > 0, bitsPerSample > 0 else {
            throw AudioDecodingError.malformed("invalid fmt chunk")
        }
        guard formatTag == 1 || formatTag == 3 else {
            throw AudioDecodingError.unsupportedFormat("WAV format tag \(formatTag); only uncompressed PCM and IEEE float are lossless")
        }
        let bytesPerSample = bitsPerSample / 8
        let frameSize = max(blockAlign, bytesPerSample * channels)
        guard frameSize > 0 else { throw AudioDecodingError.malformed("zero frame size") }
        let header = Header(
            formatTag: formatTag,
            channels: channels,
            sampleRate: sampleRate,
            bitsPerSample: bitsPerSample,
            frameCount: dataRange.count / frameSize
        )
        return Layout(header: header, dataRange: dataRange)
    }

    public static func decode(data: Data) throws -> DecodedAudio {
        let layout = try layout(of: data)
        let header = layout.header
        let bits = header.bitsPerSample
        let isFloat = header.formatTag == 3
        let formatName: String
        switch (isFloat, bits) {
        case (false, 8): formatName = "pcm_u8"
        case (false, 16): formatName = "pcm_s16le"
        case (false, 24): formatName = "pcm_s24le"
        case (false, 32): formatName = "pcm_s32le"
        case (true, 32): formatName = "pcm_f32le"
        case (true, 64): formatName = "pcm_f64le"
        default:
            throw AudioDecodingError.unsupportedFormat("\(bits)-bit \(isFloat ? "float" : "integer") PCM")
        }

        let channels = header.channels
        let bytesPerSample = bits / 8
        let frameSize = bytesPerSample * channels
        let frames = layout.dataRange.count / frameSize
        var samples = [Float](repeating: 0, count: frames)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = layout.dataRange.lowerBound
            for frame in 0..<frames {
                var sum = 0.0
                for channel in 0..<channels {
                    let p = base + frame * frameSize + channel * bytesPerSample
                    let value: Double
                    switch (isFloat, bits) {
                    case (false, 8):
                        value = (Double(raw[p]) - 128.0) / 128.0
                    case (false, 16):
                        let v = Int16(bitPattern: UInt16(raw[p]) | UInt16(raw[p + 1]) << 8)
                        value = Double(v) / 32768.0
                    case (false, 24):
                        let u = UInt32(raw[p]) | UInt32(raw[p + 1]) << 8 | UInt32(raw[p + 2]) << 16
                        // Sign-extend from 24 bits.
                        let v = Int32(bitPattern: u << 8) >> 8
                        value = Double(v) / 8_388_608.0
                    case (false, 32):
                        let u = UInt32(raw[p]) | UInt32(raw[p + 1]) << 8 | UInt32(raw[p + 2]) << 16 | UInt32(raw[p + 3]) << 24
                        value = Double(Int32(bitPattern: u)) / 2_147_483_648.0
                    case (true, 32):
                        let u = UInt32(raw[p]) | UInt32(raw[p + 1]) << 8 | UInt32(raw[p + 2]) << 16 | UInt32(raw[p + 3]) << 24
                        value = Double(Float(bitPattern: u))
                    default:
                        var u: UInt64 = 0
                        for byte in 0..<8 { u |= UInt64(raw[p + byte]) << (8 * UInt64(byte)) }
                        value = Double(bitPattern: u)
                    }
                    sum += value
                }
                samples[frame] = Float(sum / Double(channels))
            }
        }

        return DecodedAudio(
            samples: samples,
            sampleRate: header.sampleRate,
            sourceChannels: channels,
            sourceFormat: formatName,
            decodeSeconds: 0
        )
    }
}

/// Writes mono 16-bit PCM WAV files. Used by tests and by tools that create fixtures.
public enum WAVWriter {
    public static func pcm16Data(samples: [Float], sampleRate: Int, channels: Int = 1) -> Data {
        var data = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * channels * 2))
        append16(UInt16(channels * 2))
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        for sample in AudioNormalizer.int16(from: samples) {
            append16(UInt16(bitPattern: sample))
        }
        return data
    }
}
