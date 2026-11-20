import XCTest
@testable import NodCore

final class SentenceChunkerTests: XCTestCase {
    func testSentencesAreReleasedAsSoonAsTheyAreComplete() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("You have two "), [])
        XCTAssertEqual(chunker.append("things today. Stand-up "), ["You have two things today."])
        XCTAssertEqual(chunker.append("at 10:00."), [], "a full stop at the very end may still be followed by more")
        XCTAssertEqual(chunker.flush(), "Stand-up at 10:00.")
        XCTAssertNil(chunker.flush())
    }

    func testNumbersAndTimesAreNotCutApart() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("It costs 3.50 and starts at 12.30 sharp. Then"), ["It costs 3.50 and starts at 12.30 sharp."])
        // The digit arrives in a later piece than the full stop before it.
        var split = SentenceChunker()
        XCTAssertEqual(split.append("Version 2."), [])
        XCTAssertEqual(split.append("5 is out. "), ["Version 2.5 is out."])
    }

    func testClosingQuotesAndRepeatedMarksStayWithTheirSentence() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("He said \"go.\" Really?! Yes… "), ["He said \"go.\"", "Really?!", "Yes…"])
    }

    func testLineBreaksAndWideFullStopsEndASentence() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("First item\nSecond item\n"), ["First item", "Second item"])
        XCTAssertEqual(chunker.append("오늘은 맑습니다。내일은"), ["오늘은 맑습니다。"])
    }

    func testResetDropsWhatWasBuffered() {
        var chunker = SentenceChunker()
        _ = chunker.append("Half a sentence")
        chunker.reset()
        XCTAssertNil(chunker.flush())
    }
}

final class LanguageSegmenterTests: XCTestCase {
    private func parts(_ text: String) -> [String] {
        LanguageSegmenter.segments(of: text).map { "\($0.language):\($0.text)" }
    }

    func testEachWritingSystemGetsItsOwnVoice() {
        XCTAssertEqual(parts("Hello there"), ["en:Hello there"])
        XCTAssertEqual(parts("Привет, как дела?"), ["ru:Привет, как дела?"])
        XCTAssertEqual(parts("오늘 일정은 두 개입니다."), ["ko:오늘 일정은 두 개입니다."])
    }

    func testMixedSentencesAreSplitWhereTheScriptChanges() {
        XCTAssertEqual(
            parts("Напомни мне про meeting с командой"),
            ["ru:Напомни мне про", "en:meeting", "ru:с командой"]
        )
        XCTAssertEqual(parts("Slack에 올려 줘"), ["en:Slack", "ko:에 올려 줘"])
        XCTAssertEqual(
            parts("Okay, давай так: 일정은 내일 확인하자."),
            ["en:Okay,", "ru:давай так:", "ko:일정은 내일 확인하자."]
        )
    }

    func testNumbersAreReadInTheLanguageAroundThem() {
        XCTAssertEqual(parts("Стендап в 10:00 и обед в 12:30."), ["ru:Стендап в 10:00 и обед в 12:30."])
        XCTAssertEqual(parts("10시에 스탠드업이 있습니다"), ["ko:10시에 스탠드업이 있습니다"])
        XCTAssertEqual(parts("12:30"), ["en:12:30"], "text without letters uses the fallback language")
    }

    func testPunctuationAloneIsNotSpoken() {
        XCTAssertEqual(parts("…"), [])
        XCTAssertEqual(parts("  "), [])
        XCTAssertEqual(parts("«привет»"), ["ru:«привет»"])
    }
}

final class SpeechTextSanitizerTests: XCTestCase {
    func testMarkdownMarksAreNotReadAloud() {
        XCTAssertEqual(SpeechTextSanitizer.clean("**Done.** The `mail.send` tool ran."), "Done. The mail.send tool ran.")
        XCTAssertEqual(SpeechTextSanitizer.clean("## Today"), "Today")
        XCTAssertEqual(SpeechTextSanitizer.clean("- Stand-up at 10:00"), "Stand-up at 10:00")
        XCTAssertEqual(SpeechTextSanitizer.clean("1. First"), "1. First", "numbered steps keep their number")
    }

    func testLinksAreSpokenAsTheirLabel() {
        XCTAssertEqual(SpeechTextSanitizer.clean("See [the booking](https://example.com/b?id=1) for details."), "See the booking for details.")
        XCTAssertEqual(SpeechTextSanitizer.clean("Open https://example.com/long/path now"), "Open now")
    }

    func testPlainTextAndHyphensAreLeftAlone() {
        XCTAssertEqual(SpeechTextSanitizer.clean("Stand-up at 10:00, lunch at 12:30."), "Stand-up at 10:00, lunch at 12:30.")
        XCTAssertEqual(SpeechTextSanitizer.clean("Это демо-ассистент."), "Это демо-ассистент.")
    }
}

final class RetryPolicyTests: XCTestCase {
    func testDelaysGrowAndStopAtTheCap() {
        let policy = RetryPolicy(base: 1, factor: 2, cap: 10, maxRetries: nil)
        XCTAssertEqual((1...6).map { policy.delay(beforeRetry: $0) }, [1, 2, 4, 8, 10, 10])
    }

    func testTheLimitEndsRetrying() {
        let policy = RetryPolicy(base: 1, factor: 2, cap: 30, maxRetries: 2)
        XCTAssertEqual(policy.delay(beforeRetry: 2), 2)
        XCTAssertNil(policy.delay(beforeRetry: 3))
    }
}
