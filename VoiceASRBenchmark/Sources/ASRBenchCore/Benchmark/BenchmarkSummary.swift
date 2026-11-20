import Foundation

/// Aggregated results of one engine over one group of recordings.
///
/// Only measured, successful runs contribute to accuracy and latency. Unavailable, failed and
/// skipped runs are counted but never turned into error rates.
public struct AggregateSummary: Codable, Sendable, Equatable, Identifiable {
    public var engineID: String
    public var mode: BenchmarkMode
    public var hintRole: HintRole
    /// What the group is defined by: `all`, `language`, `category`, `code-switched` or `tag`.
    public var groupKind: String
    /// The group's value, for example `en+ru`, `command` or `yes`.
    public var groupValue: String

    public var recordingCount: Int
    public var measuredRuns: Int
    public var unavailableRuns: Int
    public var failedRuns: Int
    public var thermallyAffectedRuns: Int

    /// Pooled error rates: total errors divided by total reference length over all measured
    /// runs, so long recordings weigh more than short ones.
    public var werConservative: Double?
    public var cerConservative: Double?
    public var werRelaxed: Double?
    public var cerRelaxed: Double?
    public var wordsConservative: EditCounts
    public var wordsRelaxed: EditCounts
    public var charactersRelaxed: EditCounts

    /// Pooled key-term recall (proper nouns, dates, numbers).
    public var keyTermRecall: Double?
    public var keyTermTotal: Int
    /// Share of runs whose relaxed-normalized transcript matched the reference exactly.
    public var exactMatchRate: Double?
    /// Relaxed word outcomes by script, pooled.
    public var byScript: [String: EditCounts]

    // Batch mode.
    public var inferenceSeconds: Distribution?
    public var realTimeFactor: Distribution?

    // Streaming mode.
    public var timeToFirstPartial: Distribution?
    public var firstPartialAfterSpeechStart: Distribution?
    public var timeToFirstStable: Distribution?
    public var timeToFinal: Distribution?
    public var endOfAudioToFinal: Distribution?
    public var endOfSpeechToFinal: Distribution?

    public var peakMemoryBytes: Distribution?
    public var averageCPUPercent: Distribution?

    public var id: String { "\(engineID)|\(mode.rawValue)|\(hintRole.rawValue)|\(groupKind)|\(groupValue)" }
}

public enum BenchmarkSummarizer {
    /// Builds every aggregate for a set of records.
    public static func summarize(records: [RunRecord], recordings: [Recording]) -> [AggregateSummary] {
        let byID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let relevant = records.filter { $0.phase == .measured && $0.status != .skipped && $0.status != .cancelled }

        struct Key: Hashable {
            var engineID: String
            var mode: BenchmarkMode
            var hintRole: HintRole
            var groupKind: String
            var groupValue: String
        }

        var groups: [Key: [RunRecord]] = [:]
        var order: [Key] = []
        for record in relevant {
            guard let recording = byID[record.recordingID] else { continue }
            var memberships: [(String, String)] = [
                ("all", "all"),
                ("language", recording.languageKey),
                ("category", recording.category.rawValue),
                ("code-switched", recording.isCodeSwitched ? "yes" : "no"),
            ]
            for tag in recording.tags ?? [] { memberships.append(("tag", tag)) }
            for (kind, value) in memberships {
                let key = Key(engineID: record.engineID, mode: record.mode, hintRole: record.hintRole, groupKind: kind, groupValue: value)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(record)
            }
        }

        return order.map { key in
            summary(
                engineID: key.engineID,
                mode: key.mode,
                hintRole: key.hintRole,
                groupKind: key.groupKind,
                groupValue: key.groupValue,
                records: groups[key] ?? []
            )
        }
    }

    static func summary(
        engineID: String,
        mode: BenchmarkMode,
        hintRole: HintRole,
        groupKind: String,
        groupValue: String,
        records: [RunRecord]
    ) -> AggregateSummary {
        let successes = records.filter { $0.status == .success }
        let scored = successes.compactMap(\.accuracy)

        var wordsConservative = EditCounts(), charactersConservative = EditCounts()
        var wordsRelaxed = EditCounts(), charactersRelaxed = EditCounts()
        var byScript: [String: EditCounts] = [:]
        var termTotal = 0, termMatched = 0, exact = 0
        for accuracy in scored {
            wordsConservative += accuracy.conservative.words
            charactersConservative += accuracy.conservative.characters
            wordsRelaxed += accuracy.relaxed.words
            charactersRelaxed += accuracy.relaxed.characters
            for (script, counts) in accuracy.byScript { byScript[script, default: EditCounts()] += counts }
            if let terms = accuracy.keyTerms {
                termTotal += terms.total
                termMatched += terms.matched
            }
            if accuracy.exactMatch { exact += 1 }
        }
        let hasScores = !scored.isEmpty

        func distribution(_ value: (RunRecord) -> Double?) -> Distribution? {
            Distribution(successes.compactMap(value))
        }

        return AggregateSummary(
            engineID: engineID,
            mode: mode,
            hintRole: hintRole,
            groupKind: groupKind,
            groupValue: groupValue,
            recordingCount: Set(records.map(\.recordingID)).count,
            measuredRuns: successes.count,
            unavailableRuns: records.filter { $0.status == .unavailable }.count,
            failedRuns: records.filter { $0.status == .failed }.count,
            thermallyAffectedRuns: successes.filter(\.thermallyAffected).count,
            werConservative: hasScores ? wordsConservative.errorRate : nil,
            cerConservative: hasScores ? charactersConservative.errorRate : nil,
            werRelaxed: hasScores ? wordsRelaxed.errorRate : nil,
            cerRelaxed: hasScores ? charactersRelaxed.errorRate : nil,
            wordsConservative: wordsConservative,
            wordsRelaxed: wordsRelaxed,
            charactersRelaxed: charactersRelaxed,
            keyTermRecall: termTotal > 0 ? Double(termMatched) / Double(termTotal) : nil,
            keyTermTotal: termTotal,
            exactMatchRate: hasScores ? Double(exact) / Double(scored.count) : nil,
            byScript: byScript,
            inferenceSeconds: distribution { $0.batch?.inferenceSeconds },
            realTimeFactor: distribution { $0.batch?.realTimeFactor },
            timeToFirstPartial: distribution { $0.streaming?.timeToFirstPartial },
            firstPartialAfterSpeechStart: distribution { $0.streaming?.firstPartialAfterSpeechStart },
            timeToFirstStable: distribution { $0.streaming?.timeToFirstStable },
            timeToFinal: distribution { $0.streaming?.timeToFinal },
            endOfAudioToFinal: distribution { $0.streaming?.endOfAudioToFinal },
            endOfSpeechToFinal: distribution { $0.streaming?.endOfSpeechToFinal },
            peakMemoryBytes: distribution { $0.resources?.peakMemoryBytes.map { Double($0) } },
            averageCPUPercent: distribution { $0.resources?.averageCPUPercent }
        )
    }
}
