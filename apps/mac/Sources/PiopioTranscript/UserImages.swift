import AppKit
import SwiftUI

// The images you sent with a message, as in Claude: thumbnails over your bubble, on its right edge, that open the
// image. Files that aren't images (and images sent before Piopio kept a copy) stay chips.

/// The thumbnails and somewhere to send "open" (the document wires it, as it does file cards).
public final class UserImagesModel: @unchecked Sendable {
    let images: [CardImage]
    var onAction: (@MainActor (TranscriptAction) -> Void)?

    init(images: [CardImage]) { self.images = images }

    static let tile = CGSize(width: 120, height: 90)
    static let gap: CGFloat = 8

    /// How many fit on a row of `width`; at least one.
    static func perRow(_ width: CGFloat) -> Int { max(1, Int((width + gap) / (tile.width + gap))) }

    func height(for width: CGFloat) -> CGFloat {
        let rows = CGFloat((images.count + Self.perRow(width) - 1) / Self.perRow(width))
        return rows * Self.tile.height + max(0, rows - 1) * Self.gap
    }
}

final class UserImagesAttachment: NSTextAttachment, @unchecked Sendable {
    let model: UserImagesModel

    init(model: UserImagesModel) {
        self.model = model
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = UserImagesViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class UserImagesViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let model = (textAttachment as! UserImagesAttachment).model
        view = MainActor.assumeIsolated { ArrowHostingView(rootView: UserImagesView(model: model)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let model = (textAttachment as! UserImagesAttachment).model
        let width = textContainer?.size.width ?? proposedLineFragment.width
        return CGRect(x: 0, y: 0, width: width, height: model.height(for: width))
    }
}

struct UserImagesView: View {
    let model: UserImagesModel

    var body: some View {
        GeometryReader { geo in
            let perRow = UserImagesModel.perRow(geo.size.width)
            // Rows fill from the end, so a short row sits on the right, by the bubble.
            let rows = stride(from: 0, to: model.images.count, by: perRow).map { Array(model.images[$0..<min($0 + perRow, model.images.count)]) }
            VStack(alignment: .trailing, spacing: UserImagesModel.gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: UserImagesModel.gap) {
                        ForEach(rows[r], id: \.self) { image in UserImageTile(image: image, open: open) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func open(_ image: CardImage) {
        MainActor.assumeIsolated { model.onAction?(.openAttachment(stored: image.stored)) }
    }
}

/// One image you sent: a rounded crop of it; a click opens it in the viewer.
struct UserImageTile: View {
    let image: CardImage
    let open: (CardImage) -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.code, style: .continuous)

    var body: some View {
        let size = UserImagesModel.tile
        Button { open(image) } label: {
            ZStack {
                Self.shape.fill(Color(nsColor: DS.chip))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                } else {
                    Image(systemName: "photo").font(.system(size: 16)).foregroundStyle(Color(nsColor: DS.fg3))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(Self.shape)
            .overlay(Self.shape.strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
            .brightness(hovering ? -0.04 : 0)
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(image.name)")
        .accessibilityLabel("Image \(image.name)")
        .onDrag { NSItemProvider(contentsOf: image.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { open(image) }
            Button("Open in Default App") { NSWorkspace.shared.open(image.url) }
            Button("Save a Copy…") { FileSaving.saveCopy(of: image.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([image.url]) }
        }
        // Read at twice the tile's size, for Retina screens.
        .task(id: image.url) { thumbnail = await StepThumbnail.load(image.url, maxPixel: Int(size.width * 2)) }
    }
}
