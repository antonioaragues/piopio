import AppKit
import PiopioKit

/// What every candidate renderer must support for the benchmarks.
@MainActor
protocol LabRenderer: AnyObject {
    var name: String { get }
    var view: NSView { get }
    func load(_ items: [TimelineItem])
    /// Appends an empty streaming answer.
    func beginStreaming()
    /// Appends text to the streaming answer (one engine event batch).
    func append(_ delta: String)
    func finishStreaming()
    /// The scroll view the benchmark drives (wheel-like scrolling), once laid out.
    func scrollView() -> NSScrollView?
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T { return match }
            if let match = sub.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
