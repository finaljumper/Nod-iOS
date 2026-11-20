import Foundation

/// Runs a dataset through a set of engines and records every measurement.
///
/// Methodology, in order:
/// 1. Every recording is decoded once into canonical mono samples. Each engine's input is
///    derived from those samples, so all engines see the same audio.
/// 2. Each engine reports its capabilities and its availability per language. Combinations an
///    engine cannot run are recorded as `unavailable` and are never executed.
/// 3. Cold start (optional): the engine is unloaded, a fresh load is timed, and the first
///    transcription after it is recorded with phase `cold`.
/// 4. Warm-up: discarded transcriptions per engine and language.
/// 5. Measured runs: every recording, engine and language hint, repeated `repetitions` times,
///    strictly one transcription at a time.
///
/// The runner never downloads anything: engines are prepared with `allowDownload: false`.
public struct BenchmarkRunner: Sendable {
    /// Replaceable collaborators. Tests substitute deterministic versions.
    public struct Dependencies: Sendable {
        public var decoder: any AudioDecoding
        public var thermalProbe: @Sendable () -> ThermalState?
        public var batteryProbe: BatteryProbe?
        public var environment: @Sendable () -> EnvironmentInfo
        /// Suspends for a number of seconds (cooldown waits and pauses between runs).
        public var sleep: @Sendable (Double) async -> Void

        public init(
            decoder: any AudioDecoding = AudioFileLoader.standard,
            thermalProbe: @escaping @Sendable () -> ThermalState? = ThermalState.current,
            batteryProbe: BatteryProbe? = nil,
            environment: @escaping @Sendable () -> EnvironmentInfo = EnvironmentInfo.capture,
            sleep: @escaping @Sendable (Double) async -> Void = { seconds in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            }
        ) {
            self.decoder = decoder
            self.thermalProbe = thermalProbe
            self.batteryProbe = batteryProbe
            self.environment = environment
            self.sleep = sleep
        }
    }

    public var dependencies: Dependencies

    public init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    /// Runs the benchmark. Never throws: problems are recorded in the result. Cancelling the
    /// calling task stops after the current transcription and returns what was measured so far.
    public func run(
        dataset: BenchmarkDataset,
        engines: [any SpeechRecognitionEngine],
        configuration: BenchmarkConfiguration,
        progress: @escaping @Sendable (BenchmarkProgress) -> Void = { _ in }
    ) async -> BenchmarkRun {
        let session = Session(dataset: dataset, engines: engines, configuration: configuration, dependencies: dependencies, progress: progress)
        return await session.run()
    }
}

/// Deterministic random number generator (SplitMix64) for reproducible engine order.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// State of one benchmark run. Used from a single task.
private final class Session {
    struct Item {
        var recording: Recording
        var audio: DecodedAudio
        var bounds: SpeechBounds
    }

    struct EngineState {
        var engine: any SpeechRecognitionEngine
        var report: EngineReport
        /// Keyed by language code, or `auto`.
        var availability: [String: EngineAvailability] = [:]
        /// Set when the engine cannot be used at all, with the status its runs should get.
        var blocked: (status: RunStatus, reason: String)?
        var isPrepared = false
    }

    let dataset: BenchmarkDataset
    let configuration: BenchmarkConfiguration
    let dependencies: BenchmarkRunner.Dependencies
    let progress: @Sendable (BenchmarkProgress) -> Void

    var states: [EngineState]
    var items: [Item] = []
    var skipped: [(Recording, String)] = []
    var records: [RunRecord] = []
    var notes: [String] = []
    var battery: [BatteryImpact] = []
    var audioCache: [String: EngineAudio] = [:]
    var sequence = 0
    var completed = 0
    var total = 0
    var cancelled = false
    var generator: SeededGenerator

    init(
        dataset: BenchmarkDataset,
        engines: [any SpeechRecognitionEngine],
        configuration: BenchmarkConfiguration,
        dependencies: BenchmarkRunner.Dependencies,
        progress: @escaping @Sendable (BenchmarkProgress) -> Void
    ) {
        var configuration = configuration
        configuration.repetitions = max(1, configuration.repetitions)
        configuration.warmupRuns = max(0, configuration.warmupRuns)
        if configuration.hintModes.isEmpty { configuration.hintModes = [.primary] }
        self.dataset = dataset
        self.configuration = configuration
        self.dependencies = dependencies
        self.progress = progress
        self.states = engines.map {
            EngineState(engine: $0, report: EngineReport(descriptor: EngineDescriptor(
                id: $0.id, displayName: $0.id, family: "", engineVersion: "", modelIdentifier: "",
                capabilities: EngineCapabilities(
                    streaming: .native, partialResults: .native, segmentTimestamps: .native, wordTimestamps: .native,
                    languageDetection: .native, codeSwitching: .native, modelStorageMeasurable: .native, explicitUnload: .native
                )
            )))
        }
        self.generator = SeededGenerator(seed: configuration.randomSeed)
    }

    // MARK: Run

    func run() async -> BenchmarkRun {
        let startedAt = Date()
        let environment = dependencies.environment()
        let batteryStart = await dependencies.batteryProbe?()

        if environment.isDebugBuild {
            notes.append("Debug build: timings are not representative. Benchmark a Release build.")
        }
        if environment.isSimulator {
            notes.append("Simulator: Core ML runs on the CPU and timings are not representative of a device.")
        }
        if environment.lowPowerModeEnabled == true {
            notes.append("Low Power Mode was on, which throttles the device.")
        }

        report(stage: "Decoding audio", detail: "\(dataset.manifest.recordings.count) recordings")
        decodeAll()

        report(stage: "Checking engines", detail: "")
        await inspectEngines()
        total = plannedRunCount()

        switch configuration.executionOrder {
        case .interleaved:
            if states.count > 1 {
                notes.append("Interleaved order keeps all engines loaded, so each run's memory footprint includes every loaded engine. Use engine-block order for per-engine memory.")
            }
            for index in states.indices where !isCancelled {
                await prepareAndWarm(index)
            }
            if !isCancelled { await measureInterleaved() }
        case .engineBlocks:
            var order = Array(states.indices)
            if configuration.randomizeEngineOrder { order.shuffle(using: &generator) }
            for index in order where !isCancelled {
                for other in states.indices where other != index && states[other].isPrepared {
                    await states[other].engine.unload()
                    states[other].isPrepared = false
                }
                let blockStart = await dependencies.batteryProbe?()
                await prepareAndWarm(index)
                if !isCancelled { await measureBlock(index) }
                if let blockStart, let blockEnd = await dependencies.batteryProbe?() {
                    battery.append(BatteryImpact(scope: states[index].engine.id, start: blockStart, end: blockEnd))
                }
            }
        }

        recordSkipped()

        if let batteryStart, let batteryEnd = await dependencies.batteryProbe?() {
            battery.insert(BatteryImpact(scope: "whole-run", start: batteryStart, end: batteryEnd), at: 0)
            if configuration.executionOrder == .interleaved {
                notes.append("Battery change is recorded for the whole run only. Use engine-block order to attribute it to an engine.")
            }
        } else {
            notes.append("Battery level is not measurable on this device or was not provided.")
        }
        if dependencies.thermalProbe() == nil {
            notes.append("Thermal state is not reported on this platform.")
        }

        let usedRecordings = dataset.manifest.recordings
        let run = BenchmarkRun(
            startedAt: startedAt,
            finishedAt: Date(),
            cancelled: cancelled,
            environment: environment,
            configuration: configuration,
            datasetName: dataset.manifest.name,
            recordings: usedRecordings,
            engines: states.map(\.report),
            records: records,
            summaries: BenchmarkSummarizer.summarize(records: records, recordings: usedRecordings),
            battery: battery,
            notes: notes
        )
        report(stage: cancelled ? "Cancelled" : "Finished", detail: "\(records.count) records")
        return run
    }

    var isCancelled: Bool {
        if Task.isCancelled { cancelled = true }
        return cancelled
    }

    func report(stage: String, detail: String, latest: RunRecord? = nil) {
        progress(BenchmarkProgress(stage: stage, detail: detail, completedRuns: completed, totalRuns: total, latestRecord: latest))
    }

    // MARK: Setup

    func decodeAll() {
        for recording in dataset.manifest.recordings {
            let url = dataset.audioURL(for: recording)
            do {
                let audio = try dependencies.decoder.decode(url: url)
                guard !audio.samples.isEmpty else {
                    skipped.append((recording, "Audio file contains no samples."))
                    continue
                }
                items.append(Item(recording: recording, audio: audio, bounds: SpeechBounds.resolve(recording: recording, audio: audio)))
            } catch {
                skipped.append((recording, "\(error)"))
            }
        }
    }

    var datasetLanguages: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for item in items {
            for language in item.recording.languages where seen.insert(language).inserted {
                ordered.append(language)
            }
        }
        return ordered
    }

    func inspectEngines() async {
        let languages = datasetLanguages
        for index in states.indices {
            let engine = states[index].engine
            var report = EngineReport(descriptor: await engine.descriptor())
            report.supportedLocales = await engine.supportedLocales()
            var availability: [String: EngineAvailability] = [:]
            for language in languages {
                availability[language] = await engine.availability(forLanguage: language)
            }
            if configuration.hintModes.contains(.auto) {
                availability["auto"] = await engine.availability(forLanguage: nil)
            }
            report.availability = availability.mapValues { $0.reason ?? "available" }
            if configuration.mode == .streaming, !report.descriptor.capabilities.streaming.isAvailable {
                let reason = report.descriptor.capabilities.streaming.note ?? "Streaming is not supported."
                states[index].blocked = (.unavailable, reason)
            }
            states[index].availability = availability
            states[index].report = report
        }
    }

    /// Hints to run for a recording, in a fixed order.
    func hints(for recording: Recording) -> [(hint: String?, role: HintRole)] {
        var result: [(String?, HintRole)] = []
        if configuration.hintModes.contains(.primary) {
            result.append((recording.primaryLanguage, .primary))
        }
        if configuration.hintModes.contains(.auto) {
            result.append((nil, .auto))
        }
        if configuration.hintModes.contains(.alternates) {
            for language in recording.languages.dropFirst() {
                result.append((language, .alternate))
            }
        }
        return result
    }

    func availability(_ index: Int, hint: String?) -> EngineAvailability {
        states[index].availability[hint ?? "auto"] ?? .unavailable("Availability was not checked for this language.")
    }

    func plannedRunCount() -> Int {
        var count = 0
        for index in states.indices where states[index].blocked == nil {
            var perRepetition = 0
            for item in items {
                perRepetition += hints(for: item.recording).filter { availability(index, hint: $0.hint).isRunnable }.count
            }
            count += perRepetition * configuration.repetitions
            count += warmupPlan(index).count * configuration.warmupRuns
            if configuration.measureColdStart, coldProbe(index) != nil { count += 1 }
        }
        return count
    }

    /// The recording and hint used for the cold-start transcription: the first runnable one.
    func coldProbe(_ index: Int) -> (item: Item, hint: String?, role: HintRole)? {
        for item in items {
            for (hint, role) in hints(for: item.recording) where availability(index, hint: hint).isRunnable {
                return (item, hint, role)
            }
        }
        return nil
    }

    /// One warm-up per distinct runnable hint: the first recording that uses it.
    func warmupPlan(_ index: Int) -> [(item: Item, hint: String?, role: HintRole)] {
        var seen = Set<String>()
        var plan: [(Item, String?, HintRole)] = []
        for item in items {
            for (hint, role) in hints(for: item.recording) where availability(index, hint: hint).isRunnable {
                if seen.insert(hint ?? "auto").inserted {
                    plan.append((item, hint, role))
                }
            }
        }
        return plan
    }

    // MARK: Phases

    func prepareAndWarm(_ index: Int) async {
        guard states[index].blocked == nil else { return }
        let engine = states[index].engine
        let languages = datasetLanguages.filter { availability(index, hint: $0).isRunnable }
        // Nothing this engine can run: do not load it. Each combination is still recorded as
        // unavailable with its own reason.
        guard states[index].availability.values.contains(where: \.isRunnable) else { return }

        report(stage: "Loading \(engine.id)", detail: configuration.measureColdStart ? "cold load" : "")
        if configuration.measureColdStart {
            await engine.unload()
        }
        do {
            let metrics = try await engine.prepare(languages: languages, allowDownload: false, progress: nil)
            if configuration.measureColdStart {
                states[index].report.coldPreparation = metrics
            } else {
                states[index].report.preparation = metrics
            }
            states[index].isPrepared = true
        } catch is CancellationError {
            cancelled = true
            return
        } catch {
            let unavailable = (error as? EngineError)?.meansUnavailable ?? false
            states[index].report.preparationError = "\(error)"
            states[index].blocked = (unavailable ? .unavailable : .failed, "Engine preparation failed: \(error)")
            return
        }

        if configuration.measureColdStart, let probe = coldProbe(index), !isCancelled {
            await execute(index, item: probe.item, hint: probe.hint, role: probe.role, phase: .cold, repetition: 0)
        }

        for _ in 0..<configuration.warmupRuns {
            for step in warmupPlan(index) where !isCancelled {
                await execute(index, item: step.item, hint: step.hint, role: step.role, phase: .warmup, repetition: 0)
            }
        }
    }

    func measureInterleaved() async {
        for repetition in 0..<configuration.repetitions {
            for item in items {
                var order = Array(states.indices)
                if configuration.randomizeEngineOrder { order.shuffle(using: &generator) }
                for index in order {
                    await measure(index, item: item, repetition: repetition)
                    if isCancelled { return }
                }
            }
        }
    }

    func measureBlock(_ index: Int) async {
        for repetition in 0..<configuration.repetitions {
            for item in items {
                await measure(index, item: item, repetition: repetition)
                if isCancelled { return }
            }
        }
    }

    func measure(_ index: Int, item: Item, repetition: Int) async {
        for (hint, role) in hints(for: item.recording) {
            if isCancelled { return }
            if let blocked = states[index].blocked {
                // Record once per combination, not once per repetition.
                if repetition == 0 {
                    append(placeholder(index, item.recording, hint: hint, role: role, status: blocked.status, reason: blocked.reason))
                }
                continue
            }
            let availability = availability(index, hint: hint)
            guard availability.isRunnable else {
                if repetition == 0 {
                    append(placeholder(index, item.recording, hint: hint, role: role, status: .unavailable, reason: availability.reason))
                }
                continue
            }
            await execute(index, item: item, hint: hint, role: role, phase: .measured, repetition: repetition)
        }
    }

    func recordSkipped() {
        for (recording, reason) in skipped {
            for index in states.indices {
                append(placeholder(index, recording, hint: recording.primaryLanguage, role: .primary, status: .skipped, reason: reason))
            }
        }
    }

    func placeholder(_ index: Int, _ recording: Recording, hint: String?, role: HintRole, status: RunStatus, reason: String?) -> RunRecord {
        RunRecord(
            sequence: nextSequence(),
            recordingID: recording.id,
            engineID: states[index].engine.id,
            mode: configuration.mode,
            phase: .measured,
            repetition: 0,
            hintRole: role,
            languageHint: hint,
            status: status,
            statusReason: reason
        )
    }

    func nextSequence() -> Int {
        defer { sequence += 1 }
        return sequence
    }

    func append(_ record: RunRecord) {
        records.append(record)
    }

    // MARK: One transcription

    func waitForCooldown() async {
        guard configuration.waitForCooldown else { return }
        var waited = 0.0
        while let state = dependencies.thermalProbe(), state >= configuration.thermalFlagThreshold,
              waited < configuration.maxCooldownSeconds, !isCancelled {
            report(stage: "Cooling down", detail: "thermal state \(state.label)")
            await dependencies.sleep(1)
            waited += 1
        }
    }

    func engineAudio(for item: Item, format: EngineAudioFormat) -> EngineAudio {
        let key = "\(item.recording.id)|\(format.sampleRate)|\(format.encoding.rawValue)"
        if let cached = audioCache[key] { return cached }
        let audio = AudioNormalizer.normalize(item.audio, to: format)
        audioCache[key] = audio
        return audio
    }

    func execute(_ index: Int, item: Item, hint: String?, role: HintRole, phase: RunPhase, repetition: Int) async {
        let engine = states[index].engine
        let recording = item.recording
        if phase == .measured {
            await waitForCooldown()
            if configuration.pauseBetweenRunsSeconds > 0 {
                await dependencies.sleep(configuration.pauseBetweenRunsSeconds)
            }
            if isCancelled { return }
        }

        var record = RunRecord(
            sequence: nextSequence(),
            recordingID: recording.id,
            engineID: engine.id,
            mode: configuration.mode,
            phase: phase,
            repetition: repetition,
            hintRole: role,
            languageHint: hint,
            status: .failed,
            audioFingerprint: item.audio.fingerprint,
            audioSeconds: item.audio.durationSeconds
        )
        report(stage: "\(phase.rawValue.capitalized) run", detail: "\(engine.id) · \(recording.id) · \(hint ?? "auto")")

        let sampler = ResourceSampler(thermalProbe: dependencies.thermalProbe)
        var samplerRunning = false
        do {
            let format = try await engine.requiredAudioFormat(forLanguage: hint)
            let audio = engineAudio(for: item, format: format)
            let result: RecognitionResult

            sampler.start()
            samplerRunning = true
            switch configuration.mode {
            case .batch:
                let start = MonotonicClock.now()
                result = try await engine.transcribe(audio: audio, languageHint: hint)
                record.batch = BatchTiming(
                    decodeSeconds: item.audio.decodeSeconds,
                    preprocessSeconds: audio.preprocessSeconds,
                    inferenceSeconds: MonotonicClock.now() - start,
                    audioSeconds: audio.durationSeconds
                )
            case .streaming:
                // Warm-ups replay as fast as possible; cold and measured runs replay in real time.
                let options = StreamingOptions(chunkSeconds: configuration.streamingChunkSeconds, realTime: phase != .warmup)
                var collector = StreamingLatencyCollector()
                for try await event in engine.streamTranscribe(audio: audio, languageHint: hint, options: options) {
                    collector.record(event)
                }
                guard let final = collector.result,
                      let latency = collector.latency(
                        bounds: item.bounds,
                        audioSeconds: audio.durationSeconds,
                        replayMaxLateness: collector.result?.engineTimings[EngineTimingKey.replayMaxLateness] ?? 0
                      )
                else {
                    throw EngineError.recognitionFailed("The stream ended without a final result.")
                }
                result = final
                record.streaming = latency
            }
            let usage = sampler.stop()
            samplerRunning = false

            record.status = .success
            record.hypothesis = result.text
            record.detectedLanguage = result.detectedLanguage
            record.languageUsed = result.languageUsed
            record.engineTimings = result.engineTimings
            record.notes = result.notes
            record.resources = usage
            record.thermallyAffected = (usage.worstThermalState ?? .nominal) >= configuration.thermalFlagThreshold
            record.accuracy = AccuracyMetrics.evaluate(reference: recording.transcript, hypothesis: result.text, keyTerms: recording.keyTerms)
        } catch is CancellationError {
            if samplerRunning { _ = sampler.stop() }
            cancelled = true
            record.status = .cancelled
            record.statusReason = "The benchmark was cancelled."
        } catch {
            if samplerRunning { _ = sampler.stop() }
            if Task.isCancelled {
                cancelled = true
                record.status = .cancelled
                record.statusReason = "The benchmark was cancelled."
            } else if let engineError = error as? EngineError, engineError.meansUnavailable {
                record.status = .unavailable
                record.statusReason = "\(engineError)"
            } else {
                record.status = .failed
                record.statusReason = "\(error)"
            }
        }

        append(record)
        completed += 1
        report(stage: "\(phase.rawValue.capitalized) run", detail: "\(engine.id) · \(recording.id)", latest: record)
    }
}

/// Keys adapters use in `RecognitionResult.engineTimings`.
public enum EngineTimingKey {
    /// Largest lateness of the streaming replay, in seconds.
    public static let replayMaxLateness = "replayMaxLatenessSeconds"
}
