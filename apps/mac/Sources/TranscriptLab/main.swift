import AppKit
import PiopioKit

// TranscriptLab: Spike S2. Can a native transcript render streaming markdown smoothly at 2,000 items?
//
//   swift run -c release TranscriptLab --renderer swiftui|swiftui-list|textkit|textkit-cards|textkit-cards-swiftui [--items 2000] [--out dir]
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
    var only: String?                  // "load": stop after the load scenario

    init(_ args: [String]) {
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--renderer": renderer = it.next() ?? renderer
            case "--items": items = Int(it.next() ?? "") ?? items
            case "--out": out = URL(fileURLWithPath: it.next() ?? out.path)
            case "--only": only = it.next()
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
    case "textkit-cards": TextKitCardsRenderer(cardViews: .appkit)
    case "textkit-cards-swiftui": TextKitCardsRenderer(cardViews: .swiftui)
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

    // 1. Load and show the bottom (progressively for the cards renderer).
    let t0 = CACurrentMediaTime()
    if let cards = renderer as? TextKitCardsRenderer {
        let backfill = await cards.loadProgressively(items)
        _ = await clock.nextFrame()
        r.tailToFrameMs = (CACurrentMediaTime() - t0) * 1000
        clock.startRecording()
        await backfill.value
        _ = await clock.nextFrame()
        r.backfill = FrameStats(intervals: clock.stopRecording(), refreshMs: refreshMs)
        r.backfillTotalMs = (CACurrentMediaTime() - t0) * 1000
        r.prependMaxMs = cards.prependCosts.max()
        log(String(format: "tail on screen in %.0f ms, full history in %.0f ms (prepend max %.1f ms); ", r.tailToFrameMs!, r.backfillTotalMs!, r.prependMaxMs ?? 0) + describe("backfill", r.backfill!))
    } else {
        renderer.load(items)
    }
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
    if o.only == "load" {
        write(r, o)
        return
    }

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
    if let cards = renderer as? TextKitCardsRenderer, !cards.pageCosts.isEmpty {
        r.pageLoads = cards.pageCosts.count
        r.pageLoadAvgMs = cards.pageCosts.reduce(0, +) / Double(cards.pageCosts.count)
        r.pageLoadMaxMs = cards.pageCosts.max()
        r.pageAnchorDriftChars = cards.maxAnchorDrift
        log(String(format: "on-demand pages: %d, avg %.1f ms, max %.1f ms, max anchor drift %d chars", r.pageLoads!, r.pageLoadAvgMs!, r.pageLoadMaxMs!, r.pageAnchorDriftChars!))
    }

    // 3b. Expand and collapse the last tool cards (attachment views relayout in place).
    if let cards = renderer as? TextKitCardsRenderer {
        scroller.toBottom()
        _ = await clock.nextFrame()
        let targets = cards.lastCards(8)
        var costs: [Double] = []
        clock.startRecording()
        for pass in 0..<2 {
            for card in targets {
                let a = CACurrentMediaTime()
                card.expanded = pass == 0
                cards.relayout(card)
                costs.append((CACurrentMediaTime() - a) * 1000)
                for _ in 0..<6 { _ = await clock.nextFrame() }
            }
        }
        r.toggle = FrameStats(intervals: clock.stopRecording(), refreshMs: refreshMs)
        targets.first?.expanded = true
        cards.relayout(targets[0])
        _ = await clock.nextFrame()
        snapshot(renderer.view, to: o.out.appending(path: "\(renderer.name)-2b-expanded.png"))
        targets.first?.expanded = false
        cards.relayout(targets[0])
        r.toggleAvgMs = costs.reduce(0, +) / Double(max(1, costs.count))
        r.toggleMaxMs = costs.max()
        log(describe("toggle", r.toggle!) + String(format: ", relayout avg %.2f ms max %.2f ms", r.toggleAvgMs!, r.toggleMaxMs!))
    }

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

    // 5. One very long answer (~60k chars) streamed fast into a single message.
    let long = corpus.answer(blocks: 250)
    let longStats = await streamAnswer(long, charsPerSec: 3000)
    r.longStream = longStats.frames
    r.longStreamChars = long.count
    r.longStreamAppendAvgMs = longStats.avgMs
    r.longStreamAppendMaxMs = longStats.maxMs
    log(describe("long stream (\(long.count) chars)", longStats.frames) + String(format: ", append avg %.2f ms max %.2f ms", longStats.avgMs, longStats.maxMs))
    snapshot(renderer.view, to: o.out.appending(path: "\(renderer.name)-4-long.png"))

    r.footprintEndMB = footprintMB()
    write(r, o)

    func streamAnswer(_ text: String, charsPerSec: Double) async -> (frames: FrameStats, avgMs: Double, maxMs: Double) {
        scroller.toBottom()
        _ = await clock.nextFrame()
        renderer.beginStreaming()
        clock.startRecording()
        var sent = text.startIndex
        var times: [Double] = []
        let start = await clock.nextFrame()
        var nextBatch = start
        while sent < text.endIndex {
            let now = await clock.nextFrame()
            guard now >= nextBatch else { continue }
            nextBatch += 1 / o.streamBatchHz
            let due = min(text.count, Int((now - start) * charsPerSec))
            let target = text.index(text.startIndex, offsetBy: due)
            guard target > sent else { continue }
            let a = CACurrentMediaTime()
            renderer.append(String(text[sent..<target]))
            times.append((CACurrentMediaTime() - a) * 1000)
            sent = target
            scroller.toBottom()
        }
        renderer.finishStreaming()
        let frames = FrameStats(intervals: clock.stopRecording(), refreshMs: refreshMs)
        return (frames, times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count), times.max() ?? 0)
    }
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
