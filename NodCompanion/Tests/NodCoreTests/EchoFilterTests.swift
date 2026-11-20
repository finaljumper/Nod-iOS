import XCTest
@testable import NodCore

final class EchoFilterTests: XCTestCase {
    private let spoken = "You have two things today. Stand-up at 10:00 and lunch with Dmitri at 12:30."

    func testTheAppsOwnWordsAreAnEcho() {
        XCTAssertTrue(EchoFilter.isEcho(heard: "you have two things today", spoken: spoken))
        XCTAssertTrue(EchoFilter.isEcho(heard: "Lunch with Dmitri", spoken: spoken))
    }

    func testAnEchoThatWasHeardBadlyIsStillAnEcho() {
        XCTAssertTrue(EchoFilter.isEcho(heard: "have two thing today stand up", spoken: spoken))
    }

    func testWhatTheUserSaysIsNotAnEcho() {
        XCTAssertFalse(EchoFilter.isEcho(heard: "stop", spoken: spoken))
        XCTAssertFalse(EchoFilter.isEcho(heard: "wait, what about tomorrow?", spoken: spoken))
        XCTAssertFalse(EchoFilter.isEcho(heard: "move the lunch to one", spoken: spoken), "one shared word does not make an echo")
        XCTAssertFalse(EchoFilter.isEcho(heard: "yes send it", spoken: "Here is the draft. Shall I send it?"), "a short answer that repeats some of the question")
    }

    func testNoWordsAtAllIsNoiseAndTreatedLikeAnEcho() {
        XCTAssertTrue(EchoFilter.isEcho(heard: "", spoken: spoken))
        XCTAssertTrue(EchoFilter.isEcho(heard: " … ", spoken: spoken))
    }

    func testWithNothingSpokenNothingIsAnEcho() {
        XCTAssertFalse(EchoFilter.isEcho(heard: "hello", spoken: ""))
    }

    func testKoreanIsComparedWithoutRelyingOnSpaces() {
        let korean = "오늘은 회의가 두 개 있습니다. 열 시에 스탠드업이 있어요."
        XCTAssertTrue(EchoFilter.isEcho(heard: "오늘은 회의가 두개 있습니다", spoken: korean), "the recogniser spaced it differently")
        XCTAssertFalse(EchoFilter.isEcho(heard: "잠깐만요 내일은 어때요", spoken: korean))
    }

    func testWordsMustComeInTheOrderTheyWereSpoken() {
        XCTAssertFalse(EchoFilter.isEcho(heard: "today things two have you", spoken: spoken))
    }
}
