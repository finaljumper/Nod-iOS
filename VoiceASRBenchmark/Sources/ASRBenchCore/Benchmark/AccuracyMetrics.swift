import Foundation

// MARK: - Text normalization

/// How transcripts are normalized before they are compared.
public enum NormalizationMode: String, Codable, Sendable, CaseIterable {
    /// Unicode NFC and whitespace cleanup only. Case, punctuation, digits and spelling are
    /// compared exactly as written. This is the strict score: an engine is penalized for a
    /// missing comma or a different capitalization.
    case conservative
    /// Case- and punctuation-insensitive comparison, see `TextNormalizer`.
    case relaxed
}

/// Unicode-aware transcript normalization.
///
/// **Conservative** applies, in order:
/// 1. Unicode NFC, so that decomposed Hangul jamo and combining marks compare equal to their
///    precomposed forms.
/// 2. Every run of Unicode whitespace becomes one space; leading and trailing space is removed.
///
/// **Relaxed** applies, in order:
/// 1. Unicode NFKC (also folds full-width forms and compatibility characters).
/// 2. Locale-independent lowercasing. Hangul has no case and is unaffected.
/// 3. Cyrillic `ё` becomes `е`, because Russian text commonly writes either.
/// 4. Typographic apostrophes become `'`. An apostrophe is kept only between two letters
///    (`don't`), and `.`, `,` and `:` are kept only between two digits (`3.5`, `10:30`).
/// 5. All other punctuation and symbols become a space, so `twenty-one` compares as two words.
/// 6. Whitespace cleanup as above.
///
/// Neither mode rewrites numbers (`3` versus `three`, `3` versus `три`, `3` versus `셋`),
/// transliterates between scripts, or strips diacritics. Those differences count as errors, so
/// reference transcripts should follow one written convention.
public enum TextNormalizer {
    public static func normalize(_ text: String, mode: NormalizationMode) -> String {
        switch mode {
        case .conservative:
            return collapseWhitespace(text.precomposedStringWithCanonicalMapping)
        case .relaxed:
            return relaxed(text)
        }
    }

    /// Whitespace-separated tokens of the normalized text. The unit of WER.
    public static func words(_ text: String, mode: NormalizationMode) -> [String] {
        normalize(text, mode: mode).split(separator: " ").map(String.init)
    }

    /// Characters (extended grapheme clusters) of the normalized text with whitespace removed.
    /// The unit of CER. One Hangul syllable is one character. Whitespace is excluded so that
    /// Korean spacing variants, which are common and often both acceptable, do not count as errors.
    public static func characters(_ text: String, mode: NormalizationMode) -> [Character] {
        normalize(text, mode: mode).filter { !$0.isWhitespace }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    private static func relaxed(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let scalars = Array(folded.unicodeScalars)
        var output = String.UnicodeScalarView()
        let space: Unicode.Scalar = " "

        func isLetter(_ index: Int) -> Bool {
            guard scalars.indices.contains(index) else { return false }
            return isLetterCategory(scalars[index].properties.generalCategory)
        }
        func isDigit(_ index: Int) -> Bool {
            guard scalars.indices.contains(index) else { return false }
            return scalars[index].properties.generalCategory == .decimalNumber
        }

        for (index, original) in scalars.enumerated() {
            var scalar = original
            if scalar == "\u{0451}" { scalar = "\u{0435}" }                       // ё → е
            if scalar == "\u{2019}" || scalar == "\u{02BC}" || scalar == "\u{2018}" { scalar = "'" }

            let category = scalar.properties.generalCategory
            if isLetterCategory(category) || isMarkCategory(category) || isNumberCategory(category) {
                output.append(scalar)
            } else if scalar == "'" {
                output.append(isLetter(index - 1) && isLetter(index + 1) ? scalar : space)
            } else if scalar == "." || scalar == "," || scalar == ":" {
                output.append(isDigit(index - 1) && isDigit(index + 1) ? scalar : space)
            } else {
                output.append(space)
            }
        }
        return collapseWhitespace(String(output).precomposedStringWithCanonicalMapping)
    }

    private static func isLetterCategory(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func isMarkCategory(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isNumberCategory(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }
}

// MARK: - Edit distance

/// Counts from a Levenshtein alignment of a hypothesis against a reference.
public struct EditCounts: Codable, Sendable, Equatable {
    /// Reference units replaced by a different unit.
    public var substitutions: Int
    /// Reference units missing from the hypothesis.
    public var deletions: Int
    /// Hypothesis units with no counterpart in the reference.
    public var insertions: Int
    /// Reference units recognized correctly.
    public var hits: Int

    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, hits: Int = 0) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.hits = hits
    }

    public var referenceLength: Int { hits + substitutions + deletions }
    public var errors: Int { substitutions + deletions + insertions }

    /// `(S + D + I) / N`. Can exceed 1 when there are many insertions. For an empty reference
    /// the rate is 0 if the hypothesis is empty too, otherwise 1.
    public var errorRate: Double {
        if referenceLength == 0 { return insertions == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceLength)
    }

    public static func + (lhs: EditCounts, rhs: EditCounts) -> EditCounts {
        EditCounts(
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions,
            hits: lhs.hits + rhs.hits
        )
    }

    public static func += (lhs: inout EditCounts, rhs: EditCounts) { lhs = lhs + rhs }
}

/// One step of an alignment. Indices refer to the reference and hypothesis arrays.
public enum EditOperation: Sendable, Equatable {
    case match(reference: Int, hypothesis: Int)
    case substitution(reference: Int, hypothesis: Int)
    case deletion(reference: Int)
    case insertion(hypothesis: Int)
}

public struct Alignment: Sendable, Equatable {
    public var counts: EditCounts
    public var operations: [EditOperation]
}

public enum EditDistance {
    /// Minimum edit distance alignment with unit costs.
    ///
    /// Several alignments usually share the minimum cost, and they split the errors differently
    /// between substitutions, deletions and insertions. Among them this picks one with the most
    /// exact matches, so a correctly recognized unit is reported as a hit rather than folded
    /// into a chain of substitutions. Remaining ties prefer match or substitution, then
    /// deletion, then insertion.
    public static func align<T: Equatable>(reference: [T], hypothesis: [T]) -> Alignment {
        let n = reference.count
        let m = hypothesis.count
        let width = m + 1
        var cost = [Int32](repeating: 0, count: (n + 1) * width)
        var hits = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 0...n { cost[i * width] = Int32(i) }
        for j in 0...m { cost[j] = Int32(j) }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let same = reference[i - 1] == hypothesis[j - 1]
                    var bestCost = cost[(i - 1) * width + j - 1] + (same ? 0 : 1)
                    var bestHits = hits[(i - 1) * width + j - 1] + (same ? 1 : 0)
                    let deletionCost = cost[(i - 1) * width + j] + 1
                    let deletionHits = hits[(i - 1) * width + j]
                    if deletionCost < bestCost || (deletionCost == bestCost && deletionHits > bestHits) {
                        bestCost = deletionCost
                        bestHits = deletionHits
                    }
                    let insertionCost = cost[i * width + j - 1] + 1
                    let insertionHits = hits[i * width + j - 1]
                    if insertionCost < bestCost || (insertionCost == bestCost && insertionHits > bestHits) {
                        bestCost = insertionCost
                        bestHits = insertionHits
                    }
                    cost[i * width + j] = bestCost
                    hits[i * width + j] = bestHits
                }
            }
        }

        var operations: [EditOperation] = []
        operations.reserveCapacity(max(n, m))
        var counts = EditCounts()
        var i = n, j = m
        while i > 0 || j > 0 {
            let hereCost = cost[i * width + j]
            let hereHits = hits[i * width + j]
            if i > 0, j > 0 {
                let same = reference[i - 1] == hypothesis[j - 1]
                let previous = (i - 1) * width + j - 1
                if hereCost == cost[previous] + (same ? 0 : 1), hereHits == hits[previous] + (same ? 1 : 0) {
                    if same {
                        operations.append(.match(reference: i - 1, hypothesis: j - 1))
                        counts.hits += 1
                    } else {
                        operations.append(.substitution(reference: i - 1, hypothesis: j - 1))
                        counts.substitutions += 1
                    }
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, hereCost == cost[(i - 1) * width + j] + 1, hereHits == hits[(i - 1) * width + j] {
                operations.append(.deletion(reference: i - 1))
                counts.deletions += 1
                i -= 1
            } else {
                operations.append(.insertion(hypothesis: j - 1))
                counts.insertions += 1
                j -= 1
            }
        }
        operations.reverse()
        return Alignment(counts: counts, operations: operations)
    }
}

// MARK: - Scores

/// WER and CER of one hypothesis under one normalization mode.
public struct AccuracyScore: Codable, Sendable, Equatable {
    public var mode: NormalizationMode
    /// Word error rate: word-level `(S + D + I) / N`.
    public var wer: Double
    /// Character error rate: character-level `(S + D + I) / N`, whitespace excluded.
    public var cer: Double
    public var words: EditCounts
    public var characters: EditCounts
    public var normalizedReference: String
    public var normalizedHypothesis: String
}

/// How many of a recording's key terms appear in the hypothesis.
public struct KeyTermScore: Codable, Sendable, Equatable {
    public var total: Int
    public var matched: Int
    public var missed: [String]

    public var recall: Double { total == 0 ? 1 : Double(matched) / Double(total) }
}

/// Writing systems that tell the benchmark's languages apart.
public enum Script: String, Codable, Sendable, CaseIterable {
    case latin, cyrillic, hangul, han, kana, number, other

    /// The script most letters of `token` belong to.
    public static func of(_ token: String) -> Script {
        var counts: [Script: Int] = [:]
        for scalar in token.unicodeScalars {
            let value = scalar.value
            let script: Script?
            switch value {
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF: script = .latin
            case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: script = .cyrillic
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF: script = .hangul
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: script = .han
            case 0x3040...0x30FF: script = .kana
            default:
                script = scalar.properties.generalCategory == .decimalNumber ? .number : nil
            }
            if let script { counts[script, default: 0] += 1 }
        }
        // Ties resolve in declaration order so the result is deterministic.
        var best: Script = .other
        var bestCount = 0
        for script in Script.allCases {
            if let count = counts[script], count > bestCount {
                best = script
                bestCount = count
            }
        }
        return best
    }
}

/// All accuracy measurements of one hypothesis against its reference.
public struct RecordingAccuracy: Codable, Sendable, Equatable {
    public var conservative: AccuracyScore
    public var relaxed: AccuracyScore
    /// Recall of the recording's `keyTerms` (proper nouns, dates, numbers), when it has any.
    public var keyTerms: KeyTermScore?
    /// Whether the relaxed-normalized hypothesis equals the reference exactly. For short commands
    /// this is the command accuracy: a command either came through intact or it did not.
    public var exactMatch: Bool
    /// Relaxed word-level outcomes grouped by the script of the word (script name → counts).
    /// For code-switched recordings this shows which language's words an engine lost.
    /// Substitutions and deletions are attributed to the reference word's script, insertions to
    /// the inserted word's script.
    public var byScript: [String: EditCounts]

    public func score(_ mode: NormalizationMode) -> AccuracyScore {
        mode == .conservative ? conservative : relaxed
    }
}

public enum AccuracyMetrics {
    public static func score(reference: String, hypothesis: String, mode: NormalizationMode) -> AccuracyScore {
        let referenceWords = TextNormalizer.words(reference, mode: mode)
        let hypothesisWords = TextNormalizer.words(hypothesis, mode: mode)
        let words = EditDistance.align(reference: referenceWords, hypothesis: hypothesisWords).counts
        let characters = EditDistance.align(
            reference: TextNormalizer.characters(reference, mode: mode),
            hypothesis: TextNormalizer.characters(hypothesis, mode: mode)
        ).counts
        return AccuracyScore(
            mode: mode,
            wer: words.errorRate,
            cer: characters.errorRate,
            words: words,
            characters: characters,
            normalizedReference: referenceWords.joined(separator: " "),
            normalizedHypothesis: hypothesisWords.joined(separator: " ")
        )
    }

    public static func evaluate(reference: String, hypothesis: String, keyTerms: [String]? = nil) -> RecordingAccuracy {
        let conservative = score(reference: reference, hypothesis: hypothesis, mode: .conservative)
        let relaxed = score(reference: reference, hypothesis: hypothesis, mode: .relaxed)

        let referenceWords = TextNormalizer.words(reference, mode: .relaxed)
        let hypothesisWords = TextNormalizer.words(hypothesis, mode: .relaxed)
        let alignment = EditDistance.align(reference: referenceWords, hypothesis: hypothesisWords)
        var byScript: [String: EditCounts] = [:]
        for operation in alignment.operations {
            switch operation {
            case .match(let r, _):
                byScript[Script.of(referenceWords[r]).rawValue, default: EditCounts()].hits += 1
            case .substitution(let r, _):
                byScript[Script.of(referenceWords[r]).rawValue, default: EditCounts()].substitutions += 1
            case .deletion(let r):
                byScript[Script.of(referenceWords[r]).rawValue, default: EditCounts()].deletions += 1
            case .insertion(let h):
                byScript[Script.of(hypothesisWords[h]).rawValue, default: EditCounts()].insertions += 1
            }
        }

        let terms = (keyTerms ?? []).filter { !TextNormalizer.words($0, mode: .relaxed).isEmpty }
        return RecordingAccuracy(
            conservative: conservative,
            relaxed: relaxed,
            keyTerms: terms.isEmpty ? nil : keyTermScore(terms: terms, hypothesis: hypothesis),
            exactMatch: referenceWords == hypothesisWords,
            byScript: byScript
        )
    }

    /// A key term counts as recognized when its relaxed-normalized words appear in the hypothesis
    /// as a contiguous word sequence. Terms containing Hangul also match as a substring of the
    /// hypothesis with spaces removed, because Korean attaches particles to nouns
    /// (`서울` inside `서울에서`).
    public static func keyTermScore(terms: [String], hypothesis: String) -> KeyTermScore {
        let hypothesisWords = TextNormalizer.words(hypothesis, mode: .relaxed)
        let hypothesisJoined = hypothesisWords.joined()
        var missed: [String] = []
        for term in terms {
            let termWords = TextNormalizer.words(term, mode: .relaxed)
            var found = containsSequence(hypothesisWords, termWords)
            if !found, Script.of(termWords.joined()) == .hangul {
                found = hypothesisJoined.contains(termWords.joined())
            }
            if !found { missed.append(term) }
        }
        return KeyTermScore(total: terms.count, matched: terms.count - missed.count, missed: missed)
    }

    private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
