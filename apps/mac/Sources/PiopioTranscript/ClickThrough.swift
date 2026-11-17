import AppKit

/// A view inside the transcript that takes its own clicks and drags: a visual's page, a table's selectable cells.
protocol ClickThroughArea: NSView {}

/// The transcript is a text view, and its selection gestures hold a mouse-down back until they know it isn't a double
/// click or a drag, which swallows a click meant for a page inside it and a drag that selects a table cell's text.
/// While the mouse is down in a `ClickThroughArea`, those gestures (only the text view's) are paused, so the event goes
/// straight to the view under it.
@MainActor enum ClickThrough {
    private static var monitor: Any?
    private static var paused: [NSGestureRecognizer] = []

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown {
                    pause(for: event)
                } else if !paused.isEmpty {
                    // After this event is delivered: the text view's selection works again everywhere else.
                    DispatchQueue.main.async {
                        paused.forEach { $0.isEnabled = true }
                        paused = []
                    }
                }
            }
            return event
        }
    }

    private static func pause(for event: NSEvent) {
        guard let frame = event.window?.contentView?.superview else { return }
        var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let v = view, !(v is ClickThroughArea) { view = v.superview }
        guard view != nil else { return }
        while let v = view?.superview {
            if v is NSTextView {
                for g in v.gestureRecognizers where g.isEnabled && g.delaysPrimaryMouseButtonEvents {
                    g.isEnabled = false
                    paused.append(g)
                }
            }
            view = v
        }
    }
}
