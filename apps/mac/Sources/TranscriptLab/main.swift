import AppKit
import PiopioKit

// TranscriptLab: Spike S2. Can a native transcript render streaming markdown smoothly at 2,000 items?
//
//   swift run -c release TranscriptLab --renderer swiftui|swiftui-list|textkit [--items 2000] [--out dir]
//
// Opens a floating window for ~30 s, runs the scenarios, writes results-<renderer>.json and PNG snapshots.

struct Options {
    var renderer = "swiftui"
    var items = 2000
    var out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "transcript-lab")
    var scrollSpeed: CGFloat = 3000    // pt/s, a brisk trackpad scroll
    var flingSpeed: CGFloat = 14000    // pt/s, a hard fling through unrealized content
    var streamCharsPerSec = 600.0      // ~150 tokens/s, a fast model
    var streamBatchHz = 30.0           // engine event batches per second

    init(_ args: [String]) {
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--renderer": renderer = it.next() ?? renderer
            case "--items": items = Int(it.next() ?? "") ?? items
            case "--out": out = URL(fileURLWithPath: it.next() ?? out.path)
            default: FileHandle.standardError.write(Data("unknown option \(a)\n".utf8)); exit(2)
            }
        }
    }
}

@MainActor
func run(_ o: Options) async {
    try? FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    let renderer: LabRenderer = switch o.renderer {
    case "textkit": TextKitRenderer()
    case "swiftui-list": SwiftUIRenderer(list: true)
    default: SwiftUIRenderer()
    }

    let window = NSWindow(contentRect: NSRect(x: 120, y: 80, width: 860, height: 1000), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.title = "TranscriptLab: \(renderer.name)"
    window.level = .floating // stay visible: occluded windows get throttled display links
    window.contentView = renderer.view
    window.orderFrontRegardless()

    let clock = FrameClock()
    clock.attach(to: renderer.view)
    for _ in 0..<10 { _ = await clock.nextFrame() }

    let refreshHz = window.screen?.maximumFramesPerSecond ?? 60
    let refreshMs = 1000 / Double(refreshHz)
    var corpus = Corpus()
    let items = corpus.transcript(count: o.items)
    let chars = items.reduce(0) { n, i in
        switch i {
        case .assistant(let a): n + a.text.count
        case .user(let u): n + u.text.count
        case .tool(let t): n + (t.output?.count ?? 0)
        default: n
        }
    }
    var r = LabResults(renderer: renderer.name, items: items.count, characters: chars, refreshHz: refreshHz)
    func log(_ s: String) { print("[\(renderer.name)] \(s)") }

    // 1. Load and show the bottom.
    let t0 = CACurrentMediaTime()
    renderer.load(items)
    renderer.view.layoutSubtreeIfNeeded()
    r.loadSyncMs = (CACurrentMediaTime() - t0) * 1000
    _ = await clock.nextFrame()
    guard let sv = renderer.scrollView() else {
        r.notes.append("No NSScrollView found under the renderer view; scrolling scenarios skipped.")
        write(r, o)
        return
    }
    let scroller = Scroller(scrollView: sv)
    scroller.toBottom()
    _ = await clock.nextFrame()
    _ = await clock.nextFrame()
    r.loadToFrameMs = (CACurrentMediaTime() - t0) * 1000
    r.footprintAfterLoadMB = footprintMB()
    log(String(format: "loaded %d items (%d chars): sync %.0f ms, to frame %.0f ms, %.0f MB", items.count, chars, r.loadSyncMs, r.loadToFrameMs, r.footprintAfterLoadMB))
    snapshot(renderer.view, to: o.out.appending(path: "\(renderer.name)-1-bottom.png"))

    // 2. Scroll up steadily, then 3. fling, both from the bottom.
    func scrollUp(speed: CGFloat, seconds: Double) async -> FrameStats {
        scroller.toBottom()
        _ = await clock.nextFrame()
        clock.startRecording()
        var last = await clock.nextFrame()
        let end = last + seconds
        while last < end, !scroller.atTop {
            let now = await clock.nextFrame()
            scroller.offsetFromTop -= speed * CGFloat(now - last)
            last = now
        }
        return FrameStats(intervals: clock.stopRecording(), refreshMs: refreshMs)
    }
    r.scroll = await scrollUp(speed: o.scrollSpeed, seconds: 6)
    log(describe("scroll", r.scroll!))
    snapshot(renderer.view, to: o.out.appending(path: "\(renderer.name)-2-scrolled.png"))
    r.fling = await scrollUp(speed: o.flingSpeed, seconds: 4)
    log(describe("fling", r.fling!))

    // 4. Stream a long answer at the bottom, following it.
    scroller.toBottom()
    _ = await clock.nextFrame()
    let answer = corpus.answer(blocks: 28)
    renderer.beginStreaming()
    clock.startRecording()
    var sent = answer.startIndex
    var appendTimes: [Double] = []
    let start = await clock.nextFrame()
    var nextBatch = start
    while sent < answer.endIndex {
        let now = await clock.nextFrame()
        guard now >= nextBatch else { continue }
        nextBatch += 1 / o.streamBatchHz
        let due = min(answer.count, Int((now - start) * o.streamCharsPerSec))
        let target = answer.index(answer.startIndex, offsetBy: due)
        guard target > sent else { continue }
        let a = CACurrentMediaTime()
        renderer.append(String(answer[sent..<target]))
        appendTimes.append((CACurrentMediaTime() - a) * 1000)
        sent = target
        scroller.toBottom()
    }
    renderer.finishStreaming()
    r.stream = FrameStats(intervals: clock.stopRecording(), refreshMs: refreshMs)
    r.streamCharsPerSec = o.streamCharsPerSec
    r.streamAppendAvgMs = appendTimes.isEmpty ? 0 : appendTimes.reduce(0, +) / Double(appendTimes.count)
    r.streamAppendMaxMs = appendTimes.max() ?? 0
    log(describe("stream", r.stream!) + String(format: ", append avg %.2f ms max %.2f ms", r.streamAppendAvgMs, r.streamAppendMaxMs))
    scroller.toBottom()
    _ = await clock.nextFrame()
    _ = await clock.nextFrame()
    snapshot(renderer.view, to: o.out.appending(path: "\(renderer.name)-3-streamed.png"))
    r.footprintEndMB = footprintMB()
    write(r, o)
}

func describe(_ label: String, _ s: FrameStats) -> String {
    String(format: "%@: %d frames in %.1fs, p50 %.1f / p95 %.1f / p99 %.1f / max %.0f ms, hitch %.1f ms/s, dropped %.1f%%",
           label, s.frames, s.seconds, s.p50Ms, s.p95Ms, s.p99Ms, s.maxMs, s.hitchMsPerSec, s.droppedFraction * 100)
}

func write(_ r: LabResults, _ o: Options) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = o.out.appending(path: "results-\(r.renderer).json")
    try? enc.encode(r).write(to: url)
    print("wrote \(url.path)")
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled], reason: "TranscriptLab benchmark")
Task { @MainActor in
    await run(options)
    ProcessInfo.processInfo.endActivity(activity)
    exit(0)
}
app.run()
