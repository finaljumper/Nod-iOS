import XCTest
@testable import ASRBenchCore

final class ManifestTests: XCTestCase {
    private var sampleManifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Dataset/manifest.json")
    }

    func testBundledSampleManifestDecodesAndCoversEveryCategory() throws {
        let manifest = try BenchmarkManifest.load(from: sampleManifestURL)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(Set(manifest.recordings.map(\.id)).count, manifest.recordings.count)
        XCTAssertEqual(Set(manifest.recordings.map(\.category)), Set(RecordingCategory.allCases))
        let keys = Set(manifest.recordings.map(\.languageKey))
        for key in ["en", "ru", "ko", "en+ru", "en+ko", "ko+ru", "en+ko+ru"] {
            XCTAssertTrue(keys.contains(key), "missing language combination \(key)")
        }
    }

    func testBundledSampleShipsNoAudioAndSaysSo() throws {
        let dataset = try BenchmarkDataset.load(from: sampleManifestURL)
        XCTAssertTrue(dataset.recordingsWithAudio.isEmpty, "the sample manifest must not ship audio")
        let issues = dataset.validate()
        let missing = issues.filter { $0.severity == .error && $0.message.hasPrefix("Audio file is missing") }
        XCTAssertEqual(missing.count, dataset.manifest.recordings.count)
        XCTAssertFalse(issues.contains { $0.severity == .error && !$0.message.hasPrefix("Audio file is missing") })
    }

    func testDecodingMinimalEntryAndOptionalFields() throws {
        let json = """
        {"schemaVersion": 1, "name": "t", "recordings": [
          {"id": "a", "audioFile": "audio/a.wav", "transcript": "안녕하세요", "languages": ["ko"], "category": "long-form", "speaker": "s1"},
          {"id": "b", "audioFile": "audio/b.wav", "transcript": "hi", "languages": ["en", "ru"], "category": "command", "speaker": "s2",
           "durationSeconds": 1.5, "tags": ["noisy"], "keyTerms": ["hi"], "speechStartSeconds": 0.2, "speechEndSeconds": 1.1, "source": "self-recorded"}
        ]}
        """
        let manifest = try BenchmarkManifest.decode(Data(json.utf8))
        XCTAssertEqual(manifest.recordings[0].category, .longForm)
        XCTAssertEqual(manifest.recordings[0].transcript, "안녕하세요")
        XCTAssertNil(manifest.recordings[0].durationSeconds)
        XCTAssertFalse(manifest.recordings[0].isCodeSwitched)
        XCTAssertEqual(manifest.recordings[1].languageKey, "en+ru")
        XCTAssertEqual(manifest.recordings[1].primaryLanguage, "en")
        XCTAssertTrue(manifest.recordings[1].isCodeSwitched)
        XCTAssertEqual(manifest.recordings[1].speechEndSeconds, 1.1)

        let roundTrip = try BenchmarkManifest.decode(manifest.encoded())
        XCTAssertEqual(roundTrip, manifest)
    }

    func testNewerSchemaIsRejected() {
        let json = #"{"schemaVersion": 99, "name": "t", "recordings": []}"#
        XCTAssertThrowsError(try BenchmarkManifest.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedSchema(99))
        }
    }

    func testUnknownCategoryIsRejected() {
        let json = #"{"schemaVersion": 1, "name": "t", "recordings": [{"id": "a", "audioFile": "a.wav", "transcript": "x", "languages": ["en"], "category": "poetry", "speaker": "s"}]}"#
        XCTAssertThrowsError(try BenchmarkManifest.decode(Data(json.utf8)))
    }

    func testValidationFindsProblems() throws {
        let directory = try TestSignal.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, sampleRate: Int, seconds: Double, channels: Int = 1) throws {
            let samples = [Float](repeating: 0.1, count: Int(Double(sampleRate) * seconds) * channels)
            try WAVWriter.pcm16Data(samples: samples, sampleRate: sampleRate, channels: channels).write(to: directory.appendingPathComponent(name))
        }
        try write("good.wav", sampleRate: 16_000, seconds: 1)
        try write("low.wav", sampleRate: 8_000, seconds: 1)
        try write("stereo.wav", sampleRate: 48_000, seconds: 1, channels: 2)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("broken.wav"))
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("clip.mp3"))

        func recording(_ id: String, _ file: String, transcript: String = "text", languages: [String] = ["en"], duration: Double? = nil) -> Recording {
            Recording(id: id, audioFile: file, transcript: transcript, languages: languages, category: .conversational, durationSeconds: duration, speaker: "s")
        }
        let manifest = BenchmarkManifest(name: "t", recordings: [
            recording("good", "good.wav", duration: 1.0),
            recording("good", "good.wav"),                              // duplicate id
            recording("empty", "good.wav", transcript: "  "),
            recording("lang", "good.wav", languages: ["English"]),
            recording("nolang", "good.wav", languages: []),
            recording("low", "low.wav"),
            recording("stereo", "stereo.wav"),
            recording("duration", "good.wav", duration: 3.0),
            recording("missing", "nope.wav"),
            recording("broken", "broken.wav"),
            recording("lossy", "clip.mp3"),
        ])
        let issues = BenchmarkDataset(manifest: manifest, baseURL: directory).validate()
        func has(_ severity: ManifestIssue.Severity, _ id: String, _ fragment: String) -> Bool {
            issues.contains { $0.severity == severity && $0.recordingID == id && $0.message.contains(fragment) }
        }
        XCTAssertTrue(has(.error, "good", "Duplicate"))
        XCTAssertTrue(has(.error, "empty", "transcript is empty"))
        XCTAssertTrue(has(.error, "lang", "not a BCP 47"))
        XCTAssertTrue(has(.error, "nolang", "No language"))
        XCTAssertTrue(has(.error, "low", "below 16 kHz"))
        XCTAssertTrue(has(.warning, "stereo", "2 channels"))
        XCTAssertTrue(has(.warning, "duration", "differs from the file"))
        XCTAssertTrue(has(.error, "missing", "Audio file is missing"))
        XCTAssertTrue(has(.error, "broken", "Cannot read audio"))
        XCTAssertTrue(has(.warning, "lossy", "lossy"))
        XCTAssertEqual(issues.filter { $0.recordingID == "stereo" && $0.severity == .error }.count, 0)
    }

    func testLanguageCodes() {
        for code in ["en", "ru", "ko", "yue", "en-US", "zh-Hant-TW"] {
            XCTAssertTrue(BenchmarkDataset.isPlausibleLanguageCode(code), code)
        }
        for code in ["", "e", "EN", "english", "en_US", "en-"] {
            XCTAssertFalse(BenchmarkDataset.isPlausibleLanguageCode(code), code)
        }
        XCTAssertEqual("ko-KR".languageSubtag, "ko")
        XCTAssertEqual("en_US".languageSubtag, "en")
    }

    func testLoadingFromAFolder() throws {
        let directory = try TestSignal.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = BenchmarkManifest(name: "folder", recordings: [])
        try manifest.encoded().write(to: directory.appendingPathComponent("manifest.json"))
        let dataset = try BenchmarkDataset.load(from: directory)
        XCTAssertEqual(dataset.manifest.name, "folder")
        XCTAssertEqual(dataset.baseURL.standardizedFileURL.path, directory.standardizedFileURL.path)
    }
}
