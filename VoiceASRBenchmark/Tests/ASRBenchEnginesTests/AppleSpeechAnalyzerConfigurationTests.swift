import XCTest
@testable import ASRBenchEngines

final class AppleSpeechAnalyzerConfigurationTests: XCTestCase {
    func testEngineIdentifiersAreDistinctPerModuleAndStable() {
        // Exported results are keyed by these identifiers; changing one breaks comparisons
        // with earlier runs.
        XCTAssertEqual(AppleSpeechAnalyzerConfiguration().engineID, "apple-speechanalyzer")
        XCTAssertEqual(AppleSpeechAnalyzerConfiguration(fastResults: true).engineID, "apple-speechanalyzer/fast-results")
        XCTAssertEqual(AppleSpeechAnalyzerConfiguration(module: .dictationTranscriber).engineID, "apple-dictationtranscriber")
    }

    func testFastResultsAppliesToSpeechTranscriberOnly() {
        let dictation = AppleSpeechAnalyzerConfiguration(module: .dictationTranscriber, fastResults: true)
        XCTAssertFalse(dictation.usesFastResults)
        XCTAssertEqual(dictation.engineID, "apple-dictationtranscriber", "the ignored option must not create a second engine")
        XCTAssertTrue(AppleSpeechAnalyzerConfiguration(fastResults: true).usesFastResults)
    }

    func testDescriptorNamesTheModule() async {
        let speech = await AppleSpeechAnalyzerEngine().descriptor()
        let dictation = await AppleSpeechAnalyzerEngine(configuration: .init(module: .dictationTranscriber)).descriptor()
        XCTAssertEqual(speech.configuration["module"], "SpeechTranscriber")
        XCTAssertEqual(dictation.configuration["module"], "DictationTranscriber")
        XCTAssertEqual(dictation.id, "apple-dictationtranscriber")
        XCTAssertNotEqual(speech.displayName, dictation.displayName)
        XCTAssertEqual(dictation.configuration["transcriptionOptions"], "punctuation")
    }
}
