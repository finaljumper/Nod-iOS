import Foundation

/// Fetches model files from Hugging Face into the app's own storage, once.
enum ModelDownloader {
    enum Failure: Error, CustomStringConvertible {
        case download(file: String, status: Int)

        var description: String {
            switch self {
            case .download(let file, let status): return "Could not download \(file) (HTTP \(status))."
            }
        }
    }

    /// Where downloaded models live: Application Support, so that they are not offered to the
    /// user as documents and are not removed by the system the way caches are.
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NodCompanion/Models", isDirectory: true)
    }

    static func isComplete(files: [String], in directory: URL) -> Bool {
        files.allSatisfy { file in
            let path = directory.appendingPathComponent(file).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return size > 0
        }
    }

    /// Downloads the files of a repository that are not there yet. `progress` is called
    /// before each download with a sentence for the user.
    static func ensure(
        repository: String, files: [String], in directory: URL, name: String,
        progress: @Sendable (String) -> Void
    ) async throws {
        let manager = FileManager.default
        let missing = files.filter { !isComplete(files: [$0], in: directory) }
        for (index, file) in missing.enumerated() {
            progress("Downloading \(name), part \(index + 1) of \(missing.count). This happens once.")
            let target = directory.appendingPathComponent(file)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/main/\(file)") else { continue }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                try? manager.removeItem(at: temporary)
                throw Failure.download(file: file, status: status)
            }
            try? manager.removeItem(at: target)
            try manager.moveItem(at: temporary, to: target)
        }
    }
}
