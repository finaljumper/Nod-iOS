import NodCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Turns what the user picked into attachments that can be sent.
enum AttachmentLoader {
    /// Photos are scaled down to this many pixels on their longer side before they are sent.
    static let photoSide: CGFloat = 2048
    /// Files are held in memory until they are sent; larger ones are refused. Nod itself
    /// takes up to 90 MB.
    static let fileLimit = 25 * 1024 * 1024

    struct Problem: Error {
        var message: String
    }

    static func photo(_ item: PhotosPickerItem, number: Int) async throws -> Attachment {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw Problem(message: "A photo could not be read.")
        }
        if let jpeg = await scaledJPEG(from: data) {
            return Attachment(name: "Photo \(number).jpg", mimeType: "image/jpeg", data: jpeg)
        }
        // Not something this device can draw: sent as it is.
        let type = item.supportedContentTypes.first
        return Attachment(
            name: "Photo \(number).\(type?.preferredFilenameExtension ?? "img")",
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            data: data
        )
    }

    static func file(_ url: URL) throws -> Attachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= fileLimit else {
            throw Problem(message: "\(url.lastPathComponent) is larger than 25 MB and cannot be sent from this app.")
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw Problem(message: "\(url.lastPathComponent) is empty.") }
        let type = UTType(filenameExtension: url.pathExtension)
        return Attachment(name: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data)
    }

    private nonisolated static func scaledJPEG(from data: Data) async -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longer = max(image.size.width, image.size.height) * image.scale
        guard longer > photoSide else { return image.jpegData(compressionQuality: 0.85) }
        let ratio = photoSide / longer
        let size = CGSize(width: image.size.width * image.scale * ratio, height: image.size.height * image.scale * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// A photo as a picture, anything else as a labelled chip. Content layer: fills, no glass.
struct AttachmentView: View {
    let attachment: Attachment
    /// The side of a photo's square preview.
    var side: CGFloat = 160

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityLabel(attachment.name)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: attachment.isImage ? "photo" : "doc")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.name).font(.footnote.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        if attachment.byteCount > 0 {
                            Text(Int64(attachment.byteCount), format: .byteCount(style: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: 220, minHeight: min(side, 48), alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: attachment.id) {
            guard attachment.isImage, let data = attachment.data else { return }
            let pixels = side * 3
            image = await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: pixels, height: pixels)) }.value
        }
    }
}
