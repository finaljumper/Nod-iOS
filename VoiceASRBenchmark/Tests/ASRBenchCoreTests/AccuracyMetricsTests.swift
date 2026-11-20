import XCTest
@testable import ASRBenchCore

final class TextNormalizationTests: XCTestCase {
    func testConservativeKeepsCaseAndPunctuation() {
        XCTAssertEqual(TextNormalizer.normalize("  Hello,   World!\n", mode: .conservative), "Hello, World!")
    }

    func testRelaxedLowercasesAndStripsPunctuation() {
        XCTAssertEqual(TextNormalizer.normalize("Hello, World! — It's 3.5 km; twenty-one.", mode: .relaxed), "hello world it's 3.5 km twenty one")
    }

    func testRelaxedKeepsTimesAndDropsSentencePunctuationAfterDigits() {
        XCTAssertEqual(TextNormalizer.normalize("Meet at 10:30, room 4.", mode: .relaxed), "meet at 10:30 room 4")
    }

    func testRelaxedApostrophes() {
        XCTAssertEqual(TextNormalizer.normalize("Don’t 'quote' me", mode: .relaxed), "don't quote me")
    }

    func testCyrillicLowercasingAndYoFolding() {
        XCTAssertEqual(TextNormalizer.normalize("Ёлка, ПРИВЕТ!", mode: .relaxed), "елка привет")
        // Conservative keeps ё and case.
        XCTAssertEqual(TextNormalizer.normalize("Ёлка", mode: .conservative), "Ёлка")
    }

    func testHangulIsPreserved() {
        let text = "안녕하세요, 서울에서 만나요!"
        XCTAssertEqual(TextNormalizer.normalize(text, mode: .relaxed), "안녕하세요 서울에서 만나요")
        XCTAssertEqual(TextNormalizer.words(text, mode: .relaxed).count, 3)
    }

    func testDecomposedHangulComposesToTheSameSyllables() {
        let composed = "한국어"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))
        for mode in NormalizationMode.allCases {
            XCTAssertEqual(
                Array(TextNormalizer.normalize(decomposed, mode: mode).unicodeScalars),
                Array(composed.unicodeScalars)
            )
        }
    }

    func testCharactersCountHangulSyllablesAndSkipWhitespace() {
        XCTAssertEqual(TextNormalizer.characters("한국어 좋아", mode: .conservative).count, 5)
    }

    func testFullWidthFormsFoldOnlyInRelaxedMode() {
        XCTAssertEqual(TextNormalizer.normalize("ＡＢＣ１２３", mode: .relaxed), "abc123")
        XCTAssertEqual(TextNormalizer.normalize("ＡＢＣ", mode: .conservative), "ＡＢＣ")
    }

    func testNumbersAreNotRewritten() {
        XCTAssertNotEqual(TextNormalizer.normalize("3", mode: .relaxed), TextNormalizer.normalize("three", mode: .relaxed))
    }

    func testEmptyAndPunctuationOnly() {
        XCTAssertEqual(TextNormalizer.words("", mode: .relaxed), [])
        XCTAssertEqual(TextNormalizer.words("?! ...", mode: .relaxed), [])
    }
}

final class AccuracyMetricsTests: XCTestCase {
    func testIdenticalTextHasNoErrors() {
        let score = AccuracyMetrics.score(reference: "turn on the lights", hypothesis: "turn on the lights", mode: .conservative)
        XCTAssertEqual(score.wer, 0)
        XCTAssertEqual(score.cer, 0)
        XCTAssertEqual(score.words, EditCounts(hits: 4))
    }

    func testSubstitutionDeletionInsertionCounts() {
        // ref: the quick brown fox      hyp: the quack fox jumps
        let alignment = EditDistance.align(
            reference: ["the", "quick", "brown", "fox"],
            hypothesis: ["the", "quack", "fox", "jumps"]
        )
        XCTAssertEqual(alignment.counts, EditCounts(substitutions: 1, deletions: 1, insertions: 1, hits: 2))
        XCTAssertEqual(alignment.counts.errorRate, 0.75)
        // "fox" is kept as a hit instead of being folded into three substitutions. Which of
        // "quick" and "brown" is the deletion is a tie; the result is deterministic.
        XCTAssertEqual(alignment.operations, [
            .match(reference: 0, hypothesis: 0),
            .deletion(reference: 1),
            .substitution(reference: 2, hypothesis: 1),
            .match(reference: 3, hypothesis: 2),
            .insertion(hypothesis: 3),
        ])
    }

    func testAlignmentPrefersTheMostExactMatches() {
        // Cost 3 either way: three substitutions (one hit) or sub + del + ins (two hits).
        let counts = EditDistance.align(reference: ["a", "b", "c", "d"], hypothesis: ["a", "x", "d", "e"]).counts
        XCTAssertEqual(counts.errors, 3)
        XCTAssertEqual(counts.hits, 2)
    }

    func testEmptyHypothesisIsAllDeletions() {
        let counts = EditDistance.align(reference: ["a", "b", "c"], hypothesis: [String]()).counts
        XCTAssertEqual(counts, EditCounts(deletions: 3))
        XCTAssertEqual(counts.errorRate, 1)
    }

    func testEmptyReference() {
        XCTAssertEqual(EditDistance.align(reference: [String](), hypothesis: [String]()).counts.errorRate, 0)
        let counts = EditDistance.align(reference: [String](), hypothesis: ["a", "b"]).counts
        XCTAssertEqual(counts, EditCounts(insertions: 2))
        XCTAssertEqual(counts.errorRate, 1)
    }

    func testErrorRateCanExceedOne() {
        let counts = EditDistance.align(reference: ["yes"], hypothesis: ["oh", "no", "not", "that"]).counts
        XCTAssertEqual(counts.errors, 4)
        XCTAssertEqual(counts.errorRate, 4)
    }

    func testEditDistanceMatchesKnownValue() {
        let counts = EditDistance.align(reference: Array("kitten"), hypothesis: Array("sitting")).counts
        XCTAssertEqual(counts.errors, 3)
    }

    func testConservativeAndRelaxedDiffer() {
        let accuracy = AccuracyMetrics.evaluate(reference: "Hello, world.", hypothesis: "hello world")
        XCTAssertEqual(accuracy.conservative.wer, 1)
        XCTAssertEqual(accuracy.relaxed.wer, 0)
        XCTAssertTrue(accuracy.exactMatch)
    }

    func testKoreanCharacterErrorRate() {
        // One syllable of six is wrong; spacing differs but is not counted.
        let score = AccuracyMetrics.score(reference: "오늘 날씨 어때", hypothesis: "오늘날씨 어대", mode: .relaxed)
        XCTAssertEqual(score.characters, EditCounts(substitutions: 1, hits: 5))
        XCTAssertEqual(score.cer, 1.0 / 6.0, accuracy: 1e-12)
        // Word level sees the spacing difference.
        XCTAssertGreaterThan(score.wer, score.cer)
    }

    func testRussianWordErrorRate() {
        let score = AccuracyMetrics.score(reference: "Поставь будильник на семь утра", hypothesis: "поставь будильник на семь", mode: .relaxed)
        XCTAssertEqual(score.words, EditCounts(deletions: 1, hits: 4))
        XCTAssertEqual(score.wer, 0.2, accuracy: 1e-12)
    }

    func testScriptBreakdownShowsWhichLanguageWasLost() {
        // The Russian half is dropped, the English half is intact.
        let accuracy = AccuracyMetrics.evaluate(
            reference: "Send the report завтра утром",
            hypothesis: "send the report"
        )
        XCTAssertEqual(accuracy.byScript["latin"], EditCounts(hits: 3))
        XCTAssertEqual(accuracy.byScript["cyrillic"], EditCounts(deletions: 2))
        XCTAssertNil(accuracy.byScript["hangul"])
    }

    func testScriptDetection() {
        XCTAssertEqual(Script.of("hello"), .latin)
        XCTAssertEqual(Script.of("привет"), .cyrillic)
        XCTAssertEqual(Script.of("안녕"), .hangul)
        XCTAssertEqual(Script.of("2026"), .number)
        XCTAssertEqual(Script.of("café"), .latin)
    }

    func testKeyTermRecall() {
        let score = AccuracyMetrics.keyTermScore(
            terms: ["Seoul", "March 3rd", "Dmitri"],
            hypothesis: "I'm flying to Seoul on march 3rd with Dimitri."
        )
        XCTAssertEqual(score.total, 3)
        XCTAssertEqual(score.matched, 2)
        XCTAssertEqual(score.missed, ["Dmitri"])
    }

    func testKeyTermDoesNotMatchInsideALongerLatinWord() {
        let score = AccuracyMetrics.keyTermScore(terms: ["Al"], hypothesis: "also call me")
        XCTAssertEqual(score.matched, 0)
    }

    func testKoreanKeyTermMatchesWithAttachedParticle() {
        let score = AccuracyMetrics.keyTermScore(terms: ["서울"], hypothesis: "내일 서울에서 만나요")
        XCTAssertEqual(score.matched, 1)
    }

    func testEvaluateOmitsKeyTermsWhenNoneGiven() {
        XCTAssertNil(AccuracyMetrics.evaluate(reference: "a", hypothesis: "a").keyTerms)
        XCTAssertNotNil(AccuracyMetrics.evaluate(reference: "a b", hypothesis: "a", keyTerms: ["b"]).keyTerms)
    }

    func testEditCountsAddition() {
        var total = EditCounts(substitutions: 1, deletions: 2, insertions: 3, hits: 4)
        total += EditCounts(substitutions: 1, hits: 1)
        XCTAssertEqual(total, EditCounts(substitutions: 2, deletions: 2, insertions: 3, hits: 5))
        XCTAssertEqual(total.referenceLength, 9)
    }
}
