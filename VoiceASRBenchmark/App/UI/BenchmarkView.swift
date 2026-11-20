import ASRBenchCore
import ASRBenchMLXEngines
import SwiftUI
import UniformTypeIdentifiers

struct BenchmarkView: View {
    @Environment(BenchmarkViewModel.self) private var model
    @State private var isImporting = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Dataset") {
                Picker("Dataset", selection: $model.selectedDatasetID) {
                    ForEach(model.datasetChoices) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .onChange(of: model.selectedDatasetID) { _, _ in
                    model.loadSelectedDataset()
                    Task { await model.refreshEngineStatus() }
                }
                Button("Import dataset folder…") { isImporting = true }
                datasetSummary
            }

            Section("Engines") {
                Toggle("Apple SpeechTranscriber", isOn: $model.useSpeechTranscriber)
                if model.useSpeechTranscriber {
                    Toggle("SpeechTranscriber: fast results (streaming)", isOn: $model.appleFastResults)
                }
                Toggle("Apple DictationTranscriber", isOn: $model.useDictationTranscriber)
                Toggle("WhisperKit", isOn: $model.useWhisperKit)
                if model.useWhisperKit {
                    Picker("WhisperKit model", selection: $model.whisperModel) {
                        ForEach(model.whisperModels, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: model.whisperModel) { _, _ in
                        Task { await model.refreshEngineStatus() }
                    }
                }
                Toggle("Rumble-2-Flash (MLX)", isOn: $model.useRumble)
                    .disabled(!RumbleFlashEngine.runsOnThisPlatform)
                if model.useRumble {
                    Toggle("Rumble-2-Flash: numbers as words", isOn: $model.rumbleNumbersAsWords)
                        .onChange(of: model.rumbleNumbersAsWords) { _, _ in
                            Task { await model.refreshEngineStatus() }
                        }
                }
            }

            Section {
                Picker("Mode", selection: $model.mode) {
                    Text("Batch").tag(BenchmarkMode.batch)
                    Text("Streaming").tag(BenchmarkMode.streaming)
                }
                .pickerStyle(.segmented)
                Text(model.mode == .batch
                     ? "Each recording is processed as fast as possible. Reports time to final transcript and real-time factor."
                     : "Each recording is replayed at real-time speed. Reports partial, stable and final latencies. Takes at least the duration of the audio per run.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Mode")
            } footer: {
                Text("Batch and streaming latencies measure different things and are never compared with each other.")
            }

            Section("Method") {
                Stepper("Repetitions: \(model.repetitions)", value: $model.repetitions, in: 3...20)
                Stepper("Warm-up runs: \(model.warmupRuns)", value: $model.warmupRuns, in: 0...5)
                Toggle("Measure cold start", isOn: $model.measureColdStart)
                Toggle("Randomize engine order", isOn: $model.randomizeEngineOrder)
                Picker("Order", selection: $model.executionOrder) {
                    Text("Interleaved").tag(ExecutionOrder.interleaved)
                    Text("Engine blocks").tag(ExecutionOrder.engineBlocks)
                }
                Toggle("Hint: primary language", isOn: $model.hintPrimary)
                Toggle("Hint: none (auto-detect)", isOn: $model.hintAuto)
                Toggle("Hint: each further language", isOn: $model.hintAlternates)
            }

            Section("Run") {
                if model.isRunning {
                    Button("Cancel", role: .destructive) { model.cancelBenchmark() }
                } else {
                    Button("Run benchmark") { model.runBenchmark() }
                        .disabled(!model.canRun)
                }
                if !model.canRun, !model.isRunning, model.recordingsWithAudio == 0 {
                    Text("The selected dataset has no audio files. Import a dataset with recordings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let progress = model.progress, model.isRunning {
                    ProgressView(value: progress.fraction) {
                        Text(progress.stage)
                    } currentValueLabel: {
                        Text("\(progress.completedRuns) of \(progress.totalRuns) · \(progress.detail)")
                    }
                }
                if !model.runMessage.isEmpty {
                    Text(model.runMessage).font(.callout)
                }
            }

            if !model.liveRecords.isEmpty {
                Section("Latest runs") {
                    ForEach(model.liveRecords.prefix(12)) { record in
                        LiveRecordRow(record: record)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("ASR Benchmark")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.importDataset(from: url)
                Task { await model.refreshEngineStatus() }
            }
        }
    }

    @ViewBuilder
    private var datasetSummary: some View {
        if let error = model.datasetError {
            Text(error).foregroundStyle(.red).font(.footnote)
        } else if let dataset = model.dataset {
            let errors = model.datasetIssues.filter { $0.severity == .error }
            let warnings = model.datasetIssues.filter { $0.severity == .warning }
            MetricRow(label: "Recordings with audio", value: "\(model.recordingsWithAudio) of \(dataset.manifest.recordings.count)")
            if !errors.isEmpty || !warnings.isEmpty {
                DisclosureGroup("\(errors.count) errors, \(warnings.count) warnings") {
                    ForEach(model.datasetIssues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.recordingID ?? "Manifest").font(.caption).foregroundStyle(.secondary)
                            Text(issue.message).font(.footnote)
                                .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                        }
                    }
                }
            }
        }
    }
}

private struct LiveRecordRow: View {
    var record: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.recordingID).font(.callout.weight(.medium))
                Text(record.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(record.status.label).font(.caption).foregroundStyle(record.status.color)
            }
            Text("\(record.engineID) · hint \(record.languageHint ?? "auto")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if record.status == .success {
                HStack(spacing: 12) {
                    Text("WER \(Format.percent(record.accuracy?.relaxed.wer))")
                    Text("CER \(Format.percent(record.accuracy?.relaxed.cer))")
                    if let batch = record.batch {
                        Text("RTF \(Format.factor(batch.realTimeFactor))")
                    }
                    if let streaming = record.streaming {
                        Text("final +\(Format.seconds(streaming.endOfAudioToFinal))")
                    }
                }
                .font(.caption)
                .monospacedDigit()
            } else if let reason = record.statusReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
