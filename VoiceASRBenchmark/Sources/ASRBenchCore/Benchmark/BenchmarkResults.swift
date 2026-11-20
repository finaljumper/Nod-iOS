import Foundation

/// The two benchmark modes. Their latencies measure different things and are never compared
/// with each other.
public enum BenchmarkMode: String, Codable, Sendable, CaseIterable {
    /// The whole recording is handed to the engine at once and processed as fast as possible.
    case batch
    /// The recording is replayed in chunks at real-time speed.
    case streaming
}

/// Which language information an engine is given for a recording.
public enum HintMode: String, Codable, Sendable, CaseIterable {
    /// The recording's primary language (the first entry of `languages`).
    case primary
    /// No hint; the engine must detect the language. Engines without language detection are
    /// reported as unavailable for these runs.
    case auto
    /// One additional run per further language of a code-switched recording.
    case alternates
}

/// The language information one run actually received.
public enum HintRole: String, Codable, Sendable, CaseIterable {
    case primary
    case auto
    case alternate
}

/// In which order engines and recordings are executed.
public enum ExecutionOrder: String, Codable, Sendable, CaseIterable {
    /// Every recording is run on all engines before the next recording. Slow drift (thermal
    /// build-up, background activity) then affects all engines alike.
    case interleaved
    /// One engine processes the whole dataset before the next engine starts. Needed to
    /// attribute battery drain to an engine.
    case engineBlocks
}

public struct BenchmarkConfiguration: Codable, Sendable, Equatable {
    public var mode: BenchmarkMode
    /// Measured repetitions of every recording, engine and hint combination.
    public var repetitions: Int
    /// Discarded warm-up transcriptions per engine and language before measuring.
    public var warmupRuns: Int
    /// Unload each engine, then time a fresh load and the first transcription after it.
    public var measureColdStart: Bool
    public var hintModes: [HintMode]
    public var executionOrder: ExecutionOrder
    /// Shuffle the engine order (per recording when interleaved, once for engine blocks).
    public var randomizeEngineOrder: Bool
    /// Seed of the shuffle, stored so a run can be repeated in the same order.
    public var randomSeed: UInt64
    /// Chunk duration of the streaming replay, in seconds.
    public var streamingChunkSeconds: Double
    /// Runs whose thermal state reaches this level are flagged as thermally affected.
    public var thermalFlagThreshold: ThermalState
    /// Before each run, wait for the thermal state to drop below the flag threshold.
    public var waitForCooldown: Bool
    /// Longest wait for a cooldown before running anyway, in seconds.
    public var maxCooldownSeconds: Double
    /// Pause between runs, in seconds, to let the system settle.
    public var pauseBetweenRunsSeconds: Double

    public init(
        mode: BenchmarkMode = .batch,
        repetitions: Int = 3,
        warmupRuns: Int = 1,
        measureColdStart: Bool = true,
        hintModes: [HintMode] = [.primary, .auto],
        executionOrder: ExecutionOrder = .interleaved,
        randomizeEngineOrder: Bool = true,
        randomSeed: UInt64 = 20_261_119,
        streamingChunkSeconds: Double = 0.1,
        thermalFlagThreshold: ThermalState = .serious,
        waitForCooldown: Bool = true,
        maxCooldownSeconds: Double = 120,
        pauseBetweenRunsSeconds: Double = 0
    ) {
        self.mode = mode
        self.repetitions = repetitions
        self.warmupRuns = warmupRuns
        self.measureColdStart = measureColdStart
        self.hintModes = hintModes
        self.executionOrder = executionOrder
        self.randomizeEngineOrder = randomizeEngineOrder
        self.randomSeed = randomSeed
        self.streamingChunkSeconds = streamingChunkSeconds
        self.thermalFlagThreshold = thermalFlagThreshold
        self.waitForCooldown = waitForCooldown
        self.maxCooldownSeconds = maxCooldownSeconds
        self.pauseBetweenRunsSeconds = pauseBetweenRunsSeconds
    }
}

/// Outcome category of one run.
public enum RunStatus: String, Codable, Sendable, CaseIterable {
    /// The engine produced a transcript.
    case success
    /// The engine cannot run this combination on this device (unsupported language, missing
    /// capability, missing assets). Not a recognition failure and never counted as an error.
    case unavailable
    /// The engine ran and failed.
    case failed
    /// The recording could not be used (for example its audio file is missing).
    case skipped
    /// The benchmark was cancelled during this run.
    case cancelled
}

/// Which part of the methodology a run belongs to.
public enum RunPhase: String, Codable, Sendable, CaseIterable {
    /// First transcription after a fresh model load. Reported separately, never aggregated
    /// with warm runs.
    case cold
    /// Discarded transcription that brings the engine to a steady state.
    case warmup
    /// A run that counts towards the results.
    case measured
}

/// Everything recorded about one transcription attempt.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Position in the overall execution order, starting at 0.
    public var sequence: Int
    public var recordingID: String
    public var engineID: String
    public var mode: BenchmarkMode
    public var phase: RunPhase
    /// Repetition index, starting at 0. Always 0 for cold and warm-up runs.
    public var repetition: Int
    public var hintRole: HintRole
    /// The language hint passed to the engine, `nil` for automatic detection.
    public var languageHint: String?
    public var status: RunStatus
    /// Why the run is unavailable, failed, skipped or cancelled.
    public var statusReason: String?
    /// Transcript exactly as the engine returned it.
    public var hypothesis: String?
    public var detectedLanguage: String?
    public var languageUsed: String?
    public var accuracy: RecordingAccuracy?
    /// Present for batch runs.
    public var batch: BatchTiming?
    /// Present for streaming runs.
    public var streaming: StreamingLatency?
    public var resources: ResourceUsage?
    public var thermallyAffected: Bool
    public var audioFingerprint: String?
    public var audioSeconds: Double?
    public var engineTimings: [String: Double]
    public var notes: [String]
    public var startedAt: Date

    public init(
        id: String = UUID().uuidString,
        sequence: Int,
        recordingID: String,
        engineID: String,
        mode: BenchmarkMode,
        phase: RunPhase,
        repetition: Int,
        hintRole: HintRole,
        languageHint: String?,
        status: RunStatus,
        statusReason: String? = nil,
        hypothesis: String? = nil,
        detectedLanguage: String? = nil,
        languageUsed: String? = nil,
        accuracy: RecordingAccuracy? = nil,
        batch: BatchTiming? = nil,
        streaming: StreamingLatency? = nil,
        resources: ResourceUsage? = nil,
        thermallyAffected: Bool = false,
        audioFingerprint: String? = nil,
        audioSeconds: Double? = nil,
        engineTimings: [String: Double] = [:],
        notes: [String] = [],
        startedAt: Date = Date()
    ) {
        self.id = id
        self.sequence = sequence
        self.recordingID = recordingID
        self.engineID = engineID
        self.mode = mode
        self.phase = phase
        self.repetition = repetition
        self.hintRole = hintRole
        self.languageHint = languageHint
        self.status = status
        self.statusReason = statusReason
        self.hypothesis = hypothesis
        self.detectedLanguage = detectedLanguage
        self.languageUsed = languageUsed
        self.accuracy = accuracy
        self.batch = batch
        self.streaming = streaming
        self.resources = resources
        self.thermallyAffected = thermallyAffected
        self.audioFingerprint = audioFingerprint
        self.audioSeconds = audioSeconds
        self.engineTimings = engineTimings
        self.notes = notes
        self.startedAt = startedAt
    }
}

/// What was learned about one engine outside individual runs.
public struct EngineReport: Codable, Sendable, Equatable, Identifiable {
    public var descriptor: EngineDescriptor
    public var supportedLocales: [String]
    /// Availability per language code (`auto` for language detection): `available` or the reason
    /// it is not.
    public var availability: [String: String]
    /// Load measured after an explicit unload. `nil` when cold start was not measured.
    public var coldPreparation: PreparationMetrics?
    /// Load measured without unloading first (the engine may already have been loaded).
    public var preparation: PreparationMetrics?
    /// Set when the engine could not be prepared at all.
    public var preparationError: String?
    public var notes: [String]

    public var id: String { descriptor.id }

    public init(
        descriptor: EngineDescriptor,
        supportedLocales: [String] = [],
        availability: [String: String] = [:],
        coldPreparation: PreparationMetrics? = nil,
        preparation: PreparationMetrics? = nil,
        preparationError: String? = nil,
        notes: [String] = []
    ) {
        self.descriptor = descriptor
        self.supportedLocales = supportedLocales
        self.availability = availability
        self.coldPreparation = coldPreparation
        self.preparation = preparation
        self.preparationError = preparationError
        self.notes = notes
    }
}

/// A complete benchmark run: everything needed to reproduce and audit the numbers.
public struct BenchmarkRun: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var startedAt: Date
    public var finishedAt: Date
    /// `true` when the run was cancelled; the records up to that point are still valid.
    public var cancelled: Bool
    public var environment: EnvironmentInfo
    public var configuration: BenchmarkConfiguration
    public var datasetName: String
    /// The manifest entries that were benchmarked, including reference transcripts.
    public var recordings: [Recording]
    public var engines: [EngineReport]
    public var records: [RunRecord]
    public var summaries: [AggregateSummary]
    public var battery: [BatteryImpact]
    public var notes: [String]

    public init(
        id: String = UUID().uuidString,
        startedAt: Date,
        finishedAt: Date,
        cancelled: Bool,
        environment: EnvironmentInfo,
        configuration: BenchmarkConfiguration,
        datasetName: String,
        recordings: [Recording],
        engines: [EngineReport],
        records: [RunRecord],
        summaries: [AggregateSummary],
        battery: [BatteryImpact],
        notes: [String]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.cancelled = cancelled
        self.environment = environment
        self.configuration = configuration
        self.datasetName = datasetName
        self.recordings = recordings
        self.engines = engines
        self.records = records
        self.summaries = summaries
        self.battery = battery
        self.notes = notes
    }
}

/// Progress reported while a benchmark runs.
public struct BenchmarkProgress: Sendable, Equatable {
    public var stage: String
    public var detail: String
    public var completedRuns: Int
    public var totalRuns: Int
    /// The run that just finished, if any.
    public var latestRecord: RunRecord?

    public var fraction: Double {
        totalRuns > 0 ? min(1, Double(completedRuns) / Double(totalRuns)) : 0
    }
}
