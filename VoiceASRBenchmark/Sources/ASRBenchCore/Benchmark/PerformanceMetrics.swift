import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Device thermal state, mirroring `ProcessInfo.ThermalState`.
public enum ThermalState: Int, Codable, Sendable, Comparable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }

    /// Current state, or `nil` on platforms that do not report one.
    public static func current() -> ThermalState? {
        #if canImport(Darwin)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// Process-level probes.
public enum ProcessProbe {
    /// Memory attributed to this process, in bytes.
    ///
    /// On Apple platforms this is `phys_footprint`, the figure Xcode's memory gauge and the
    /// system's memory limits use. It covers this process only: work an engine performs in a
    /// system service process is not included.
    public static func memoryFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
        #else
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return nil }
        let fields = statm.split(separator: " ")
        guard fields.count > 1, let pages = UInt64(fields[1]) else { return nil }
        return pages * UInt64(sysconf(Int32(_SC_PAGESIZE)))
        #endif
    }

    /// CPU time (user plus system) consumed by this process so far, in seconds, summed over all
    /// threads. Work done on the GPU or Neural Engine, or in another process, is not CPU time.
    public static func cpuSeconds() -> Double? {
        var time = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0 else { return nil }
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}

/// Resource use observed during one transcription.
public struct ResourceUsage: Codable, Sendable, Equatable {
    /// Highest process memory footprint sampled during the run, in bytes.
    public var peakMemoryBytes: UInt64?
    /// Process memory footprint just before the run, in bytes. The difference to the peak is the
    /// memory the run added on top of the loaded model.
    public var baselineMemoryBytes: UInt64?
    /// CPU seconds consumed by the process during the run.
    public var cpuSeconds: Double?
    /// Wall-clock seconds of the run.
    public var wallSeconds: Double
    /// `cpuSeconds / wallSeconds * 100`. Exceeds 100 when several cores are busy.
    public var averageCPUPercent: Double? {
        guard let cpuSeconds, wallSeconds > 0 else { return nil }
        return cpuSeconds / wallSeconds * 100
    }
    public var thermalStateBefore: ThermalState?
    public var thermalStateAfter: ThermalState?
    public var sampleCount: Int

    public init(
        peakMemoryBytes: UInt64?,
        baselineMemoryBytes: UInt64?,
        cpuSeconds: Double?,
        wallSeconds: Double,
        thermalStateBefore: ThermalState?,
        thermalStateAfter: ThermalState?,
        sampleCount: Int
    ) {
        self.peakMemoryBytes = peakMemoryBytes
        self.baselineMemoryBytes = baselineMemoryBytes
        self.cpuSeconds = cpuSeconds
        self.wallSeconds = wallSeconds
        self.thermalStateBefore = thermalStateBefore
        self.thermalStateAfter = thermalStateAfter
        self.sampleCount = sampleCount
    }

    /// The hotter of the two thermal readings.
    public var worstThermalState: ThermalState? {
        [thermalStateBefore, thermalStateAfter].compactMap { $0 }.max()
    }
}

/// Samples process memory on a background thread while a transcription runs.
public final class ResourceSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64?
    private var samples = 0
    private var task: Task<Void, Never>?
    private let intervalNanoseconds: UInt64
    private let thermalProbe: @Sendable () -> ThermalState?

    private var baseline: UInt64?
    private var startCPU: Double?
    private var startWall = 0.0
    private var thermalBefore: ThermalState?

    public init(intervalSeconds: Double = 0.02, thermalProbe: @escaping @Sendable () -> ThermalState? = ThermalState.current) {
        self.intervalNanoseconds = UInt64(max(0.001, intervalSeconds) * 1_000_000_000)
        self.thermalProbe = thermalProbe
    }

    private func sample() {
        guard let value = ProcessProbe.memoryFootprintBytes() else { return }
        lock.lock()
        peak = max(peak ?? 0, value)
        samples += 1
        lock.unlock()
    }

    public func start() {
        baseline = ProcessProbe.memoryFootprintBytes()
        startCPU = ProcessProbe.cpuSeconds()
        startWall = MonotonicClock.now()
        thermalBefore = thermalProbe()
        sample()
        let interval = intervalNanoseconds
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                self?.sample()
            }
        }
    }

    public func stop() -> ResourceUsage {
        task?.cancel()
        task = nil
        sample()
        let endCPU = ProcessProbe.cpuSeconds()
        lock.lock()
        let peak = self.peak
        let samples = self.samples
        lock.unlock()
        var cpu: Double?
        if let startCPU, let endCPU { cpu = endCPU - startCPU }
        return ResourceUsage(
            peakMemoryBytes: peak,
            baselineMemoryBytes: baseline,
            cpuSeconds: cpu,
            wallSeconds: MonotonicClock.now() - startWall,
            thermalStateBefore: thermalBefore,
            thermalStateAfter: thermalProbe(),
            sampleCount: samples
        )
    }
}

/// A battery reading.
public struct BatteryReading: Codable, Sendable, Equatable {
    /// Charge from 0 to 1.
    public var level: Double
    /// `true` when the device is on external power, which makes level changes meaningless as an
    /// energy measurement.
    public var isCharging: Bool
    public var timestamp: Date

    public init(level: Double, isCharging: Bool, timestamp: Date = Date()) {
        self.level = level
        self.isCharging = isCharging
        self.timestamp = timestamp
    }
}

/// Battery change over a block of work.
public struct BatteryImpact: Codable, Sendable, Equatable {
    /// What the block covered, for example an engine id or `whole-run`.
    public var scope: String
    public var start: BatteryReading
    public var end: BatteryReading
    /// `start.level - end.level`, or `nil` when the device was charging at either reading.
    public var levelDrop: Double? {
        start.isCharging || end.isCharging ? nil : start.level - end.level
    }

    public init(scope: String, start: BatteryReading, end: BatteryReading) {
        self.scope = scope
        self.start = start
        self.end = end
    }
}

/// Reads the battery. Returns `nil` on devices without one (for example a Mac mini).
public typealias BatteryProbe = @Sendable () async -> BatteryReading?

/// The device and software a benchmark ran on.
public struct EnvironmentInfo: Codable, Sendable, Equatable {
    /// Hardware model identifier, for example `iPhone17,1` or `Mac16,10`.
    public var deviceModel: String
    public var operatingSystem: String
    public var osVersion: String
    public var processorCount: Int
    public var physicalMemoryBytes: UInt64
    public var lowPowerModeEnabled: Bool?
    public var appVersion: String?
    public var isDebugBuild: Bool
    public var isSimulator: Bool

    public init(
        deviceModel: String,
        operatingSystem: String,
        osVersion: String,
        processorCount: Int,
        physicalMemoryBytes: UInt64,
        lowPowerModeEnabled: Bool?,
        appVersion: String?,
        isDebugBuild: Bool,
        isSimulator: Bool
    ) {
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.osVersion = osVersion
        self.processorCount = processorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.appVersion = appVersion
        self.isDebugBuild = isDebugBuild
        self.isSimulator = isSimulator
    }

    public static func capture() -> EnvironmentInfo {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion

        #if os(iOS)
        let system = "iOS"
        #elseif os(macOS)
        let system = "macOS"
        #elseif os(visionOS)
        let system = "visionOS"
        #elseif os(Linux)
        let system = "Linux"
        #else
        let system = "unknown"
        #endif

        #if canImport(Darwin)
        let lowPower: Bool? = info.isLowPowerModeEnabled
        #else
        let lowPower: Bool? = nil
        #endif

        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif

        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif

        let bundle = Bundle.main.infoDictionary
        let short = bundle?["CFBundleShortVersionString"] as? String
        let build = bundle?["CFBundleVersion"] as? String
        let appVersion = short.map { build == nil ? $0 : "\($0) (\(build!))" }

        return EnvironmentInfo(
            deviceModel: hardwareModel(),
            operatingSystem: system,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            processorCount: info.activeProcessorCount,
            physicalMemoryBytes: info.physicalMemory,
            lowPowerModeEnabled: lowPower,
            appVersion: appVersion,
            isDebugBuild: debug,
            isSimulator: simulator
        )
    }

    static func hardwareModel() -> String {
        #if canImport(Darwin)
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
        #else
        var name = utsname()
        guard uname(&name) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &name.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }
}
