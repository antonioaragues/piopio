import AppKit
import ImageIO
import PDFKit
import PiopioKit
import UniformTypeIdentifiers

/// A file prepared for sending, shown as a chip in the composer.
struct PendingAttachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let attachment: Attachment
    var isImage: Bool { if case .image = attachment { true } else { false } }
}

/// Turns files and pasted images into attachments: images downscaled to JPEG, PDFs and text files as text.
enum AttachmentLoader {
    static let maxImageSide: CGFloat = 2048
    static let maxTextBytes = 4 * 1024 * 1024

    enum Failure: LocalizedError {
        case unsupported(String), unreadable(String), tooLarge(String), emptyPDF(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let n): "Can't attach \(n): only images, PDFs and text files are supported."
            case .unreadable(let n): "Couldn't read \(n)."
            case .tooLarge(let n): "\(n) is too large to attach."
            case .emptyPDF(let n): "\(n) has no text to read (it may be a scanned PDF)."
            }
        }
    }

    static func load(_ url: URL) throws -> PendingAttachment {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadable(name) }
            return try image(source, name: name)
        }
        if type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else { throw Failure.unreadable(name) }
            let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.emptyPDF(name) }
            return PendingAttachment(name: name, attachment: .text(name: name, mimeType: "application/pdf", text: text))
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxTextBytes { throw Failure.tooLarge(name) }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), !data.contains(0) else { throw Failure.unsupported(name) }
        return PendingAttachment(name: name, attachment: .text(name: name, mimeType: type.preferredMIMEType, text: text))
    }

    /// Images from the pasteboard (screenshots, copied images).
    static func load(imageData: Data, name: String = "Pasted image.jpg") throws -> PendingAttachment {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { throw Failure.unreadable(name) }
        return try image(source, name: name)
    }

    private static func image(_ source: CGImageSource, name: String) throws -> PendingAttachment {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable(name) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.unreadable(name) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unreadable(name) }
        return PendingAttachment(name: name, attachment: .image(name: name, mimeType: "image/jpeg", data: (data as Data).base64EncodedString()))
    }
}
