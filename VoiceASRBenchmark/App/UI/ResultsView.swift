import ASRBenchCore
import SwiftUI
import UniformTypeIdentifiers

/// A file handed to the system exporter.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .commaSeparatedText]

    var data: Data
    var contentType: UTType
    var filename: String

    init(data: Data, contentType: UTType, filename: String) {
        self.data = data
        self.contentType = contentType
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
        filename = "export"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ResultsView: View {
    @Environment(BenchmarkViewModel.self) private var model
    @State private var normalization: NormalizationMode = .relaxed
    @State private var hintRole: HintRole = .primary
    @State private var groupKind = "language"
    @State private var exportDocument: ExportDocument?
    @State private var isExporting = false
    @State private var exportError: String?

    private let groupKinds = ["language", "category", "code-switched", "tag", "all"]

    var body: some View {
        Group {
            if let run = model.run {
                content(run)
            } else {
                ContentUnavailableView(
                    "No results yet",
                    systemImage: "chart.bar",
                    description: Text("Run a benchmark to see per-recording results and the comparison by language.")
                )
            }
        }
        .navigationTitle("Results")
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportDocument?.contentType ?? .json,
            defaultFilename: exportDocument?.filename ?? "asr-benchmark"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }

    private func content(_ run: BenchmarkRun) -> some View {
        List {
            Section("Run") {
                MetricRow(label: "Device", value: "\(run.environment.deviceModel) · \(run.environment.operatingSystem) \(run.environment.osVersion)")
                MetricRow(label: "Mode", value: run.configuration.mode.rawValue)
                MetricRow(label: "Dataset", value: run.datasetName)
                MetricRow(label: "Repetitions", value: "\(run.configuration.repetitions)")
                if run.cancelled {
                    Text("This run was cancelled; results are partial.").foregroundStyle(.orange).font(.footnote)
                }
                ForEach(run.notes, id: \.self) { note in
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Export") {
                Button("Export JSON (complete)") { export(run, kind: .json) }
                Button("Export CSV (runs)") { export(run, kind: .runsCSV) }
                Button("Export CSV (summary)") { export(run, kind: .summaryCSV) }
                if let exportError {
                    Text(exportError).foregroundStyle(.red).font(.footnote)
                }
            }

            Section("Engines") {
                ForEach(run.engines) { engine in
                    EngineReportRow(report: engine)
                }
            }

            Section {
                Picker("Normalization", selection: $normalization) {
                    Text("Relaxed").tag(NormalizationMode.relaxed)
                    Text("Conservative").tag(NormalizationMode.conservative)
                }
                .pickerStyle(.segmented)
                Picker("Language hint", selection: $hintRole) {
                    Text("Primary").tag(HintRole.primary)
                    Text("Auto-detect").tag(HintRole.auto)
                    Text("Alternate").tag(HintRole.alternate)
                }
                .pickerStyle(.segmented)
                Picker("Group by", selection: $groupKind) {
                    ForEach(groupKinds, id: \.self) { Text($0).tag($0) }
                }
                let summaries = run.summaries.filter { $0.groupKind == groupKind && $0.hintRole == hintRole }
                if summaries.isEmpty {
                    Text("No runs for this selection.").foregroundStyle(.secondary)
                }
                ForEach(groupValues(summaries), id: \.self) { value in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(value).font(.headline)
                        ForEach(summaries.filter { $0.groupValue == value }) { summary in
                            SummaryCard(summary: summary, normalization: normalization)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Comparison")
            } footer: {
                Text("Latencies are shown as median / 95th percentile over measured runs. Error rates are pooled over the group. Unavailable combinations are counted, never scored.")
            }

            Section("Cold start") {
                let cold = run.records.filter { $0.phase == .cold }
                if cold.isEmpty {
                    Text("Cold start was not measured.").foregroundStyle(.secondary)
                }
                ForEach(cold) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.engineID).font(.callout.weight(.medium))
                        MetricRow(label: "Model load", value: Format.seconds(run.engines.first { $0.id == record.engineID }?.coldPreparation?.loadSeconds))
                        if let batch = record.batch {
                            MetricRow(label: "First transcription (\(record.recordingID))", value: Format.seconds(batch.inferenceSeconds))
                        }
                        if let streaming = record.streaming {
                            MetricRow(label: "First transcription, time to final", value: Format.seconds(streaming.timeToFinal))
                        }
                    }
                }
            }

            Section("Recordings") {
                ForEach(run.recordings) { recording in
                    NavigationLink {
                        TranscriptComparisonView(recording: recording, records: run.records.filter { $0.recordingID == recording.id && $0.phase == .measured })
                    } label: {
                        RecordingRow(recording: recording, records: run.records.filter { $0.recordingID == recording.id && $0.phase == .measured }, normalization: normalization)
                    }
                }
            }
        }
    }

    private func groupValues(_ summaries: [AggregateSummary]) -> [String] {
        var values: [String] = []
        for summary in summaries where !values.contains(summary.groupValue) { values.append(summary.groupValue) }
        return values
    }

    private enum ExportKind { case json, runsCSV, summaryCSV }

    private func export(_ run: BenchmarkRun, kind: ExportKind) {
        exportError = nil
        let stem = ResultsExporter.fileStem(for: run)
        do {
            switch kind {
            case .json:
                exportDocument = ExportDocument(data: try ResultsExporter.json(run), contentType: .json, filename: stem)
            case .runsCSV:
                exportDocument = ExportDocument(data: Data(ResultsExporter.runsCSV(run).utf8), contentType: .commaSeparatedText, filename: stem + "-runs")
            case .summaryCSV:
                exportDocument = ExportDocument(data: Data(ResultsExporter.summaryCSV(run).utf8), contentType: .commaSeparatedText, filename: stem + "-summary")
            }
            isExporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct EngineReportRow: View {
    var report: EngineReport

    var body: some View {
        DisclosureGroup(report.descriptor.displayName) {
            MetricRow(label: "Model", value: report.descriptor.modelIdentifier)
            MetricRow(label: "Version", value: report.descriptor.engineVersion)
            if let cold = report.coldPreparation {
                MetricRow(label: "Cold load", value: Format.seconds(cold.loadSeconds))
                MetricRow(label: "Model storage", value: cold.modelStorageBytes.map { Format.megabytes(Double($0)) } ?? "not measurable")
            } else if let preparation = report.preparation {
                MetricRow(label: "Load", value: Format.seconds(preparation.loadSeconds))
                MetricRow(label: "Model storage", value: preparation.modelStorageBytes.map { Format.megabytes(Double($0)) } ?? "not measurable")
            }
            if let error = report.preparationError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            ForEach(report.availability.sorted { $0.key < $1.key }, id: \.key) { entry in
                MetricRow(label: entry.key, value: entry.value)
            }
            CapabilityList(capabilities: report.descriptor.capabilities)
        }
    }
}

struct CapabilityList: View {
    var capabilities: EngineCapabilities

    private struct Row: Identifiable {
        var name: String
        var support: CapabilitySupport
        var id: String { name }
    }

    private var rows: [Row] {
        [
            Row(name: "Streaming", support: capabilities.streaming),
            Row(name: "Partial results", support: capabilities.partialResults),
            Row(name: "Segment timestamps", support: capabilities.segmentTimestamps),
            Row(name: "Word timestamps", support: capabilities.wordTimestamps),
            Row(name: "Language detection", support: capabilities.languageDetection),
            Row(name: "Code-switching", support: capabilities.codeSwitching),
            Row(name: "Model storage size", support: capabilities.modelStorageMeasurable),
            Row(name: "Explicit unload", support: capabilities.explicitUnload),
        ]
    }

    var body: some View {
        ForEach(rows) { row in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.name).font(.callout)
                    Spacer()
                    Text(row.support.level.label).font(.caption.weight(.semibold)).foregroundStyle(row.support.level.color)
                }
                if let note = row.support.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SummaryCard: View {
    var summary: AggregateSummary
    var normalization: NormalizationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.engineID).font(.callout.weight(.medium))
            if summary.measuredRuns == 0 {
                Text(summary.unavailableRuns > 0 ? "Unavailable for this group" : "No successful runs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                MetricRow(label: "WER", value: Format.percent(normalization == .relaxed ? summary.werRelaxed : summary.werConservative))
                MetricRow(label: "CER", value: Format.percent(normalization == .relaxed ? summary.cerRelaxed : summary.cerConservative))
                let words = normalization == .relaxed ? summary.wordsRelaxed : summary.wordsConservative
                MetricRow(label: "Sub / Del / Ins", value: "\(words.substitutions) / \(words.deletions) / \(words.insertions) of \(words.referenceLength)")
                if summary.keyTermTotal > 0 {
                    MetricRow(label: "Key-term recall", value: Format.percent(summary.keyTermRecall))
                }
                if summary.groupKind == "category", summary.groupValue == RecordingCategory.command.rawValue {
                    MetricRow(label: "Commands exactly right", value: Format.percent(summary.exactMatchRate))
                }
                if summary.byScript.count > 1 {
                    ForEach(summary.byScript.sorted { $0.key < $1.key }, id: \.key) { entry in
                        MetricRow(label: "  \(entry.key) words", value: "\(Format.percent(entry.value.errorRate)) error")
                    }
                }
                if summary.mode == .batch {
                    MetricRow(label: "Time to final", value: Format.medianAndP95(summary.inferenceSeconds))
                    MetricRow(label: "Real-time factor", value: Format.medianAndP95(summary.realTimeFactor, Format.factor))
                } else {
                    MetricRow(label: "First partial", value: Format.medianAndP95(summary.timeToFirstPartial))
                    MetricRow(label: "First stable", value: Format.medianAndP95(summary.timeToFirstStable))
                    MetricRow(label: "End of speech → final", value: Format.medianAndP95(summary.endOfSpeechToFinal))
                    MetricRow(label: "End of audio → final", value: Format.medianAndP95(summary.endOfAudioToFinal))
                }
                MetricRow(label: "Peak memory (median)", value: Format.megabytes(summary.peakMemoryBytes?.median))
                MetricRow(label: "CPU (median)", value: summary.averageCPUPercent.map { String(format: "%.0f%%", $0.median) } ?? Format.dash)
            }
            if summary.unavailableRuns > 0 || summary.failedRuns > 0 || summary.thermallyAffectedRuns > 0 {
                Text("\(summary.unavailableRuns) unavailable · \(summary.failedRuns) failed · \(summary.thermallyAffectedRuns) thermally affected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RecordingRow: View {
    var recording: Recording
    var records: [RunRecord]
    var normalization: NormalizationMode

    private var engines: [String] {
        var ids: [String] = []
        for record in records where !ids.contains(record.engineID) { ids.append(record.engineID) }
        return ids
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(recording.id).font(.callout.weight(.medium))
                Text(recording.languageKey).font(.caption).foregroundStyle(.secondary)
                Text(recording.category.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(engines, id: \.self) { engine in
                let primary = records.filter { $0.engineID == engine && $0.hintRole == .primary }
                let best = primary.first { $0.status == .success } ?? primary.first ?? records.first { $0.engineID == engine }
                HStack {
                    Text(engine).font(.caption).lineLimit(1)
                    Spacer()
                    if let best, best.status == .success {
                        Text("WER \(Format.percent(best.accuracy?.score(normalization).wer)) · CER \(Format.percent(best.accuracy?.score(normalization).cer))")
                            .font(.caption)
                            .monospacedDigit()
                    } else if let best {
                        Text(best.status.label).font(.caption).foregroundStyle(best.status.color)
                    }
                }
            }
        }
    }
}
