import ASRBenchCore
import SwiftUI

/// Reference and recognized transcripts of one recording, side by side with a word-level diff.
struct TranscriptComparisonView: View {
    var recording: Recording
    var records: [RunRecord]

    /// One entry per engine and language hint: the first repetition stands for the group.
    private var groups: [[RunRecord]] {
        var keys: [String] = []
        var byKey: [String: [RunRecord]] = [:]
        for record in records.sorted(by: { $0.sequence < $1.sequence }) {
            let key = "\(record.engineID)|\(record.hintRole.rawValue)|\(record.languageHint ?? "auto")"
            if byKey[key] == nil { keys.append(key) }
            byKey[key, default: []].append(record)
        }
        return keys.compactMap { byKey[$0] }
    }

    var body: some View {
        List {
            Section("Reference") {
                Text(recording.transcript).textSelection(.enabled)
                MetricRow(label: "Languages", value: recording.languages.joined(separator: ", "))
                MetricRow(label: "Category", value: recording.category.rawValue)
                MetricRow(label: "Speaker", value: recording.speaker)
                if let terms = recording.keyTerms, !terms.isEmpty {
                    MetricRow(label: "Key terms", value: terms.joined(separator: ", "))
                }
            }

            ForEach(groups, id: \.first?.id) { group in
                if let first = group.first {
                    Section("\(first.engineID) · hint \(first.languageHint ?? "auto")") {
                        EngineTranscript(reference: recording.transcript, group: group)
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Text("Diff:")
                    Text("substituted").foregroundStyle(.orange)
                    Text("missing").foregroundStyle(.red).strikethrough()
                    Text("inserted").foregroundStyle(.green)
                }
                .font(.footnote)
            } footer: {
                Text("The diff uses relaxed normalization (case and punctuation ignored).")
            }
        }
        .navigationTitle(recording.id)
    }
}

private struct EngineTranscript: View {
    var reference: String
    var group: [RunRecord]

    var body: some View {
        let successes = group.filter { $0.status == .success }
        if let first = successes.first, let hypothesis = first.hypothesis, let accuracy = first.accuracy {
            Text(hypothesis.isEmpty ? "(empty transcript)" : hypothesis).textSelection(.enabled)
            Text(WordDiff.attributed(reference: reference, hypothesis: hypothesis))
            MetricRow(label: "WER relaxed / conservative", value: "\(Format.percent(accuracy.relaxed.wer)) / \(Format.percent(accuracy.conservative.wer))")
            MetricRow(label: "CER relaxed / conservative", value: "\(Format.percent(accuracy.relaxed.cer)) / \(Format.percent(accuracy.conservative.cer))")
            MetricRow(label: "Sub / Del / Ins (relaxed)", value: "\(accuracy.relaxed.words.substitutions) / \(accuracy.relaxed.words.deletions) / \(accuracy.relaxed.words.insertions)")
            if let terms = accuracy.keyTerms {
                MetricRow(label: "Key terms", value: "\(terms.matched) of \(terms.total)" + (terms.missed.isEmpty ? "" : " · missed: \(terms.missed.joined(separator: ", "))"))
            }
            if let language = first.detectedLanguage {
                MetricRow(label: "Detected language", value: language)
            } else if let language = first.languageUsed {
                MetricRow(label: "Language used", value: language)
            }
            if Set(successes.compactMap(\.hypothesis)).count > 1 {
                Text("Transcripts differ between repetitions; the first is shown.").font(.footnote).foregroundStyle(.orange)
            }
            if let inference = Distribution(successes.compactMap { $0.batch?.inferenceSeconds }) {
                MetricRow(label: "Time to final (median / p95)", value: Format.medianAndP95(inference))
                MetricRow(label: "Real-time factor (median)", value: Format.factor(Distribution(successes.compactMap { $0.batch?.realTimeFactor })?.median))
            }
            if !successes.compactMap(\.streaming).isEmpty {
                MetricRow(label: "First partial", value: Format.medianAndP95(Distribution(successes.compactMap { $0.streaming?.timeToFirstPartial })))
                MetricRow(label: "First stable", value: Format.medianAndP95(Distribution(successes.compactMap { $0.streaming?.timeToFirstStable })))
                MetricRow(label: "End of speech → final", value: Format.medianAndP95(Distribution(successes.compactMap { $0.streaming?.endOfSpeechToFinal })))
            }
            MetricRow(label: "Peak memory", value: Format.megabytes(successes.compactMap { $0.resources?.peakMemoryBytes }.max()))
            if successes.contains(where: \.thermallyAffected) {
                Text("At least one repetition ran while the device was hot.").font(.footnote).foregroundStyle(.orange)
            }
            ForEach(first.notes, id: \.self) { note in
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        } else if let first = group.first {
            Text(first.status.label).foregroundStyle(first.status.color)
            if let reason = first.statusReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

enum WordDiff {
    /// Renders the hypothesis against the reference: matches plain, substitutions orange,
    /// missing reference words struck through in red, inserted words green.
    static func attributed(reference: String, hypothesis: String) -> AttributedString {
        let referenceWords = TextNormalizer.words(reference, mode: .relaxed)
        let hypothesisWords = TextNormalizer.words(hypothesis, mode: .relaxed)
        let alignment = EditDistance.align(reference: referenceWords, hypothesis: hypothesisWords)
        var output = AttributedString()

        func append(_ word: String, color: Color?, struck: Bool = false) {
            var piece = AttributedString(word + " ")
            if let color { piece.foregroundColor = color }
            if struck { piece.strikethroughStyle = Text.LineStyle.single }
            output.append(piece)
        }

        for operation in alignment.operations {
            switch operation {
            case .match(_, let h):
                append(hypothesisWords[h], color: nil)
            case .substitution(let r, let h):
                append(referenceWords[r], color: .red, struck: true)
                append(hypothesisWords[h], color: .orange)
            case .deletion(let r):
                append(referenceWords[r], color: .red, struck: true)
            case .insertion(let h):
                append(hypothesisWords[h], color: .green)
            }
        }
        return output
    }
}
