import Foundation

/// Writes benchmark results as JSON (complete, lossless) and CSV (flat tables for spreadsheets).
public enum ResultsExporter {
    // MARK: JSON

    public static func json(_ run: BenchmarkRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(run)
    }

    public static func decodeJSON(_ data: Data) throws -> BenchmarkRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BenchmarkRun.self, from: data)
    }

    // MARK: CSV

    /// One row per run record, including unavailable, failed and skipped ones.
    public static func runsCSV(_ run: BenchmarkRun) -> String {
        let recordings = Dictionary(run.recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let header = [
            "run_id", "device_model", "os_version", "sequence", "engine_id", "recording_id", "languages", "category",
            "mode", "phase", "repetition", "hint_role", "language_hint", "status", "status_reason",
            "audio_seconds", "audio_fingerprint", "detected_language", "language_used",
            "wer_conservative", "cer_conservative", "wer_relaxed", "cer_relaxed",
            "substitutions_relaxed", "deletions_relaxed", "insertions_relaxed", "reference_words_relaxed",
            "key_terms_matched", "key_terms_total", "exact_match",
            "decode_s", "preprocess_s", "inference_s", "rtf",
            "time_to_first_partial_s", "first_partial_after_speech_start_s", "time_to_first_stable_s", "stable_before_final",
            "time_to_final_s", "end_of_audio_to_final_s", "end_of_speech_to_final_s", "partial_count",
            "replay_max_lateness_s", "speech_bounds_source",
            "peak_memory_mb", "baseline_memory_mb", "cpu_s", "avg_cpu_percent",
            "thermal_before", "thermal_after", "thermally_affected",
            "reference", "hypothesis", "notes",
        ]
        var rows = [header]
        for record in run.records {
            let recording = recordings[record.recordingID]
            let relaxed = record.accuracy?.relaxed
            let conservative = record.accuracy?.conservative
            let streaming = record.streaming
            let resources = record.resources
            rows.append([
                run.id,
                run.environment.deviceModel,
                run.environment.osVersion,
                String(record.sequence),
                record.engineID,
                record.recordingID,
                recording?.languageKey ?? "",
                recording?.category.rawValue ?? "",
                record.mode.rawValue,
                record.phase.rawValue,
                String(record.repetition),
                record.hintRole.rawValue,
                record.languageHint ?? "",
                record.status.rawValue,
                record.statusReason ?? "",
                number(record.audioSeconds),
                record.audioFingerprint ?? "",
                record.detectedLanguage ?? "",
                record.languageUsed ?? "",
                number(conservative?.wer),
                number(conservative?.cer),
                number(relaxed?.wer),
                number(relaxed?.cer),
                integer(relaxed?.words.substitutions),
                integer(relaxed?.words.deletions),
                integer(relaxed?.words.insertions),
                integer(relaxed?.words.referenceLength),
                integer(record.accuracy?.keyTerms?.matched),
                integer(record.accuracy?.keyTerms?.total),
                record.accuracy.map { $0.exactMatch ? "true" : "false" } ?? "",
                number(record.batch?.decodeSeconds),
                number(record.batch?.preprocessSeconds),
                number(record.batch?.inferenceSeconds),
                number(record.batch?.realTimeFactor),
                number(streaming?.timeToFirstPartial),
                number(streaming?.firstPartialAfterSpeechStart),
                number(streaming?.timeToFirstStable),
                streaming.map { $0.stableBeforeFinal ? "true" : "false" } ?? "",
                number(streaming?.timeToFinal),
                number(streaming?.endOfAudioToFinal),
                number(streaming?.endOfSpeechToFinal),
                integer(streaming?.partialCount),
                number(streaming?.replayMaxLatenessSeconds),
                streaming?.speechBoundsSource ?? "",
                megabytes(resources?.peakMemoryBytes),
                megabytes(resources?.baselineMemoryBytes),
                number(resources?.cpuSeconds),
                number(resources?.averageCPUPercent),
                resources?.thermalStateBefore?.label ?? "",
                resources?.thermalStateAfter?.label ?? "",
                record.thermallyAffected ? "true" : "false",
                recording?.transcript ?? "",
                record.hypothesis ?? "",
                record.notes.joined(separator: " | "),
            ])
        }
        return csv(rows)
    }

    /// One row per aggregate (engine, mode, hint role and group).
    public static func summaryCSV(_ run: BenchmarkRun) -> String {
        let header = [
            "run_id", "device_model", "os_version", "engine_id", "mode", "hint_role", "group_kind", "group_value",
            "recordings", "measured_runs", "unavailable_runs", "failed_runs", "thermally_affected_runs",
            "wer_conservative", "cer_conservative", "wer_relaxed", "cer_relaxed",
            "substitutions_relaxed", "deletions_relaxed", "insertions_relaxed", "reference_words_relaxed",
            "key_term_recall", "key_term_total", "exact_match_rate",
            "inference_median_s", "inference_p95_s", "rtf_median", "rtf_p95",
            "first_partial_median_s", "first_partial_p95_s",
            "first_stable_median_s", "first_stable_p95_s",
            "final_median_s", "final_p95_s",
            "end_of_audio_to_final_median_s", "end_of_audio_to_final_p95_s",
            "end_of_speech_to_final_median_s", "end_of_speech_to_final_p95_s",
            "peak_memory_median_mb", "peak_memory_max_mb", "avg_cpu_percent_median",
        ]
        var rows = [header]
        for summary in run.summaries {
            rows.append([
                run.id,
                run.environment.deviceModel,
                run.environment.osVersion,
                summary.engineID,
                summary.mode.rawValue,
                summary.hintRole.rawValue,
                summary.groupKind,
                summary.groupValue,
                String(summary.recordingCount),
                String(summary.measuredRuns),
                String(summary.unavailableRuns),
                String(summary.failedRuns),
                String(summary.thermallyAffectedRuns),
                number(summary.werConservative),
                number(summary.cerConservative),
                number(summary.werRelaxed),
                number(summary.cerRelaxed),
                String(summary.wordsRelaxed.substitutions),
                String(summary.wordsRelaxed.deletions),
                String(summary.wordsRelaxed.insertions),
                String(summary.wordsRelaxed.referenceLength),
                number(summary.keyTermRecall),
                String(summary.keyTermTotal),
                number(summary.exactMatchRate),
                number(summary.inferenceSeconds?.median), number(summary.inferenceSeconds?.p95),
                number(summary.realTimeFactor?.median), number(summary.realTimeFactor?.p95),
                number(summary.timeToFirstPartial?.median), number(summary.timeToFirstPartial?.p95),
                number(summary.timeToFirstStable?.median), number(summary.timeToFirstStable?.p95),
                number(summary.timeToFinal?.median), number(summary.timeToFinal?.p95),
                number(summary.endOfAudioToFinal?.median), number(summary.endOfAudioToFinal?.p95),
                number(summary.endOfSpeechToFinal?.median), number(summary.endOfSpeechToFinal?.p95),
                megabytes(summary.peakMemoryBytes?.median), megabytes(summary.peakMemoryBytes?.max),
                number(summary.averageCPUPercent?.median),
            ])
        }
        return csv(rows)
    }

    /// Suggested file name stem, for example `asr-benchmark-batch-Mac16,10-20261119-141500`.
    public static func fileStem(for run: BenchmarkRun) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let device = run.environment.deviceModel.replacingOccurrences(of: " ", with: "_")
        return "asr-benchmark-\(run.configuration.mode.rawValue)-\(device)-\(formatter.string(from: run.startedAt))"
    }

    // MARK: Helpers

    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting: fields containing a comma, quote or line break are quoted.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func integer(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    static func megabytes(_ bytes: UInt64?) -> String {
        megabytes(bytes.map { Double($0) })
    }

    static func megabytes(_ bytes: Double?) -> String {
        guard let bytes else { return "" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), bytes / 1_048_576)
    }
}
