import AppKit
import PDFKit
import Quartz
import SwiftTerm
import WebKit

/// The arrow comes back when the mouse leaves text. Text views and fields (the composers, the transcript, the
/// terminal) set the I-beam themselves, but SwiftUI's own views never set a cursor, so after leaving a text field
/// for piopio, the sidebar or an empty stretch of a page the I-beam stayed. After each mouse event the app handles,
/// an I-beam over something that isn't text becomes the arrow again. Other cursors (a link's hand, a column resize)
/// are left alone.
@MainActor
enum CursorKeeper {
    private static var monitor: Any?
    /// Owns the tracking areas that make every window the mouse reaches send mouse moves, so the check also runs over
    /// views with no hover of their own.
    private static let mover = NSResponder()

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .leftMouseUp, .rightMouseUp, .scrollWheel]) { event in
            let number = event.windowNumber, location = event.locationInWindow
            MainActor.assumeIsolated { track(event.window) }
            // After the event is handled: that's when a text view has set its I-beam.
            DispatchQueue.main.async { MainActor.assumeIsolated { restoreArrow(in: NSApp.window(withWindowNumber: number), at: location) } }
            return event
        }
    }

    private static func track(_ window: NSWindow?) {
        guard let view = window?.contentView, !view.trackingAreas.contains(where: { $0.owner === mover }) else { return }
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: mover, userInfo: nil))
    }

    private static func restoreArrow(in window: NSWindow?, at location: NSPoint) {
        // While dragging (selecting text past a field's edge) the I-beam stays.
        guard NSCursor.current == .iBeam, NSEvent.pressedMouseButtons == 0,
              let window, window.isVisible, let frame = window.contentView?.superview ?? window.contentView,
              frame.bounds.contains(frame.convert(location, from: nil)),
              let hit = frame.hitTest(location) else { return }
        if !isText(hit) { NSCursor.arrow.set() }
    }

    /// Whether the view under the mouse shows the I-beam: text, or inside a text view, a web page, a PDF or a terminal.
    /// SwiftUI hosted inside a text view (the transcript's cards) is not text, unless it's selectable text itself.
    static func isText(_ hit: NSView) -> Bool {
        var view: NSView? = hit
        while let v = view {
            if v is NSText || v is WKWebView || v is PDFView || v is QLPreviewView || v is TerminalView { return true }
            if let field = v as? NSTextField { return field.isEditable || field.isSelectable }
            let name = String(describing: type(of: v))
            // SwiftUI's selectable Text (`.textSelection(.enabled)`) is drawn by this view.
            if name.contains("TextInteraction") { return true }
            if name.contains("HostingView") { return false }
            view = v.superview
        }
        return false
    }
}
