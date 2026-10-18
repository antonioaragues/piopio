import AppKit
import Foundation
import QuartzCore

/// Records display-link callbacks. A late or missing callback means the main thread missed a frame.
@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var waiters: [CheckedContinuation<CFTimeInterval, Never>] = []
    private(set) var intervals: [Double] = []
    private var last: CFTimeInterval?
    private var recording = false

    func attach(to view: NSView) {
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        if recording, let last { intervals.append((now - last) * 1000) }
        last = now
        let ws = waiters
        waiters.removeAll()
        for w in ws { w.resume(returning: now) }
    }

    func nextFrame() async -> CFTimeInterval {
        await withCheckedContinuation { waiters.append($0) }
    }

    func startRecording() {
        intervals = []
        last = nil
        recording = true
    }

    func stopRecording() -> [Double] {
        recording = false
        return intervals
    }
}

struct FrameStats: Codable {
    var frames: Int
    var seconds: Double
    var p50Ms: Double
    var p95Ms: Double
    var p99Ms: Double
    var maxMs: Double
    /// Milliseconds of hitch per second of activity (Apple's "hitch time ratio"). <5 good, 5–10 warning, >10 bad.
    var hitchMsPerSec: Double
    /// Fraction of display refreshes that were missed.
    var droppedFraction: Double

    init(intervals: [Double], refreshMs: Double) {
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let total = intervals.reduce(0, +)
        frames = intervals.count
        seconds = total / 1000
        p50Ms = pct(0.5)
        p95Ms = pct(0.95)
        p99Ms = pct(0.99)
        maxMs = sorted.last ?? 0
        let hitch = intervals.reduce(0) { $0 + max(0, $1 - refreshMs * 1.5) }
        hitchMsPerSec = total > 0 ? hitch / (total / 1000) : 0
        let expected = total / refreshMs
        droppedFraction = expected > 0 ? max(0, 1 - Double(intervals.count) / expected) : 0
    }
}

struct LabResults: Codable {
    var renderer: String
    var items: Int
    var characters: Int
    var refreshHz: Int
    var loadSyncMs: Double = 0
    var loadToFrameMs: Double = 0
    var footprintAfterLoadMB: Double = 0
    var scroll: FrameStats?
    var fling: FrameStats?
    var stream: FrameStats?
    var streamCharsPerSec: Double = 0
    var streamAppendAvgMs: Double = 0
    var streamAppendMaxMs: Double = 0
    var footprintEndMB: Double = 0
    // S2b
    var tailToFrameMs: Double?
    var backfillTotalMs: Double?
    var backfill: FrameStats?
    var prependMaxMs: Double?
    var toggle: FrameStats?
    var toggleAvgMs: Double?
    var toggleMaxMs: Double?
    var longStream: FrameStats?
    var longStreamChars: Int?
    var longStreamAppendAvgMs: Double?
    var longStreamAppendMaxMs: Double?
    var pageLoads: Int?
    var pageLoadAvgMs: Double?
    var pageLoadMaxMs: Double?
    var pageAnchorDriftChars: Int?
    var notes: [String] = []
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

@MainActor
func snapshot(_ view: NSView, to url: URL) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    // Composite onto the window background: hosting views render with a transparent backdrop.
    let image = NSImage(size: view.bounds.size, flipped: false) { rect in
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        rep.draw(in: rect)
        return true
    }
    guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
    try? out.representation(using: .png, properties: [:])?.write(to: url)
}

/// Wheel-like scrolling through the clip view, independent of how the document is built.
@MainActor
struct Scroller {
    let scrollView: NSScrollView

    private var clip: NSClipView { scrollView.contentView }
    private var maxOffset: CGFloat { max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height) }
    private var flipped: Bool { scrollView.documentView?.isFlipped ?? true }

    /// Distance from the top of the document.
    var offsetFromTop: CGFloat {
        get { flipped ? clip.bounds.origin.y : maxOffset - clip.bounds.origin.y }
        nonmutating set {
            let clamped = min(max(0, newValue), maxOffset)
            clip.scroll(to: NSPoint(x: 0, y: flipped ? clamped : maxOffset - clamped))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func toBottom() { offsetFromTop = maxOffset }
    var atTop: Bool { offsetFromTop <= 0.5 }
}
