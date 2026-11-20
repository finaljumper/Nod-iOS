import Foundation

/// What kind of speech a recording contains. Language coverage is described separately by
/// `Recording.languages`, so "English–Russian code-switched short command" is
/// `languages: ["en", "ru"]` with `category: .command`.
public enum RecordingCategory: String, Codable, Sendable, CaseIterable {
    /// Everyday conversational speech.
    case conversational
    /// Short commands addressed to an assistant.
    case command
    /// Long conversational sentences.
    case longForm = "long-form"
    /// Names, dates, numbers and calendar vocabulary.
    case entities
    /// Natural hesitations, pauses and filler words.
    case disfluent
}

/// One recording of the benchmark dataset.
public struct Recording: Codable, Sendable, Equatable, Identifiable {
    /// Unique identifier within the manifest.
    public var id: String
    /// Path of the audio file, relative to the manifest.
    public var audioFile: String
    /// Reference transcript, written exactly as spoken.
    public var transcript: String
    /// BCP 47 language codes spoken in the recording. The first is the primary language.
    /// More than one entry marks the recording as code-switched.
    public var languages: [String]
    public var category: RecordingCategory
    /// Duration in seconds. Optional; checked against the audio file when present.
    public var durationSeconds: Double?
    /// Anonymous speaker identifier.
    public var speaker: String
    /// Optional difficulty tags, for example `noisy`, `fast`, `accented`.
    public var tags: [String]?
    /// Proper nouns, dates, numbers and other terms whose recognition is scored separately.
    public var keyTerms: [String]?
    /// Where speech starts and ends in the file, in seconds. When absent the benchmark
    /// estimates the bounds from signal energy and says so in the results.
    public var speechStartSeconds: Double?
    public var speechEndSeconds: Double?
    /// Where the recording came from (for example `self-recorded` or a corpus name).
    public var source: String?

    public init(
        id: String,
        audioFile: String,
        transcript: String,
        languages: [String],
        category: RecordingCategory,
        durationSeconds: Double? = nil,
        speaker: String,
        tags: [String]? = nil,
        keyTerms: [String]? = nil,
        speechStartSeconds: Double? = nil,
        speechEndSeconds: Double? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.audioFile = audioFile
        self.transcript = transcript
        self.languages = languages
        self.category = category
        self.durationSeconds = durationSeconds
        self.speaker = speaker
        self.tags = tags
        self.keyTerms = keyTerms
        self.speechStartSeconds = speechStartSeconds
        self.speechEndSeconds = speechEndSeconds
        self.source = source
    }

    public var primaryLanguage: String { languages.first ?? "und" }
    public var isCodeSwitched: Bool { languages.count > 1 }
    /// Order-independent key such as `en`, `en+ru` or `en+ko+ru`.
    public var languageKey: String { languages.sorted().joined(separator: "+") }
}

/// The dataset manifest (`manifest.json`).
public struct BenchmarkManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var description: String?
    public var recordings: [Recording]

    public init(schemaVersion: Int = BenchmarkManifest.currentSchemaVersion, name: String, description: String? = nil, recordings: [Recording]) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.description = description
        self.recordings = recordings
    }

    public static func load(from url: URL) throws -> BenchmarkManifest {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> BenchmarkManifest {
        let manifest = try JSONDecoder().decode(BenchmarkManifest.self, from: data)
        guard manifest.schemaVersion <= currentSchemaVersion else {
            throw ManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum ManifestError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Manifest schema version \(version) is newer than this app supports (\(BenchmarkManifest.currentSchemaVersion))."
        }
    }
}

/// A problem found while validating a manifest.
public struct ManifestIssue: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable {
        /// The recording cannot be benchmarked.
        case error
        /// The recording can be benchmarked, but something deserves attention.
        case warning
    }

    public var severity: Severity
    public var recordingID: String?
    public var message: String

    public var id: String { "\(severity.rawValue)|\(recordingID ?? "")|\(message)" }

    public init(_ severity: Severity, recordingID: String? = nil, _ message: String) {
        self.severity = severity
        self.recordingID = recordingID
        self.message = message
    }
}

/// A manifest together with the folder its audio paths are relative to.
public struct BenchmarkDataset: Sendable {
    public var manifest: BenchmarkManifest
    public var baseURL: URL

    public init(manifest: BenchmarkManifest, baseURL: URL) {
        self.manifest = manifest
        self.baseURL = baseURL
    }

    /// Loads `manifest.json` from a dataset folder, or a manifest file directly.
    public static func load(from url: URL) throws -> BenchmarkDataset {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let manifestURL = exists && isDirectory.boolValue ? url.appendingPathComponent("manifest.json") : url
        let manifest = try BenchmarkManifest.load(from: manifestURL)
        return BenchmarkDataset(manifest: manifest, baseURL: manifestURL.deletingLastPathComponent())
    }

    public func audioURL(for recording: Recording) -> URL {
        baseURL.appendingPathComponent(recording.audioFile)
    }

    public func hasAudio(for recording: Recording) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: recording).path)
    }

    /// Recordings whose audio file exists.
    public var recordingsWithAudio: [Recording] {
        manifest.recordings.filter(hasAudio(for:))
    }

    /// Checks the manifest and, for WAV files, the audio headers.
    public func validate() -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        if manifest.recordings.isEmpty {
            issues.append(.init(.error, "The manifest contains no recordings."))
        }

        var seen = Set<String>()
        for recording in manifest.recordings {
            let id = recording.id
            if id.isEmpty {
                issues.append(.init(.error, recordingID: id, "Recording has an empty id."))
            }
            if !seen.insert(id).inserted {
                issues.append(.init(.error, recordingID: id, "Duplicate recording id."))
            }
            if recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(.error, recordingID: id, "Reference transcript is empty."))
            }
            if recording.languages.isEmpty {
                issues.append(.init(.error, recordingID: id, "No language given."))
            }
            for language in recording.languages where !Self.isPlausibleLanguageCode(language) {
                issues.append(.init(.error, recordingID: id, "\"\(language)\" is not a BCP 47 language code such as en, ru or ko."))
            }
            if Set(recording.languages).count != recording.languages.count {
                issues.append(.init(.warning, recordingID: id, "A language is listed more than once."))
            }
            if recording.speaker.isEmpty {
                issues.append(.init(.warning, recordingID: id, "No speaker identifier."))
            }
            if let start = recording.speechStartSeconds, let end = recording.speechEndSeconds, end <= start {
                issues.append(.init(.error, recordingID: id, "speechEndSeconds must be greater than speechStartSeconds."))
            }

            let url = audioURL(for: recording)
            guard FileManager.default.fileExists(atPath: url.path) else {
                issues.append(.init(.error, recordingID: id, "Audio file is missing: \(recording.audioFile)"))
                continue
            }
            guard WAVDecoder().canDecode(url: url) else {
                let lossless = ["caf", "flac", "aiff", "aif"]
                if !lossless.contains(url.pathExtension.lowercased()) {
                    issues.append(.init(.warning, recordingID: id, ".\(url.pathExtension) may be a lossy format; use WAV or another lossless container."))
                }
                continue
            }
            do {
                let header = try WAVDecoder.readHeader(url: url)
                if header.sampleRate < 16_000 {
                    issues.append(.init(.error, recordingID: id, "Sample rate \(Int(header.sampleRate)) Hz is below 16 kHz."))
                }
                if header.channels > 1 {
                    issues.append(.init(.warning, recordingID: id, "\(header.channels) channels; the benchmark downmixes to mono."))
                }
                if let declared = recording.durationSeconds, abs(declared - header.durationSeconds) > 0.25 {
                    let actual = String(format: "%.2f", header.durationSeconds)
                    issues.append(.init(.warning, recordingID: id, "Manifest duration \(declared)s differs from the file (\(actual)s)."))
                }
                if let end = recording.speechEndSeconds, end > header.durationSeconds + 0.05 {
                    issues.append(.init(.error, recordingID: id, "speechEndSeconds is past the end of the file."))
                }
            } catch {
                issues.append(.init(.error, recordingID: id, "Cannot read audio: \(error)"))
            }
        }
        return issues
    }

    static func isPlausibleLanguageCode(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLetter && $0.isLowercase })
        else { return false }
        return parts.dropFirst().allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }
}

public extension String {
    /// The language subtag of a BCP 47 identifier: `ko` for `ko-KR`.
    var languageSubtag: String {
        String(split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}
