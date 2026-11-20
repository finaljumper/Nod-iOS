import XCTest
@testable import ASRBenchMLXEngines

/// These tests cover the adapter's own logic. None of them loads the model or touches MLX.
final class RumbleFlashEngineTests: XCTestCase {
    func testEngineIdentifiersAreStable() {
        // Exported results are keyed by these identifiers.
        XCTAssertEqual(RumbleFlashConfiguration().engineID, "rumble/Rumble-2-Flash-8bit")
        XCTAssertEqual(RumbleFlashConfiguration(numbersAsDigits: false).engineID, "rumble/Rumble-2-Flash-8bit/number-words")
        XCTAssertEqual(RumbleFlashConfiguration(repository: "someone/Other-Build").engineID, "rumble/Other-Build")
    }

    func testSystemPromptCarriesTheControlTokens() {
        XCTAssertEqual(RumbleFlashConfiguration().systemPrompt, "<digits><nofiller><verbatim>")
        XCTAssertEqual(RumbleFlashConfiguration(numbersAsDigits: false).systemPrompt, "<nodigits><nofiller><verbatim>")
    }

    func testLanguageCodesMapToTheModelsNames() {
        XCTAssertEqual(RumbleLanguages.name(for: "en"), "English")
        XCTAssertEqual(RumbleLanguages.name(for: "ru"), "Russian")
        XCTAssertEqual(RumbleLanguages.name(for: "ko-KR"), "Korean")
        XCTAssertNil(RumbleLanguages.name(for: "xx"))
        XCTAssertEqual(RumbleLanguages.namesByCode.count, 30)
        XCTAssertEqual(Set(RumbleLanguages.namesByCode.values).count, 30, "every name belongs to one code")
    }

    func testReportedLanguageNamesMapBackToCodes() {
        XCTAssertEqual(RumbleLanguages.code(forReported: "Russian"), "ru")
        XCTAssertEqual(RumbleLanguages.code(forReported: "korean"), "ko")
        XCTAssertEqual(RumbleLanguages.code(forReported: "English, Russian"), "en", "the first of several languages wins")
        XCTAssertNil(RumbleLanguages.code(forReported: "Klingon"))
        XCTAssertNil(RumbleLanguages.code(forReported: nil))
        XCTAssertNil(RumbleLanguages.code(forReported: ""))
    }

    func testModelDirectoryRepeatsTheDownloadersLayout() {
        let root = URL(fileURLWithPath: "/cache")
        XCTAssertEqual(
            RumbleModelStore.modelDirectory(repository: "TypeWhisper/Rumble-2-Flash-8bit", cacheRoot: root).path,
            "/cache/mlx-audio/TypeWhisper_Rumble-2-Flash-8bit"
        )
        XCTAssertEqual(
            RumbleModelStore.hubCacheDirectory(repository: "TypeWhisper/Rumble-2-Flash-8bit", cacheRoot: root).path,
            "/cache/models--TypeWhisper--Rumble-2-Flash-8bit"
        )
    }

    func testDownloadedMeansConfigurationAndNonEmptyWeights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rumble-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = "owner/model"
        let folder = RumbleModelStore.modelDirectory(repository: repository, cacheRoot: root)
        XCTAssertFalse(RumbleModelStore.isDownloaded(repository: repository, cacheRoot: root))

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertFalse(RumbleModelStore.isDownloaded(repository: repository, cacheRoot: root), "no weights yet")

        // An interrupted download leaves an empty file behind.
        try Data().write(to: folder.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(RumbleModelStore.isDownloaded(repository: repository, cacheRoot: root))

        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("model.safetensors"))
        XCTAssertTrue(RumbleModelStore.isDownloaded(repository: repository, cacheRoot: root))
    }

    func testStablePartIsWhatTwoDecodesAgreeOn() {
        XCTAssertEqual(RumbleFlashEngine.commonWordPrefix("set a timer", "set a timer for ten"), "set a timer")
        XCTAssertEqual(RumbleFlashEngine.commonWordPrefix("set a time", "set a timer for ten"), "set a")
        XCTAssertEqual(RumbleFlashEngine.commonWordPrefix("", "set a timer"), "")
        XCTAssertEqual(RumbleFlashEngine.commonWordPrefix("Okay, давай так", "Okay, давай так. I'll book"), "Okay, давай")
    }

    func testUnknownLanguageIsUnavailableNotAnError() async {
        let engine = RumbleFlashEngine()
        guard case .unavailable = await engine.availability(forLanguage: "xx") else {
            return XCTFail("a language the model does not have must be reported as unavailable")
        }
        let descriptor = await engine.descriptor()
        XCTAssertEqual(descriptor.capabilities.streaming.level, .simulated)
        XCTAssertEqual(descriptor.capabilities.segmentTimestamps.level, .unsupported)
        XCTAssertEqual(descriptor.id, "rumble/Rumble-2-Flash-8bit")
    }
}
