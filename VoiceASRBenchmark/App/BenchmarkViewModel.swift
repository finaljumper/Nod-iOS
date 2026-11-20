import ASRBenchCore
import ASRBenchEngines
import ASRBenchMLXEngines
import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// A dataset the user can pick.
struct DatasetChoice: Identifiable, Hashable {
    var id: String
    var name: String
    var url: URL
    var isBundledSample: Bool
}

/// One line of the setup screen: can this engine transcribe this language right now?
struct EngineLanguageStatus: Identifiable {
    var engineID: String
    var language: String
    var availability: EngineAvailability

    var id: String { "\(engineID)|\(language)" }
}

@MainActor
@Observable
final class BenchmarkViewModel {
    // Configuration
    var useSpeechTranscriber = true
    var useDictationTranscriber = true
    var useWhisperKit = true
    var useRumble = RumbleFlashEngine.runsOnThisPlatform
    var rumbleNumbersAsWords = false
    var whisperModels: [String] = []
    var whisperModel: String = ""
    var appleFastResults = false
    var mode: BenchmarkMode = .batch
    var repetitions = 3
    var warmupRuns = 1
    var measureColdStart = true
    var randomizeEngineOrder = true
    var executionOrder: ExecutionOrder = .interleaved
    var hintPrimary = true
    var hintAuto = true
    var hintAlternates = false

    // Dataset
    var datasetChoices: [DatasetChoice] = []
    var selectedDatasetID: String = ""
    private(set) var dataset: BenchmarkDataset?
    private(set) var datasetIssues: [ManifestIssue] = []
    private(set) var datasetError: String?

    // Setup
    private(set) var engineDescriptors: [EngineDescriptor] = []
    private(set) var languageStatus: [EngineLanguageStatus] = []
    private(set) var supportedLocales: [String: [String]] = [:]
    private(set) var isPreparing = false
    private(set) var setupMessage = ""
    private(set) var setupProgress = 0.0
    let environment = EnvironmentInfo.capture()

    // Run
    private(set) var isRunning = false
    private(set) var progress: BenchmarkProgress?
    private(set) var liveRecords: [RunRecord] = []
    private(set) var run: BenchmarkRun?
    private(set) var runMessage = ""

    private var runTask: Task<Void, Never>?
    private var engines: [String: any SpeechRecognitionEngine] = [:]
    private var scopedURLs: [URL] = []
    private var didStart = false

    /// Languages the setup screen always shows, plus whatever the selected dataset contains.
    var languagesOfInterest: [String] {
        var languages = ["en", "ru", "ko"]
        for recording in dataset?.manifest.recordings ?? [] {
            for language in recording.languages where !languages.contains(language) {
                languages.append(language)
            }
        }
        return languages
    }

    var recordingsWithAudio: Int { dataset?.recordingsWithAudio.count ?? 0 }

    var hintModes: [HintMode] {
        var modes: [HintMode] = []
        if hintPrimary { modes.append(.primary) }
        if hintAuto { modes.append(.auto) }
        if hintAlternates { modes.append(.alternates) }
        return modes
    }

    var canRun: Bool {
        !isRunning && !isPreparing && recordingsWithAudio > 0 && !hintModes.isEmpty
            && (useSpeechTranscriber || useDictationTranscriber || useWhisperKit || useRumble)
            && (!useWhisperKit || !whisperModel.isEmpty)
    }

    // MARK: Start-up

    func start() async {
        guard !didStart else { return }
        didStart = true
        let catalog = WhisperKitModelCatalog.multilingualModels()
        whisperModels = catalog.supported
        whisperModel = UserDefaults.standard.string(forKey: "whisperModel").flatMap { catalog.supported.contains($0) ? $0 : nil }
            ?? catalog.recommended ?? catalog.supported.first ?? ""
        refreshDatasetChoices()
        await refreshEngineStatus()
    }

    // MARK: Datasets

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The bundled sample, every folder in the app's Documents directory that contains a
    /// `manifest.json`, and folders imported earlier.
    func refreshDatasetChoices() {
        var choices: [DatasetChoice] = []
        if let sample = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Dataset")
            ?? Bundle.main.url(forResource: "manifest", withExtension: "json") {
            choices.append(DatasetChoice(id: "bundled-sample", name: "Sample prompts (no audio)", url: sample, isBundledSample: true))
        }
        let manager = FileManager.default
        if let folders = try? manager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where manager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) {
                choices.append(DatasetChoice(id: folder.path, name: folder.lastPathComponent, url: folder, isBundledSample: false))
            }
        }
        for url in restoreImportedFolders() where !choices.contains(where: { $0.id == url.path }) {
            choices.append(DatasetChoice(id: url.path, name: url.lastPathComponent, url: url, isBundledSample: false))
        }
        datasetChoices = choices
        if !choices.contains(where: { $0.id == selectedDatasetID }) {
            let remembered = UserDefaults.standard.string(forKey: "selectedDataset")
            selectedDatasetID = choices.first(where: { $0.id == remembered })?.id
                ?? choices.first(where: { !$0.isBundledSample })?.id
                ?? choices.first?.id ?? ""
        }
        loadSelectedDataset()
    }

    func loadSelectedDataset() {
        UserDefaults.standard.set(selectedDatasetID, forKey: "selectedDataset")
        guard let choice = datasetChoices.first(where: { $0.id == selectedDatasetID }) else {
            dataset = nil
            datasetIssues = []
            return
        }
        do {
            let loaded = try BenchmarkDataset.load(from: choice.url)
            dataset = loaded
            datasetIssues = loaded.validate()
            datasetError = nil
        } catch {
            dataset = nil
            datasetIssues = []
            datasetError = "Cannot read the manifest: \(error)"
        }
    }

    /// Adds a dataset folder chosen with the file importer and remembers it.
    func importDataset(from url: URL) {
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        var bookmarks = UserDefaults.standard.array(forKey: "datasetBookmarks") as? [Data] ?? []
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        if let bookmark = try? url.bookmarkData(options: options) {
            bookmarks.append(bookmark)
            UserDefaults.standard.set(bookmarks, forKey: "datasetBookmarks")
        }
        selectedDatasetID = url.path
        refreshDatasetChoices()
    }

    private func restoreImportedFolders() -> [URL] {
        let bookmarks = UserDefaults.standard.array(forKey: "datasetBookmarks") as? [Data] ?? []
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        var urls: [URL] = []
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale) else { continue }
            if !scopedURLs.contains(url), url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path), !urls.contains(url) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: Engines

    private func engine(id: String, make: () -> any SpeechRecognitionEngine) -> any SpeechRecognitionEngine {
        if let existing = engines[id] { return existing }
        let created = make()
        engines[id] = created
        return created
    }

    private func appleEngine(_ module: AppleSpeechModule) -> AppleSpeechAnalyzerEngine {
        let configuration = AppleSpeechAnalyzerConfiguration(module: module, fastResults: appleFastResults)
        let candidate = AppleSpeechAnalyzerEngine(configuration: configuration)
        // Reuse the instance so that loaded models survive between setup and run.
        let existing = engine(id: candidate.id, make: { candidate })
        return (existing as? AppleSpeechAnalyzerEngine) ?? candidate
    }

    private var selectedAppleEngines: [AppleSpeechAnalyzerEngine] {
        var selected: [AppleSpeechAnalyzerEngine] = []
        if useSpeechTranscriber { selected.append(appleEngine(.speechTranscriber)) }
        if useDictationTranscriber { selected.append(appleEngine(.dictationTranscriber)) }
        return selected
    }

    private var whisperEngine: WhisperKitEngine? {
        guard !whisperModel.isEmpty else { return nil }
        let candidate = WhisperKitEngine(configuration: WhisperKitEngineConfiguration(model: whisperModel))
        let existing = engine(id: candidate.id, make: { candidate })
        return (existing as? WhisperKitEngine) ?? candidate
    }

    private var rumbleEngine: RumbleFlashEngine {
        let candidate = RumbleFlashEngine(configuration: RumbleFlashConfiguration(numbersAsDigits: !rumbleNumbersAsWords))
        // Reuse the instance so that the loaded model survives between setup and run.
        let existing = engine(id: candidate.id, make: { candidate })
        return (existing as? RumbleFlashEngine) ?? candidate
    }

    private var selectedEngines: [any SpeechRecognitionEngine] {
        var selected: [any SpeechRecognitionEngine] = selectedAppleEngines
        if useWhisperKit, let whisperEngine { selected.append(whisperEngine) }
        if useRumble { selected.append(rumbleEngine) }
        return selected
    }

    /// Asks every engine what it supports on this device. Runs no recognition and no downloads.
    func refreshEngineStatus() async {
        UserDefaults.standard.set(whisperModel, forKey: "whisperModel")
        var all: [any SpeechRecognitionEngine] = [appleEngine(.speechTranscriber), appleEngine(.dictationTranscriber)]
        if let whisperEngine { all.append(whisperEngine) }
        all.append(rumbleEngine)
        var descriptors: [EngineDescriptor] = []
        var status: [EngineLanguageStatus] = []
        var locales: [String: [String]] = [:]
        for engine in all {
            descriptors.append(await engine.descriptor())
            locales[engine.id] = await engine.supportedLocales()
            for language in languagesOfInterest {
                status.append(EngineLanguageStatus(engineID: engine.id, language: language, availability: await engine.availability(forLanguage: language)))
            }
            status.append(EngineLanguageStatus(engineID: engine.id, language: "auto", availability: await engine.availability(forLanguage: nil)))
        }
        engineDescriptors = descriptors
        languageStatus = status
        supportedLocales = locales
    }

    /// The explicit, network-using setup step: downloads the WhisperKit and Rumble-2-Flash models
    /// and installs the speech assets of every selected Apple engine for each language it
    /// supports. Benchmarks never download.
    func downloadModels() async {
        guard !isPreparing, !isRunning else { return }
        isPreparing = true
        setupProgress = 0
        defer { isPreparing = false }
        let report: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
            Task { @MainActor in
                self?.setupProgress = fraction
                self?.setupMessage = message
            }
        }

        var problems: [String] = []
        if useWhisperKit, let whisperEngine {
            do {
                try await whisperEngine.downloadModel(progress: report)
            } catch {
                problems.append("WhisperKit: \(error.localizedDescription)")
            }
        }
        if useRumble {
            do {
                try await rumbleEngine.downloadModel(progress: report)
            } catch {
                problems.append("Rumble-2-Flash: \(error)")
            }
        }
        for apple in selectedAppleEngines {
            for language in languagesOfInterest {
                // Languages the engine does not support are left alone; they stay "unavailable".
                guard case .needsDownload = await apple.availability(forLanguage: language) else { continue }
                do {
                    try await apple.installAssets(languages: [language], progress: report)
                } catch {
                    problems.append("\(apple.configuration.module.typeName) \(language): \(error)")
                }
            }
        }
        await refreshEngineStatus()
        setupProgress = 1
        setupMessage = problems.isEmpty ? "Setup finished. Benchmarks can now run offline." : problems.joined(separator: "\n")
    }

    // MARK: Benchmark

    var configuration: BenchmarkConfiguration {
        BenchmarkConfiguration(
            mode: mode,
            repetitions: repetitions,
            warmupRuns: warmupRuns,
            measureColdStart: measureColdStart,
            hintModes: hintModes,
            executionOrder: executionOrder,
            randomizeEngineOrder: randomizeEngineOrder
        )
    }

    func runBenchmark() {
        guard canRun, let dataset else { return }
        let engines = selectedEngines
        let configuration = configuration
        isRunning = true
        liveRecords = []
        progress = nil
        runMessage = ""
        setIdleTimerDisabled(true)

        runTask = Task { [weak self] in
            let runner = BenchmarkRunner(dependencies: BenchmarkRunner.Dependencies(
                decoder: PlatformSupport.audioLoader,
                batteryProbe: PlatformSupport.batteryProbe
            ))
            let result = await runner.run(dataset: dataset, engines: engines, configuration: configuration) { progress in
                Task { @MainActor in self?.apply(progress) }
            }
            await MainActor.run {
                guard let self else { return }
                self.run = result
                self.isRunning = false
                self.runMessage = result.cancelled
                    ? "Cancelled after \(result.records.count) records."
                    : "Finished: \(result.records.filter { $0.phase == .measured && $0.status == .success }.count) measured runs."
                self.setIdleTimerDisabled(false)
            }
        }
    }

    func cancelBenchmark() {
        runTask?.cancel()
        runMessage = "Cancelling after the current transcription…"
    }

    private func apply(_ progress: BenchmarkProgress) {
        self.progress = progress
        if let record = progress.latestRecord {
            liveRecords.insert(record, at: 0)
            if liveRecords.count > 50 { liveRecords.removeLast() }
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    func reference(for recordingID: String) -> Recording? {
        run?.recordings.first { $0.id == recordingID } ?? dataset?.manifest.recordings.first { $0.id == recordingID }
    }
}
