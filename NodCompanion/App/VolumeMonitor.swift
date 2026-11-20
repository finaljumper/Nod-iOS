import AVFoundation
import Observation

/// Follows the device's volume setting, so that Settings can say when the voice is playing
/// but too quiet to hear.
@MainActor
@Observable
final class VolumeMonitor {
    /// 0 to 1, as set with the volume buttons for what the app is playing at the moment.
    private(set) var volume: Float = AVAudioSession.sharedInstance().outputVolume

    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.volume = value }
        }
    }

    /// Reads the setting again. The system reports changes only while the app's audio is active.
    func refresh() {
        volume = AVAudioSession.sharedInstance().outputVolume
    }

    /// Below this, speech from the loudspeaker is easy to miss.
    var isLow: Bool { volume < 0.3 }
}
