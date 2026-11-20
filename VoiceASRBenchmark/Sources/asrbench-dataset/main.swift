import ASRBenchCore
import Foundation

// Dataset maintenance tool.
//
//   asrbench-dataset validate <dataset-folder>
//   asrbench-dataset scaffold <dataset-folder> [--speaker <id>] [--source <text>]
//   asrbench-dataset durations <dataset-folder>
//
// `scaffold` adds a manifest entry for every WAV file under <dataset-folder>/audio that is not
// listed yet. The transcript is read from a sidecar text file with the same name (clip.wav and
// clip.txt). Languages are taken from the file name prefix (en-, ru-ko-, en-ru-ko-) and, when
// the name has none, from the scripts found in the transcript.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func usage() -> Never {
    fail("""
    Usage:
      asrbench-dataset validate <dataset-folder>
      asrbench-dataset scaffold <dataset-folder> [--speaker <id>] [--source <text>]
      asrbench-dataset durations <dataset-folder>
    """)
}

func loadOrCreate(_ folder: URL) -> BenchmarkDataset {
    let manifestURL = folder.appendingPathComponent("manifest.json")
    if FileManager.default.fileExists(atPath: manifestURL.path) {
        do { return try BenchmarkDataset.load(from: folder) } catch { fail("Cannot read \(manifestURL.path): \(error)") }
    }
    return BenchmarkDataset(manifest: BenchmarkManifest(name: folder.lastPathComponent, recordings: []), baseURL: folder)
}

func save(_ dataset: BenchmarkDataset) {
    do {
        try dataset.manifest.encoded().write(to: dataset.baseURL.appendingPathComponent("manifest.json"))
    } catch {
        fail("Cannot write manifest: \(error)")
    }
}

func printIssues(_ issues: [ManifestIssue]) -> Bool {
    for issue in issues {
        let scope = issue.recordingID.map { " [\($0)]" } ?? ""
        print("\(issue.severity.rawValue.uppercased())\(scope) \(issue.message)")
    }
    let errors = issues.filter { $0.severity == .error }.count
    print("\(errors) error(s), \(issues.count - errors) warning(s)")
    return errors == 0
}

let knownLanguages: Set<String> = ["en", "ru", "ko"]

func languages(fileStem: String, transcript: String) -> [String] {
    var fromName: [String] = []
    for part in fileStem.lowercased().split(separator: "-") {
        guard knownLanguages.contains(String(part)) else { break }
        fromName.append(String(part))
    }
    if !fromName.isEmpty { return fromName }

    // Order languages by how many words each contributes, so the dominant one is primary.
    var counts: [String: Int] = [:]
    for word in TextNormalizer.words(transcript, mode: .relaxed) {
        switch Script.of(word) {
        case .latin: counts["en", default: 0] += 1
        case .cyrillic: counts["ru", default: 0] += 1
        case .hangul: counts["ko", default: 0] += 1
        default: break
        }
    }
    return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { usage() }
let command = arguments.removeFirst()
let folder = URL(fileURLWithPath: arguments.removeFirst())

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let speaker = option("--speaker", in: arguments)
let source = option("--source", in: arguments)

switch command {
case "validate":
    let dataset = loadOrCreate(folder)
    print("\(dataset.manifest.name): \(dataset.manifest.recordings.count) recordings, \(dataset.recordingsWithAudio.count) with audio")
    exit(printIssues(dataset.validate()) ? 0 : 1)

case "scaffold":
    var dataset = loadOrCreate(folder)
    let audioFolder = folder.appendingPathComponent("audio")
    guard let files = try? FileManager.default.contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: nil) else {
        fail("No audio folder at \(audioFolder.path)")
    }
    let listed = Set(dataset.manifest.recordings.map(\.audioFile))
    var added = 0
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where WAVDecoder().canDecode(url: file) {
        let relative = "audio/\(file.lastPathComponent)"
        guard !listed.contains(relative) else { continue }
        let stem = file.deletingPathExtension().lastPathComponent
        let sidecar = file.deletingPathExtension().appendingPathExtension("txt")
        let transcript = ((try? String(contentsOf: sidecar, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = (try? WAVDecoder.readHeader(url: file))?.durationSeconds
        dataset.manifest.recordings.append(Recording(
            id: stem,
            audioFile: relative,
            transcript: transcript,
            languages: languages(fileStem: stem, transcript: transcript),
            category: .conversational,
            durationSeconds: duration.map { ($0 * 1000).rounded() / 1000 },
            speaker: speaker ?? "unassigned",
            source: source
        ))
        added += 1
        print("added \(stem)\(transcript.isEmpty ? "  (no \(sidecar.lastPathComponent): fill in the transcript)" : "")")
    }
    save(dataset)
    print("\(added) recording(s) added. Review category, keyTerms and tags in manifest.json.")
    exit(printIssues(dataset.validate()) ? 0 : 1)

case "durations":
    var dataset = loadOrCreate(folder)
    var updated = 0
    for index in dataset.manifest.recordings.indices {
        let url = dataset.audioURL(for: dataset.manifest.recordings[index])
        guard let header = try? WAVDecoder.readHeader(url: url) else { continue }
        dataset.manifest.recordings[index].durationSeconds = (header.durationSeconds * 1000).rounded() / 1000
        updated += 1
    }
    save(dataset)
    print("Updated the duration of \(updated) recording(s).")

default:
    usage()
}
