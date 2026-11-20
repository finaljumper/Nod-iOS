@preconcurrency import AVFoundation
import Foundation
import NodCore

/// One audio engine for both directions: it plays the assistant's voice and captures the
/// microphone.
///
/// Both go through the same engine on purpose. With voice processing switched on, the system
/// removes from the microphone signal what the engine itself is playing, so the app does not
/// hear its own voice as the user interrupting.
public final class VoiceAudioEngine: @unchecked Sendable {
    public static let shared = VoiceAudioEngine()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Serialises every change to the engine's configuration.
    private let queue = DispatchQueue(label: "Nod.VoiceAudioEngine")
    private let lock = NSLock()
    /// Everything is played in this one format. Voices that produce another sample rate are
    /// converted, so that the player never has to be reconnected while it is playing.
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
    /// What to call when each queued piece has been played, by its number. It receives the
    /// reason if the piece could not be played at all.
    private var completions: [Int: @Sendable ((any Error)?) -> Void] = [:]
    private var nextPiece = 0
    /// The pieces handed to the player and not heard to the end yet, in order. They are given
    /// to the player again when the system resets the audio and the player loses them.
    private var queued: [(piece: Int, buffer: AVAudioPCMBuffer)] = []
    /// Counts how often the player was started over. A report from the player about a piece
    /// it was given before that is ignored.
    private var epoch = 0
    private var capture: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var scheduled = 0
    private var generation = 0
    private var paused = false
    /// How loud the last moments of playback were, as measured at the engine's output.
    private var outputLevels: [(time: TimeInterval, level: Float)] = []
    private var observer: NSObjectProtocol?

    /// Development aid: with `NOD_AUDIO_TRACE` set in the environment, what the engine does is
    /// written to standard error, where `devicectl device process launch --console` shows it.
    static let tracing = ProcessInfo.processInfo.environment["NOD_AUDIO_TRACE"] != nil
    static func trace(_ text: @autoclosure () -> String) {
        guard tracing else { return }
        FileHandle.standardError.write(Data("[audio \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(text())\n".utf8))
    }

    public init() {
        engine.attach(player)
        // The system stops the engine when the audio route changes (headphones, a call).
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Self.trace("configuration change notification")
            self?.queue.async { [weak self] in
                guard let self else { return }
                Self.trace("config change handled: capturing=\(self.isCapturing) playing=\(self.isPlaying) engineRunning=\(self.engine.isRunning) playerPlaying=\(self.player.isPlaying)")
                guard self.isCapturing || self.isPlaying else { return }
                // The system stops the engine for this, and with it the player.
                let stopped = !self.engine.isRunning
                do {
                    try self.startEngineIfNeeded()
                    if stopped { self.playQueuedAgain() }
                } catch {
                    Self.trace("restart failed: \(error)")
                    self.failQueued(error)
                }
                Self.trace("after restart: engineRunning=\(self.engine.isRunning) playerPlaying=\(self.player.isPlaying)")
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Whether speech handed to `play` is still to be heard.
    public var isPlaying: Bool { lock.withLock { scheduled > 0 } }

    public var isCapturing: Bool { lock.withLock { capture != nil } }

    // MARK: Playback

    /// Queues mono samples for playback behind whatever is already queued. `completion` runs
    /// when they have been played, or with the reason when they could not be played. It does
    /// not run if playback is stopped first.
    public func play(samples: [Float], sampleRate: Double, completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard let buffer = Self.buffer(samples, sampleRate: sampleRate, in: playbackFormat) else {
            completion(samples.isEmpty ? nil : VoiceAudioError.noPlayableAudio)
            return
        }
        let (token, piece) = lock.withLock { () -> (Int, Int) in
            scheduled += 1
            nextPiece += 1
            completions[nextPiece] = completion
            return (generation, nextPiece)
        }
        queue.async { [self] in
            do {
                try startEngineIfNeeded()
            } catch {
                Self.trace("engine start failed: \(error)")
                finished(token, piece, failure: error)
                return
            }
            let epoch = lock.withLock { () -> Int? in
                guard generation == token else { return nil }
                queued.append((piece, buffer))
                return self.epoch
            }
            guard let epoch else { Self.trace("piece \(piece) dropped: stale"); return }
            Self.trace("schedule piece \(piece): \(buffer.frameLength) frames, engineRunning=\(engine.isRunning) playerPlaying=\(player.isPlaying) out=\(engine.outputNode.outputFormat(forBus: 0))")
            schedule(buffer, piece: piece, token: token, epoch: epoch)
            if !player.isPlaying, !lock.withLock({ paused }) { player.play() }
            Self.trace("after play: playerPlaying=\(player.isPlaying)")
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, piece: Int, token: Int, epoch: Int) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Self.trace("piece \(piece) played back, loudest at the mixer in the last 2 s: \(self?.lock.withLock { self?.outputLevels.map(\.level).max() } ?? nil ?? -120) dBFS")
            self?.finished(token, piece, epoch: epoch)
        }
    }

    /// Gives the player everything not heard to the end once more. Called after the system
    /// reset the audio: that stops the engine and the player, and what the player was given
    /// is not played afterwards. The piece that was being heard starts again from its beginning.
    private func playQueuedAgain() {
        let (pieces, token, epoch, paused) = lock.withLock { () -> ([(piece: Int, buffer: AVAudioPCMBuffer)], Int, Int, Bool) in
            self.epoch += 1
            return (queued, generation, self.epoch, paused)
        }
        // Empties the player. Its reports about the old pieces carry the old epoch.
        player.stop()
        Self.trace("playing \(pieces.count) queued piece(s) again")
        guard !pieces.isEmpty else { return }
        for entry in pieces { schedule(entry.buffer, piece: entry.piece, token: token, epoch: epoch) }
        if !paused { player.play() }
    }

    /// Reports everything queued as not playable.
    private func failQueued(_ error: any Error) {
        let (pieces, token) = lock.withLock { (queued.map(\.piece), generation) }
        player.stop()
        for piece in pieces { finished(token, piece, failure: error) }
    }

    private func finished(_ token: Int, _ piece: Int, epoch: Int? = nil, failure: (any Error)? = nil) {
        let (completion, idle) = lock.withLock { () -> ((@Sendable ((any Error)?) -> Void)?, Bool) in
            guard generation == token, epoch == nil || epoch == self.epoch,
                  let completion = completions.removeValue(forKey: piece)
            else { return (nil, false) }
            queued.removeAll { $0.piece == piece }
            scheduled = max(0, scheduled - 1)
            return (completion, scheduled == 0)
        }
        guard let completion else { return }
        completion(failure)
        if idle {
            // Nothing left to say: give the loudspeaker back, unless the microphone is in use
            // or more speech has arrived in the meantime.
            queue.async { [self] in
                if !isPlaying, !isCapturing { stopEngine() }
            }
        }
    }

    /// Stops at once and drops everything queued.
    public func stopPlayback() {
        lock.withLock {
            generation += 1
            scheduled = 0
            paused = false
            completions = [:]
            queued = []
        }
        queue.async { [self] in
            Self.trace("stopPlayback")
            player.stop()
            if !isCapturing { stopEngine() }
        }
    }

    /// Mono samples as a buffer in the playback format, resampled if they have another rate.
    private static func buffer(_ samples: [Float], sampleRate: Double, in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, sampleRate > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0]
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if sampleRate == format.sampleRate { return input }

        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / sampleRate) + 1024
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }
        var given = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return input
        }
        return failure == nil && output.frameLength > 0 ? output : nil
    }

    /// Falls silent at once and keeps what is queued, until `resumePlayback` or `stopPlayback`.
    public func pausePlayback() {
        lock.withLock { paused = true }
        queue.async { [self] in player.pause() }
    }

    public func resumePlayback() {
        lock.withLock { paused = false }
        queue.async { [self] in
            guard isPlaying, (try? startEngineIfNeeded()) != nil else { return }
            player.play()
        }
    }

    /// The loudest 20 ms the app has played in the last moments, in decibels relative to
    /// full scale and with the device's volume setting counted in; nil when it has been silent.
    /// The loudest and not the average, so that the echo of a loud syllable is never louder
    /// than what this predicts.
    /// "The last moments" also covers what is still on its way through the loudspeaker and
    /// the room after the last sample was handed over.
    public func recentOutputLevel(within seconds: TimeInterval = 0.3) -> Float? {
        let now = ProcessInfo.processInfo.systemUptime
        let loudest = lock.withLock { outputLevels.filter { now - $0.time <= seconds }.map(\.level).max() }
        guard let loudest, loudest > -60 else { return nil }
        #if os(iOS)
        let volume = AVAudioSession.sharedInstance().outputVolume
        guard volume > 0 else { return nil }
        return loudest + 20 * log10(volume)
        #else
        return loudest
        #endif
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength), piece = max(1, Int(buffer.format.sampleRate * 0.02))
        var level: Float = -120
        for start in stride(from: 0, to: frames, by: piece) {
            level = max(level, UtteranceEndpointer.level(of: UnsafeBufferPointer(start: channel + start, count: min(piece, frames - start))))
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            outputLevels.append((now, level))
            outputLevels.removeAll { now - $0.time > 2 }
        }
    }

    // MARK: Capture

    /// Starts the microphone with echo cancellation and returns its audio, block by block.
    /// The stream ends when `stopCapture` is called.
    public func startCapture() throws -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(500))
        try queue.sync {
            lock.withLock { capture?.finish() }
            engine.stop()
            try configureSession(recording: true)
            let input = engine.inputNode
            // Must be set while the engine is stopped. It also routes playback through the
            // system's voice processing, which is what makes echo cancellation possible.
            try input.setVoiceProcessingEnabled(true)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceAudioError.noMicrophone
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, let copy = Self.copy(buffer) else { return }
                _ = self.lock.withLock { self.capture }?.yield(copy)
            }
            lock.withLock { capture = continuation }
            try startEngineIfNeeded()
        }
        return stream
    }

    public func stopCapture() {
        queue.async { [self] in
            guard let continuation = lock.withLock({ () -> AsyncStream<AVAudioPCMBuffer>.Continuation? in
                defer { capture = nil }
                return capture
            }) else { return }
            continuation.finish()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            try? configureSession(recording: false)
            // Stopping the engine cut off whatever was being said. Its pieces are reported as
            // played, so that whoever queued them carries on with the next sentence.
            let cut = lock.withLock { () -> [@Sendable ((any Error)?) -> Void] in
                defer {
                    generation += 1
                    scheduled = 0
                    paused = false
                    completions = [:]
                    queued = []
                }
                return Array(completions.values)
            }
            player.stop()
            cut.forEach { $0(nil) }
        }
    }

    // MARK: Engine

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        if !isCapturing { try configureSession(recording: false) }
        // Connected anew before every start. Switching voice processing on or off rebuilds the
        // engine's output, and a player left from before that plays nothing or the wrong way.
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        // Measures what is played, so that the listener can tell the app's own voice in the
        // microphone from the user's. Installed anew each time: the output's format changes
        // when voice processing is switched on or off.
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in self?.meter(buffer) }
        engine.prepare()
        try engine.start()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        Self.trace("engine started: category=\(session.category.rawValue) rate=\(session.sampleRate) volume=\(session.outputVolume) route=\(session.currentRoute.outputs.map(\.portType.rawValue))")
        #endif
    }

    private func stopEngine() {
        Self.trace("stopEngine (running=\(engine.isRunning))")
        guard engine.isRunning else { return }
        engine.stop()
        #if os(iOS)
        // Lets music that was turned down for the reply come back up.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func configureSession(recording: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if recording {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try session.setActive(true)
        #endif
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

public enum VoiceAudioError: Error, Sendable, CustomStringConvertible {
    case noMicrophone
    case noPlayableAudio

    public var description: String {
        switch self {
        case .noMicrophone: return "No microphone is available."
        case .noPlayableAudio: return "The voice produced audio that could not be played."
        }
    }
}
