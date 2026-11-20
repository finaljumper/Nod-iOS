import XCTest
@testable import ASRBenchEngines

final class WhisperKitModelCatalogTests: XCTestCase {
    /// Regression: the absolute container path was stored, so a downloaded model looked missing
    /// after every reinstall, when the container moves.
    func testModelFolderSurvivesAContainerMove() {
        let oldHome = "/var/mobile/Containers/Data/Application/AAAA"
        let newHome = "/var/mobile/Containers/Data/Application/BBBB"
        let folder = oldHome + "/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base"

        let stored = WhisperKitModelCatalog.portable(folder, home: oldHome)
        XCTAssertFalse(stored.contains("AAAA"))
        XCTAssertEqual(WhisperKitModelCatalog.resolve(stored, home: oldHome), folder)
        XCTAssertEqual(
            WhisperKitModelCatalog.resolve(stored, home: newHome),
            newHome + "/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base"
        )
    }

    func testPathsOutsideTheHomeDirectoryStayAbsolute() {
        let outside = "/Volumes/Models/openai_whisper-base"
        let stored = WhisperKitModelCatalog.portable(outside, home: "/Users/someone")
        XCTAssertEqual(stored, outside)
        XCTAssertEqual(WhisperKitModelCatalog.resolve(stored, home: "/Users/other"), outside)
        // A sibling directory that merely shares the prefix is not inside the home directory.
        XCTAssertEqual(WhisperKitModelCatalog.portable("/Users/someone-else/m", home: "/Users/someone"), "/Users/someone-else/m")
    }

    func testMultilingualFilter() {
        XCTAssertTrue(WhisperKitModelCatalog.isMultilingual("openai_whisper-large-v3-v20240930_turbo_632MB"))
        XCTAssertFalse(WhisperKitModelCatalog.isMultilingual("openai_whisper-base.en"))
        XCTAssertFalse(WhisperKitModelCatalog.isMultilingual("distil-whisper_distil-large-v3"))
    }
}
