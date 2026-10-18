import AppKit
import SwiftUI

/// SwiftUI host for a `TranscriptDocument`.
public struct TranscriptView: NSViewRepresentable {
    let document: TranscriptDocument

    public init(document: TranscriptDocument) { self.document = document }

    public func makeNSView(context: Context) -> NSScrollView { document.scrollView }
    public func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
