#if canImport(AVFoundation)
import ASRBenchCore
import AVFoundation
import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import IOKit.ps
#endif

/// Decodes lossless containers other than WAV (CAF, FLAC, AIFF, Apple Lossless) with AVFoundation.
///
/// WAV files are handled by the pure Swift `WAVDecoder` instead, whose output is bit-for-bit
/// reproducible across OS versions. Lossy formats decode too, but the manifest validation
/// warns about them.
public struct AVAudioFileDecoder: AudioDecoding {
    public init() {}

    public func canDecode(url: URL) -> Bool {
        ["caf", "flac", "aiff", "aif", "m4a", "mp3", "aac"].contains(url.pathExtension.lowercased())
    }

    public func decode(url: URL) throws -> DecodedAudio {
        let start = MonotonicClock.now()
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioDecodingError.malformed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        // The processing format is deinterleaved 32-bit float at the file's sample rate.
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioDecodingError.malformed("\(url.lastPathComponent) contains no audio.")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw AudioDecodingError.malformed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let data = buffer.floatChannelData else {
            throw AudioDecodingError.unsupportedFormat("\(url.lastPathComponent) could not be read as float samples.")
        }
        let channels = Int(format.channelCount)
        let count = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: count)
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channels { sum += data[channel][frame] }
            samples[frame] = sum / Float(channels)
        }
        return DecodedAudio(
            samples: samples,
            sampleRate: format.sampleRate,
            sourceChannels: channels,
            sourceFormat: "avfoundation:\(url.pathExtension.lowercased())",
            decodeSeconds: MonotonicClock.now() - start
        )
    }
}

public enum PlatformSupport {
    /// WAV through the deterministic decoder, other containers through AVFoundation.
    public static let audioLoader = AudioFileLoader(decoders: [WAVDecoder(), AVAudioFileDecoder()])

    /// Reads the battery level, or returns `nil` on devices without a battery.
    public static let batteryProbe: BatteryProbe = {
        #if os(iOS)
        return await MainActor.run {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let level = device.batteryLevel
            guard level >= 0 else { return nil }
            let charging = device.batteryState == .charging || device.batteryState == .full
            return BatteryReading(level: Double(level), isCharging: charging)
        }
        #elseif os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0
            else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return BatteryReading(level: current / maximum, isCharging: state == kIOPSACPowerValue)
        }
        return nil
        #else
        return nil
        #endif
    }
}
#endif
