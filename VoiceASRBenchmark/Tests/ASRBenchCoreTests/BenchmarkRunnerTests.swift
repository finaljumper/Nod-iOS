import XCTest
@testable import ASRBenchCore

final class BenchmarkRunnerTests: XCTestCase {
    private let english = TestDataset.recording("en-1", ["en"], "turn on the lights")
    private let russian = TestDataset.recording("ru-1", ["ru"], "включи свет на кухне")
    private let mixed = TestDataset.recording("en-ru-1", ["en", "ru"], "send the report завтра утром")

    private func quietDependencies(
        thermal: @escaping @Sendable () -> ThermalState? = { .nominal },
        battery: BatteryProbe? = nil,
        sleeps: Collected<Double> = Collected()
    ) -> BenchmarkRunner.Dependencies {
        BenchmarkRunner.Dependencies(thermalProbe: thermal, batteryProbe: battery, sleep: { sleeps.append($0) })
    }

    /// An engine that answers every recording with its reference transcript.
    private func perfectEngine(_ id: String, _ data: TestDataset, languages: Set<String>, detects: Bool = false, monitor: ConcurrencyMonitor = ConcurrencyMonitor()) -> MockEngine {
        let engine = MockEngine(id: id, languages: languages, detectsLanguage: detects, monitor: monitor)
        let byFingerprint = Dictionary(uniqueKeysWithValues: data.dataset.manifest.recordings.compactMap { recording in
            data.fingerprints[recording.id].map { ($0, recording.transcript) }
        })
        engine.respond = { fingerprint, _ in byFingerprint[fingerprint] ?? "" }
        return engine
    }

    func testRunsEveryCombinationInPhases() async throws {
        let data = try TestDataset([english, russian])
        defer { data.cleanUp() }
        let a = perfectEngine("a", data, languages: ["en", "ru"])
        let b = perfectEngine("b", data, languages: ["en", "ru"])
        let config = BenchmarkConfiguration(repetitions: 3, warmupRuns: 1, measureColdStart: true, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [a, b], configuration: config)

        XCTAssertFalse(run.cancelled)
        XCTAssertEqual(run.records.count, 18)
        for engine in ["a", "b"] {
            let records = run.records.filter { $0.engineID == engine }
            XCTAssertEqual(records.filter { $0.phase == .cold }.count, 1)
            XCTAssertEqual(records.filter { $0.phase == .warmup }.count, 2)
            XCTAssertEqual(records.filter { $0.phase == .measured }.count, 6)
            XCTAssertEqual(Set(records.filter { $0.phase == .measured }.map(\.repetition)), [0, 1, 2])
        }
        XCTAssertTrue(run.records.allSatisfy { $0.status == .success })
        XCTAssertEqual(run.records.map(\.sequence), Array(0..<18))
        XCTAssertTrue(run.records.allSatisfy { $0.batch != nil && $0.streaming == nil })
        XCTAssertTrue(run.records.allSatisfy { $0.accuracy?.relaxed.wer == 0 })

        // Cold start: unload, then a load without downloads, before any transcription.
        XCTAssertEqual(a.calls.values.prefix(3).map(\.kind), ["unload", "prepare", "transcribe"])
        XCTAssertFalse(a.calls.values.contains { $0.kind == "prepare-with-download" })
        XCTAssertNotNil(run.engines[0].coldPreparation)
        XCTAssertNil(run.engines[0].preparation)
    }

    func testWithoutColdStartThereAreNoColdRecords() async throws {
        let data = try TestDataset([english])
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en"])
        let config = BenchmarkConfiguration(repetitions: 2, warmupRuns: 0, measureColdStart: false, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertEqual(run.records.map(\.phase), [.measured, .measured])
        XCTAssertFalse(engine.calls.values.contains { $0.kind == "unload" })
        XCTAssertNil(run.engines[0].coldPreparation)
        XCTAssertNotNil(run.engines[0].preparation)
    }

    func testUnsupportedLanguageIsUnavailableNotFailed() async throws {
        let data = try TestDataset([english, russian])
        defer { data.cleanUp() }
        let full = perfectEngine("full", data, languages: ["en", "ru"])
        let englishOnly = perfectEngine("english-only", data, languages: ["en"])
        let config = BenchmarkConfiguration(repetitions: 3, warmupRuns: 1, measureColdStart: false, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [full, englishOnly], configuration: config)

        let unavailable = run.records.filter { $0.status == .unavailable }
        XCTAssertEqual(unavailable.count, 1, "recorded once, not once per repetition")
        XCTAssertEqual(unavailable.first?.engineID, "english-only")
        XCTAssertEqual(unavailable.first?.recordingID, "ru-1")
        XCTAssertEqual(unavailable.first?.statusReason, "english-only does not support ru.")
        XCTAssertNil(unavailable.first?.accuracy)
        XCTAssertFalse(run.records.contains { $0.status == .failed })
        // The engine was never asked to transcribe Russian.
        XCTAssertFalse(englishOnly.calls.values.contains { $0.hint == "ru" && $0.kind == "transcribe" })
        XCTAssertEqual(run.engines[1].availability["ru"], "english-only does not support ru.")
        XCTAssertEqual(run.engines[1].availability["en"], "available")

        let all = run.summaries.first { $0.engineID == "english-only" && $0.groupKind == "all" }!
        XCTAssertEqual(all.unavailableRuns, 1)
        XCTAssertEqual(all.failedRuns, 0)
        XCTAssertEqual(all.measuredRuns, 3)
        XCTAssertEqual(all.werRelaxed, 0, "an unavailable language must not count as errors")
        let russianGroup = run.summaries.first { $0.engineID == "english-only" && $0.groupKind == "language" && $0.groupValue == "ru" }!
        XCTAssertNil(russianGroup.werRelaxed)
        XCTAssertEqual(russianGroup.unavailableRuns, 1)
    }

    func testAutoDetectionIsUnavailableForEnginesThatNeedAHint() async throws {
        let data = try TestDataset([english])
        defer { data.cleanUp() }
        let detecting = perfectEngine("detecting", data, languages: ["en"], detects: true)
        let hinted = perfectEngine("hinted", data, languages: ["en"], detects: false)
        let config = BenchmarkConfiguration(repetitions: 2, warmupRuns: 0, measureColdStart: false, hintModes: [.primary, .auto])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [detecting, hinted], configuration: config)

        let auto = run.records.filter { $0.hintRole == .auto }
        XCTAssertEqual(auto.filter { $0.engineID == "detecting" && $0.status == .success }.count, 2)
        XCTAssertTrue(auto.filter { $0.engineID == "detecting" }.allSatisfy { $0.languageHint == nil && $0.detectedLanguage == "en" })
        let blocked = auto.filter { $0.engineID == "hinted" }
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked.first?.status, .unavailable)
        XCTAssertEqual(run.engines[1].availability["auto"], "hinted cannot detect the language.")
    }

    func testAlternateHintsForCodeSwitchedRecordings() async throws {
        let data = try TestDataset([mixed])
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en", "ru"])
        let config = BenchmarkConfiguration(repetitions: 1, warmupRuns: 0, measureColdStart: false, hintModes: [.primary, .alternates])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertEqual(run.records.map(\.languageHint), ["en", "ru"])
        XCTAssertEqual(run.records.map(\.hintRole), [.primary, .alternate])
        // Primary and alternate runs are aggregated separately.
        XCTAssertEqual(Set(run.summaries.filter { $0.groupKind == "all" }.map(\.hintRole)), [.primary, .alternate])
        XCTAssertNotNil(run.summaries.first { $0.groupKind == "code-switched" && $0.groupValue == "yes" })
        XCTAssertNotNil(run.summaries.first { $0.groupKind == "language" && $0.groupValue == "en+ru" })
    }

    func testRecognitionFailureIsRecordedAndTheRunContinues() async throws {
        let data = try TestDataset([english, russian])
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en", "ru"])
        let englishFingerprint = data.fingerprints["en-1"]!
        engine.respond = { fingerprint, _ in
            if fingerprint == englishFingerprint { throw EngineError.recognitionFailed("decoder crashed") }
            return "включи свет на кухне"
        }
        let config = BenchmarkConfiguration(repetitions: 2, warmupRuns: 0, measureColdStart: false, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertEqual(run.records.filter { $0.status == .failed }.count, 2)
        XCTAssertEqual(run.records.filter { $0.status == .success }.count, 2)
        XCTAssertEqual(run.records.first { $0.status == .failed }?.statusReason, "Recognition failed: decoder crashed")
        let all = run.summaries.first { $0.groupKind == "all" }!
        XCTAssertEqual(all.failedRuns, 2)
        XCTAssertEqual(all.unavailableRuns, 0)
    }

    func testMissingAssetsBlockTheEngineAsUnavailable() async throws {
        let data = try TestDataset([english, russian])
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en", "ru"])
        engine.prepareError = .assetsMissing("model not downloaded")
        let config = BenchmarkConfiguration(repetitions: 3, warmupRuns: 1, measureColdStart: true, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertEqual(run.records.count, 2)
        XCTAssertTrue(run.records.allSatisfy { $0.status == .unavailable })
        XCTAssertEqual(run.engines[0].preparationError, "Assets missing: model not downloaded")
        XCTAssertFalse(engine.calls.values.contains { $0.kind == "transcribe" })
    }

    func testEngineWithNoUsableLanguageIsNeverLoaded() async throws {
        let data = try TestDataset([english, russian])
        defer { data.cleanUp() }
        let engine = perfectEngine("korean-only", data, languages: ["ko"])
        let config = BenchmarkConfiguration(repetitions: 3, warmupRuns: 1, measureColdStart: true, hintModes: [.primary, .auto])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertTrue(engine.calls.values.isEmpty, "an engine with nothing to run is neither loaded nor unloaded")
        XCTAssertEqual(run.records.count, 4)
        XCTAssertTrue(run.records.allSatisfy { $0.status == .unavailable })
        // Every combination keeps its own reason.
        XCTAssertEqual(
            Set(run.records.compactMap(\.statusReason)),
            ["korean-only does not support en.", "korean-only does not support ru.", "korean-only cannot detect the language."]
        )
    }

    func testLanguageNeedingDownloadIsNotRun() async throws {
        let data = try TestDataset([english, russian])
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en", "ru"])
        engine.needsDownload = ["ru"]
        let config = BenchmarkConfiguration(repetitions: 1, warmupRuns: 0, measureColdStart: false, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertEqual(run.records.first { $0.recordingID == "ru-1" }?.status, .unavailable)
        XCTAssertEqual(run.records.first { $0.recordingID == "en-1" }?.status, .success)
        // Only the available language was requested at load time.
        XCTAssertEqual(engine.calls.values.first { $0.kind == "prepare" }?.hint, "en")
    }

    func testMissingAudioIsSkippedForEveryEngine() async throws {
        let data = try TestDataset([english, russian], missing: ["ru-1"])
        defer { data.cleanUp() }
        let a = perfectEngine("a", data, languages: ["en", "ru"])
        let b = perfectEngine("b", data, languages: ["en", "ru"])
        let config = BenchmarkConfiguration(repetitions: 1, warmupRuns: 0, measureColdStart: false, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [a, b], configuration: config)
        let skipped = run.records.filter { $0.status == .skipped }
        XCTAssertEqual(Set(skipped.map(\.engineID)), ["a", "b"])
        XCTAssertTrue(skipped.allSatisfy { $0.recordingID == "ru-1" && $0.statusReason?.contains("not found") == true })
        XCTAssertFalse(run.summaries.contains { $0.groupValue == "ru" }, "skipped recordings do not appear in aggregates")
    }

    func testTranscriptionsNeverOverlap() async throws {
        let data = try TestDataset([english, russian])
        defer { data.cleanUp() }
        let monitor = ConcurrencyMonitor()
        let a = perfectEngine("a", data, languages: ["en", "ru"], monitor: monitor)
        let b = perfectEngine("b", data, languages: ["en", "ru"], monitor: monitor)
        a.transcribeDelay = 0.01
        b.transcribeDelay = 0.01
        let config = BenchmarkConfiguration(repetitions: 2, warmupRuns: 1, measureColdStart: true, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [a, b], configuration: config)
        XCTAssertEqual(monitor.maxInFlight, 1)
        XCTAssertTrue(run.records.allSatisfy { ($0.batch?.inferenceSeconds ?? 0) >= 0.009 })
    }

    func testBothEnginesReceiveTheSameAudio() async throws {
        let data = try TestDataset([english])
        defer { data.cleanUp() }
        let a = perfectEngine("a", data, languages: ["en"])
        let b = perfectEngine("b", data, languages: ["en"])
        b.format = EngineAudioFormat(sampleRate: 16_000, encoding: .int16)
        let config = BenchmarkConfiguration(repetitions: 1, warmupRuns: 0, measureColdStart: false, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [a, b], configuration: config)
        let audioA = a.receivedAudio.values[0], audioB = b.receivedAudio.values[0]
        XCTAssertEqual(audioA.samples, audioB.samples)
        XCTAssertEqual(audioA.sourceFingerprint, audioB.sourceFingerprint)
        XCTAssertNotNil(audioB.int16Samples)
        XCTAssertEqual(Set(run.records.compactMap(\.audioFingerprint)), [data.fingerprints["en-1"]!])
    }

    private func order(seed: UInt64, randomize: Bool = true) async throws -> [String] {
        let recordings = (0..<8).map { TestDataset.recording("r\($0)", ["en"], "text \($0)") }
        let data = try TestDataset(recordings, seconds: 0.05)
        defer { data.cleanUp() }
        let a = perfectEngine("a", data, languages: ["en"])
        let b = perfectEngine("b", data, languages: ["en"])
        let config = BenchmarkConfiguration(repetitions: 1, warmupRuns: 0, measureColdStart: false, hintModes: [.primary], randomizeEngineOrder: randomize, randomSeed: seed)
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [a, b], configuration: config)
        return run.records.map { "\($0.engineID):\($0.recordingID)" }
    }

    func testRandomizedEngineOrderIsReproducibleAndActuallyVaries() async throws {
        let first = try await order(seed: 7)
        let again = try await order(seed: 7)
        XCTAssertEqual(first, again)

        // Recordings stay in manifest order; within each recording both engines run once.
        XCTAssertEqual(first.count, 16)
        let starters = stride(from: 0, to: 16, by: 2).map { String(first[$0].prefix(1)) }
        XCTAssertEqual(Set(starters), ["a", "b"], "with 8 recordings both engines should go first at least once")
        for pair in stride(from: 0, to: 16, by: 2) {
            XCTAssertEqual(Set([first[pair].prefix(1), first[pair + 1].prefix(1)]), ["a", "b"])
            XCTAssertEqual(first[pair].dropFirst(2), first[pair + 1].dropFirst(2))
        }

        let fixed = try await order(seed: 7, randomize: false)
        XCTAssertTrue(stride(from: 0, to: 16, by: 2).allSatisfy { fixed[$0].hasPrefix("a:") })
    }

    func testEngineBlocksUnloadOtherEnginesAndAttributeBattery() async throws {
        let data = try TestDataset([english])
        defer { data.cleanUp() }
        let a = perfectEngine("a", data, languages: ["en"])
        let b = perfectEngine("b", data, languages: ["en"])
        let level = Collected<Double>()
        let battery: BatteryProbe = {
            level.append(0)
            return BatteryReading(level: 1.0 - Double(level.values.count) * 0.01, isCharging: false, timestamp: Date(timeIntervalSince1970: 0))
        }
        let config = BenchmarkConfiguration(repetitions: 2, warmupRuns: 0, measureColdStart: false, hintModes: [.primary], executionOrder: .engineBlocks, randomizeEngineOrder: false)
        let run = await BenchmarkRunner(dependencies: quietDependencies(battery: battery)).run(dataset: data.dataset, engines: [a, b], configuration: config)

        XCTAssertEqual(run.records.map(\.engineID), ["a", "a", "b", "b"])
        // Engine a is unloaded before engine b's block starts.
        XCTAssertEqual(a.calls.values.last?.kind, "unload")
        XCTAssertEqual(run.battery.map(\.scope), ["whole-run", "a", "b"])
        XCTAssertTrue(run.battery.allSatisfy { ($0.levelDrop ?? 0) > 0 })
    }

    func testChargingDeviceReportsNoBatteryDrop() {
        let start = BatteryReading(level: 0.8, isCharging: true)
        let end = BatteryReading(level: 0.8, isCharging: false)
        XCTAssertNil(BatteryImpact(scope: "x", start: start, end: end).levelDrop)
    }

    func testHotRunsAreFlaggedAndCooldownIsBounded() async throws {
        let data = try TestDataset([english])
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en"])
        let sleeps = Collected<Double>()
        let config = BenchmarkConfiguration(repetitions: 2, warmupRuns: 0, measureColdStart: false, hintModes: [.primary], thermalFlagThreshold: .serious, waitForCooldown: true, maxCooldownSeconds: 3)
        let run = await BenchmarkRunner(dependencies: quietDependencies(thermal: { .serious }, sleeps: sleeps))
            .run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertTrue(run.records.allSatisfy(\.thermallyAffected))
        XCTAssertEqual(run.records.first?.resources?.thermalStateBefore, .serious)
        XCTAssertEqual(sleeps.values.count, 6, "waits at most maxCooldownSeconds before each run, then runs anyway")
        XCTAssertEqual(run.summaries.first { $0.groupKind == "all" }?.thermallyAffectedRuns, 2)

        let cool = await BenchmarkRunner(dependencies: quietDependencies(thermal: { .fair }))
            .run(dataset: data.dataset, engines: [perfectEngine("a", data, languages: ["en"])], configuration: config)
        XCTAssertFalse(cool.records.contains(where: \.thermallyAffected))
    }

    func testStreamingModeRecordsLatenciesAndReplaysInRealTime() async throws {
        let data = try TestDataset([english], seconds: 0.3)
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en"])
        let config = BenchmarkConfiguration(mode: .streaming, repetitions: 2, warmupRuns: 1, measureColdStart: false, hintModes: [.primary], streamingChunkSeconds: 0.1)
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)

        // The warm-up replays fast, measured runs replay in real time.
        XCTAssertEqual(engine.calls.values.filter { $0.kind.hasPrefix("stream") }.map(\.kind), ["stream-fast", "stream", "stream"])
        let measured = run.records.filter { $0.phase == .measured }
        XCTAssertEqual(measured.count, 2)
        for record in measured {
            XCTAssertEqual(record.status, .success)
            XCTAssertNil(record.batch)
            let latency = try XCTUnwrap(record.streaming)
            XCTAssertGreaterThanOrEqual(latency.timeToFinal, 0.3)
            XCTAssertLessThan(latency.timeToFinal, 0.8)
            XCTAssertEqual(try XCTUnwrap(latency.timeToFirstPartial), 0.2, accuracy: 0.1)
            XCTAssertFalse(latency.stableBeforeFinal)
            XCTAssertGreaterThanOrEqual(latency.endOfAudioToFinal, 0)
            XCTAssertEqual(latency.partialCount, 1)
            XCTAssertEqual(latency.speechBoundsSource, "energy-estimate")
        }
        let summary = try XCTUnwrap(run.summaries.first { $0.groupKind == "all" })
        XCTAssertNotNil(summary.timeToFinal)
        XCTAssertNil(summary.realTimeFactor)
    }

    func testEngineWithoutStreamingIsUnavailableInStreamingMode() async throws {
        let data = try TestDataset([english])
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en"])
        engine.streamingSupport = .unsupported("batch only")
        let config = BenchmarkConfiguration(mode: .streaming, repetitions: 2, warmupRuns: 1, measureColdStart: true, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertEqual(run.records.count, 1)
        XCTAssertEqual(run.records.first?.status, .unavailable)
        XCTAssertEqual(run.records.first?.statusReason, "batch only")
        XCTAssertFalse(engine.calls.values.contains { $0.kind.hasPrefix("stream") })
    }

    func testCancellationReturnsPartialResults() async throws {
        let recordings = (0..<10).map { TestDataset.recording("r\($0)", ["en"], "text \($0)") }
        let data = try TestDataset(recordings, seconds: 0.05)
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en"])
        engine.transcribeDelay = 0.1
        let config = BenchmarkConfiguration(repetitions: 3, warmupRuns: 0, measureColdStart: false, hintModes: [.primary])
        let dataset = data.dataset
        let runner = BenchmarkRunner(dependencies: quietDependencies())
        let task = Task { await runner.run(dataset: dataset, engines: [engine], configuration: config) }
        try await Task.sleep(nanoseconds: 350_000_000)
        task.cancel()
        let run = await task.value
        XCTAssertTrue(run.cancelled)
        XCTAssertLessThan(run.records.count, 30)
        XCTAssertGreaterThan(run.records.filter { $0.status == .success }.count, 0)
        XCTAssertEqual(run.records.filter { $0.status == .cancelled }.count, 1)
        // Completed runs are still aggregated.
        XCTAssertNotNil(run.summaries.first { $0.groupKind == "all" })
    }

    func testAccuracyAndAggregatesAreComputed() async throws {
        let command = TestDataset.recording("cmd", ["en"], "Call Dmitri at 10:30", category: .command, keyTerms: ["Dmitri", "10:30"])
        let data = try TestDataset([english, command])
        defer { data.cleanUp() }
        let engine = MockEngine(id: "a", languages: ["en"])
        let fingerprints = data.fingerprints
        engine.respond = { fingerprint, _ in
            fingerprint == fingerprints["cmd"] ? "call Dimitri at 10:30" : "Turn on the light."
        }
        let config = BenchmarkConfiguration(repetitions: 3, warmupRuns: 0, measureColdStart: false, hintModes: [.primary])
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)

        let commandRecord = try XCTUnwrap(run.records.first { $0.recordingID == "cmd" })
        XCTAssertEqual(commandRecord.accuracy?.relaxed.words, EditCounts(substitutions: 1, hits: 3))
        XCTAssertEqual(commandRecord.accuracy?.keyTerms?.matched, 1)
        XCTAssertEqual(commandRecord.accuracy?.exactMatch, false)
        XCTAssertEqual(commandRecord.hypothesis, "call Dimitri at 10:30")

        // Pooled: (1 + 1) errors over (4 + 4) reference words per repetition.
        let all = try XCTUnwrap(run.summaries.first { $0.groupKind == "all" })
        XCTAssertEqual(all.werRelaxed!, 0.25, accuracy: 1e-12)
        XCTAssertEqual(all.measuredRuns, 6)
        XCTAssertEqual(all.recordingCount, 2)
        XCTAssertEqual(all.inferenceSeconds?.count, 6)
        XCTAssertNotNil(all.realTimeFactor)
        XCTAssertEqual(all.keyTermRecall, 0.5)
        XCTAssertGreaterThan(all.werConservative!, all.werRelaxed!)

        let commands = try XCTUnwrap(run.summaries.first { $0.groupKind == "category" && $0.groupValue == "command" })
        XCTAssertEqual(commands.exactMatchRate, 0)
        XCTAssertEqual(commands.recordingCount, 1)
    }

    func testEnvironmentAndConfigurationAreRecorded() async throws {
        let data = try TestDataset([english])
        defer { data.cleanUp() }
        let engine = perfectEngine("a", data, languages: ["en"])
        let config = BenchmarkConfiguration(repetitions: 1, warmupRuns: 0, measureColdStart: false, hintModes: [.primary], randomSeed: 42)
        let run = await BenchmarkRunner(dependencies: quietDependencies()).run(dataset: data.dataset, engines: [engine], configuration: config)
        XCTAssertEqual(run.configuration, config)
        XCTAssertFalse(run.environment.deviceModel.isEmpty)
        XCTAssertGreaterThan(run.environment.processorCount, 0)
        XCTAssertEqual(run.engines.first?.descriptor.modelIdentifier, "mock-model")
        XCTAssertEqual(run.recordings.map(\.id), ["en-1"])
        XCTAssertNotNil(run.records.first?.resources?.peakMemoryBytes)
        XCTAssertTrue(run.notes.contains { $0.contains("Battery") })
    }
}
