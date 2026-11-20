import XCTest
@testable import NodCore

final class UtteranceEndpointerTests: XCTestCase {
    private let frame = 0.02

    /// Feeds `seconds` of audio at one level and returns the events with the time they came at.
    private func feed(_ endpointer: inout UtteranceEndpointer, level: Float, seconds: Double, outputLevel: Float? = nil, voice: Bool? = nil) -> [(UtteranceEndpointer.Event, Double)] {
        var events: [(UtteranceEndpointer.Event, Double)] = []
        var elapsed = 0.0
        while elapsed < seconds - 1e-9 {
            elapsed += frame
            if let event = endpointer.process(level: level, duration: frame, outputLevel: outputLevel, voice: voice) {
                events.append((event, elapsed))
            }
        }
        return events
    }

    func testSpeechStartsAfterAShortRunAndEndsAfterSilence() {
        var endpointer = UtteranceEndpointer()
        XCTAssertTrue(feed(&endpointer, level: -60, seconds: 1).isEmpty)

        let start = feed(&endpointer, level: -25, seconds: 1)
        XCTAssertEqual(start.map(\.0), [.started])
        XCTAssertEqual(start[0].1, 0.2, accuracy: 0.03)
        XCTAssertTrue(endpointer.isSpeaking)

        let end = feed(&endpointer, level: -60, seconds: 1.5)
        XCTAssertEqual(end.map(\.0), [.ended])
        XCTAssertEqual(end[0].1, 0.8, accuracy: 0.03)
        XCTAssertFalse(endpointer.isSpeaking)
    }

    func testAPauseBetweenWordsDoesNotEndTheUtterance() {
        var endpointer = UtteranceEndpointer()
        _ = feed(&endpointer, level: -60, seconds: 0.5)
        _ = feed(&endpointer, level: -25, seconds: 0.6)
        XCTAssertTrue(feed(&endpointer, level: -60, seconds: 0.5).isEmpty, "half a second of quiet is a pause, not the end")
        XCTAssertTrue(feed(&endpointer, level: -25, seconds: 0.5).isEmpty)
        XCTAssertTrue(endpointer.isSpeaking)
    }

    func testAShortNoiseDoesNotStartAnUtterance() {
        var endpointer = UtteranceEndpointer()
        _ = feed(&endpointer, level: -60, seconds: 0.5)
        XCTAssertTrue(feed(&endpointer, level: -20, seconds: 0.1).isEmpty)
        XCTAssertTrue(feed(&endpointer, level: -60, seconds: 0.5).isEmpty)
        XCTAssertFalse(endpointer.isSpeaking)
    }

    func testANoisyRoomRaisesTheBar() {
        var endpointer = UtteranceEndpointer()
        XCTAssertTrue(feed(&endpointer, level: -35, seconds: 2).isEmpty, "the room is measured first, so its noise starts nothing")
        XCTAssertEqual(endpointer.noiseFloor, -35, accuracy: 0.5)
        XCTAssertTrue(feed(&endpointer, level: -30, seconds: 1).isEmpty, "5 dB above the room is not speech")
        XCTAssertEqual(feed(&endpointer, level: -15, seconds: 1).map(\.0), [.started])
    }

    func testTheRoomEstimateDropsAtOnceAndRisesSlowly() {
        var endpointer = UtteranceEndpointer()
        _ = feed(&endpointer, level: -40, seconds: 1)
        _ = feed(&endpointer, level: -65, seconds: 0.1)
        XCTAssertEqual(endpointer.noiseFloor, -65, accuracy: 0.5, "a quieter room is believed immediately")

        // A fan starts: taken for speech at first, taken for the room after a while.
        let events = feed(&endpointer, level: -40, seconds: 12)
        XCTAssertEqual(events.map(\.0), [.started, .ended])
        XCTAssertFalse(endpointer.isSpeaking)
        XCTAssertTrue(feed(&endpointer, level: -40, seconds: 5).isEmpty, "and it stays the room")
    }

    func testSpeechWithPausesKeepsTheRoomEstimateDown() {
        var endpointer = UtteranceEndpointer()
        _ = feed(&endpointer, level: -60, seconds: 1)
        var events: [UtteranceEndpointer.Event] = []
        // Twenty seconds of talking: words with short gaps in between.
        for _ in 0..<25 {
            events += feed(&endpointer, level: -25, seconds: 0.6).map(\.0)
            events += feed(&endpointer, level: -60, seconds: 0.2).map(\.0)
        }
        XCTAssertEqual(events, [.started], "one utterance, not cut short")
        XCTAssertLessThan(endpointer.noiseFloor, -55)
    }

    func testQuietSoundsNeverCountAsSpeech() {
        var endpointer = UtteranceEndpointer(initialNoiseFloor: -90)
        XCTAssertTrue(feed(&endpointer, level: -50, seconds: 0.5).isEmpty, "below the minimum level")
    }

    // MARK: While the app itself is speaking

    /// A quiet room in which the app has spoken long enough for its echo to be measured:
    /// played at -20, its voice arrives at the microphone at -45.
    private func listenerThatKnowsItsEcho() -> UtteranceEndpointer {
        var endpointer = UtteranceEndpointer()
        _ = feed(&endpointer, level: -60, seconds: 1)
        _ = feed(&endpointer, level: -45, seconds: 0.5, outputLevel: -20)
        XCTAssertEqual(endpointer.echoCoupling ?? 0, -25, accuracy: 0.01)
        return endpointer
    }

    func testTheAppsOwnVoiceInTheMicrophoneIsNotTheUserTalking() {
        var endpointer = listenerThatKnowsItsEcho()
        // The echo wavers by a few decibels, as speech does.
        for level: Float in [-45, -41, -47, -40, -44] {
            XCTAssertTrue(feed(&endpointer, level: level, seconds: 1, outputLevel: -20).isEmpty)
        }
        // The user talks over it, clearly louder than the echo.
        let start = feed(&endpointer, level: -26, seconds: 1, outputLevel: -20)
        XCTAssertEqual(start.map(\.0), [.started])
        XCTAssertEqual(start[0].1, 0.4, accuracy: 0.03, "and it takes longer to be sure than in silence")
    }

    func testTheCutoffFollowsHowLoudTheAppPlays() {
        // Played louder, the echo is louder too: what would be speech in a quiet room is not.
        var loud = listenerThatKnowsItsEcho()
        XCTAssertTrue(feed(&loud, level: -32, seconds: 1, outputLevel: -10).isEmpty, "the echo of loud playback")
        XCTAssertEqual(feed(&loud, level: -18, seconds: 1, outputLevel: -10).map(\.0), [.started])

        // Played quietly, a quiet voice is enough again.
        var quiet = listenerThatKnowsItsEcho()
        XCTAssertEqual(feed(&quiet, level: -36, seconds: 1, outputLevel: -45).map(\.0), [.started])
    }

    func testTheAppsFirstWordsOnlyMeasureTheEcho() {
        var endpointer = UtteranceEndpointer()
        _ = feed(&endpointer, level: -60, seconds: 1)
        XCTAssertNil(endpointer.echoCoupling)
        // Loud from the first moment: without a measure this cannot be told from the user.
        XCTAssertTrue(feed(&endpointer, level: -22, seconds: 0.3, outputLevel: -15).isEmpty)
        XCTAssertEqual(endpointer.echoCoupling ?? 0, -7, accuracy: 0.01)
        XCTAssertTrue(feed(&endpointer, level: -22, seconds: 2, outputLevel: -15).isEmpty)
    }

    func testAnEchoThatWasMistakenForTheUserRaisesTheBar() {
        var endpointer = listenerThatKnowsItsEcho()
        var mistaken = endpointer
        XCTAssertEqual(feed(&mistaken, level: -33, seconds: 1, outputLevel: -20).map(\.0), [.started], "louder than the echo was thought to be")

        endpointer.raiseEchoEstimate(by: 6)
        XCTAssertTrue(feed(&endpointer, level: -33, seconds: 1, outputLevel: -20).isEmpty)
    }

    func testTheEchoMeasureComesDownSlowly() {
        var endpointer = listenerThatKnowsItsEcho()
        _ = feed(&endpointer, level: -70, seconds: 1, outputLevel: -20)
        XCTAssertEqual(endpointer.echoCoupling ?? 0, -26, accuracy: 0.1, "one decibel in a second, not all the way")
    }

    func testAVoiceThatStartsUpGraduallyIsNotTakenForALouderEcho() {
        var endpointer = listenerThatKnowsItsEcho()
        // The user's voice rises through the echo's level over a tenth of a second.
        var events: [UtteranceEndpointer.Event] = []
        for level: Float in [-44, -41, -38, -35, -32] {
            events += feed(&endpointer, level: level, seconds: 0.02, outputLevel: -20).map(\.0)
        }
        events += feed(&endpointer, level: -28, seconds: 0.6, outputLevel: -20).map(\.0)
        XCTAssertEqual(events, [.started])
        XCTAssertLessThan(endpointer.echoCoupling ?? 0, -23, "the measure of the echo did not chase the voice")
    }

    func testSpeechWithGapsBetweenSyllablesStillAddsUp() {
        var endpointer = UtteranceEndpointer(initialNoiseFloor: -60)
        var events: [UtteranceEndpointer.Event] = []
        // Bursts of 0.14 s with gaps of 0.14 s: never 0.2 s in one piece.
        for _ in 0..<6 {
            events += feed(&endpointer, level: -25, seconds: 0.14).map(\.0)
            events += feed(&endpointer, level: -60, seconds: 0.14).map(\.0)
        }
        XCTAssertEqual(events, [.started])
    }

    func testWithInterruptingSwitchedOffNothingStartsWhileTheAppTalks() {
        var endpointer = UtteranceEndpointer(settings: .init(interruptWhileOutputPlays: false))
        _ = feed(&endpointer, level: -60, seconds: 1)
        XCTAssertTrue(feed(&endpointer, level: -10, seconds: 3, outputLevel: -20).isEmpty)
        XCTAssertEqual(feed(&endpointer, level: -30, seconds: 1).map(\.0), [.started], "once the app is silent the user is heard")
    }

    // MARK: Speech and other sound

    func testLoudSoundThatIsNotAVoiceIsNotSpeech() {
        var endpointer = UtteranceEndpointer()
        _ = feed(&endpointer, level: -60, seconds: 1, voice: false)
        XCTAssertTrue(feed(&endpointer, level: -15, seconds: 2, voice: false).isEmpty, "a door, a keyboard, a passing car")
        XCTAssertEqual(feed(&endpointer, level: -25, seconds: 1, voice: true).map(\.0), [.started])
    }

    func testAnUtteranceEndsWhenTheVoiceDoesEvenIfTheNoiseGoesOn() {
        var endpointer = UtteranceEndpointer(initialNoiseFloor: -60)
        XCTAssertEqual(feed(&endpointer, level: -25, seconds: 1, voice: true).map(\.0), [.started])
        let end = feed(&endpointer, level: -25, seconds: 2, voice: false)
        XCTAssertEqual(end.map(\.0), [.ended])
        XCTAssertEqual(end[0].1, 0.8, accuracy: 0.03)
    }

    func testAVoiceThatIsTooQuietIsStillNotSpeech() {
        var endpointer = UtteranceEndpointer(initialNoiseFloor: -90)
        XCTAssertTrue(feed(&endpointer, level: -50, seconds: 1, voice: true).isEmpty, "someone talking in the next room")
    }

    func testAVeryLongUtteranceIsCutOff() {
        var endpointer = UtteranceEndpointer(settings: .init(maximumUtterance: 3))
        _ = feed(&endpointer, level: -60, seconds: 0.5)
        let events = feed(&endpointer, level: -20, seconds: 5)
        XCTAssertEqual(events.map(\.0).prefix(2), [.started, .ended])
        XCTAssertEqual(events[1].1, 3, accuracy: 0.1)
    }

    func testLevelOfSamples() {
        let silence = [Float](repeating: 0, count: 160)
        let full = [Float](repeating: 1, count: 160)
        let half = [Float](repeating: 0.5, count: 160)
        silence.withUnsafeBufferPointer { XCTAssertEqual(UtteranceEndpointer.level(of: $0), -120) }
        full.withUnsafeBufferPointer { XCTAssertEqual(UtteranceEndpointer.level(of: $0), 0, accuracy: 0.001) }
        half.withUnsafeBufferPointer { XCTAssertEqual(UtteranceEndpointer.level(of: $0), -6.02, accuracy: 0.01) }
    }
}
