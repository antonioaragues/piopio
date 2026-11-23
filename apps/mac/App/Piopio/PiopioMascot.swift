import PiopioKit
import SwiftUI

/// piopio, the chick perched on Home's box (docs/design/home): its mood (time of day or a special date), whether it's
/// awake, what it's saying, and where it looks. One for the app, so a morning nap ends once per session.
@MainActor @Observable
final class Piopio {
    static let shared = Piopio()

    private(set) var mood: PiopioMood = .at(.now)
    /// The outfit on the New agent page (docs/spec/18 §21); nil on Home, where the mood dresses it.
    private(set) var job: PiopioJob?
    /// Morning: asleep until tapped; then awake for the rest of the session.
    private(set) var woke = false
    private(set) var bubble: String?
    private(set) var hopStart: Date?
    /// The draft is changing: it looks down at the box and flaps.
    private(set) var typing = false
    /// Where it looks, in its own 120-unit drawing, and since when (eased over 0.18s from `lookFrom`).
    private(set) var look = CGVector.zero
    private(set) var lookFrom = CGVector.zero
    private(set) var lookChanged = Date.distantPast
    /// A hop or a glance is under way: drawn at full speed until it settles (`lively`).
    private(set) var stirred = false

    /// The pointer over Home, and the chick's centre, in Home's coordinate space.
    private var pointer: CGPoint?
    var center: CGPoint? { didSet { aim() } }

    private var bubbleTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private var pointerTask: Task<Void, Never>?
    private var stirTask: Task<Void, Never>?

    /// Something moves quickly (a hop, a glance, flapping while you type or it talks): drawn at 30 fps. Otherwise only
    /// the slow loops run (bob, blink, breath, the z's, periods of 2 to 5 s), and 10 fps draws them as smoothly for a
    /// third of the work (docs/research/memory-and-cpu.md §4b: at 30 fps Home cost 9.6% of a core).
    var lively: Bool { stirred || typing || bubble != nil }

    /// A chick with a job doesn't nap.
    var asleep: Bool { job == nil && mood == .morning && !woke }

    init(job: PiopioJob? = nil) {
        self.job = job
    }

    /// Puts on another job's outfit: it hops and says the job's line.
    func wear(_ job: PiopioJob) {
        guard job != self.job else { return }
        self.job = job
        hop(); say(job.line, for: 1.6)
    }

    /// Captures force a mood: PIOPIO_DEMO_MOOD=night (and so on).
    func refreshMood() {
        let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_MOOD"].flatMap(PiopioMood.init(rawValue:))
        let now = demo ?? .at(.now)
        if now != mood { mood = now }
    }

    func tap() {
        if let job {
            wear(job.next)
            return
        }
        if asleep {
            woke = true
            hop(); say(PiopioMood.wakeLine, for: 2)
            return
        }
        hop()
        say(mood.lines(name: HomeView.firstName, date: .now).randomElement() ?? "peep!")
    }

    /// The draft changed; typing ends 0.9s after the last change.
    func typed(_ text: String) {
        typing = !text.isEmpty
        aim()
        typingTask?.cancel()
        typingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.typing = false
            self?.aim()
        }
    }

    func sent() {
        typingTask?.cancel()
        typing = false
        woke = true
        hop(); say(PiopioMood.sendLine, for: 1.6)
        aim()
    }

    /// The pointer moved over Home: looked at about every 50ms, with the latest position.
    func pointer(_ point: CGPoint?) {
        pointer = point
        guard pointerTask == nil else { return }
        pointerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.pointerTask = nil
            self?.aim()
        }
    }

    private func hop() {
        hopStart = .now
        stir(for: 0.7)
    }

    /// Full speed for this long (a hop is 0.6 s, a glance 0.18 s), then the calm rate again.
    private func stir(for seconds: Double) {
        if !stirred { stirred = true }
        stirTask?.cancel()
        stirTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stirred = false
        }
    }

    private func say(_ text: String, for seconds: Double = 1.4) {
        withAnimation(.easeOut(duration: 0.22)) { bubble = text }
        bubbleTask?.cancel()
        bubbleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { self?.bubble = nil }
        }
    }

    /// Typing looks down at the box; otherwise toward the pointer, up to 3.4 units at 260pt away (y × 0.8).
    private func aim() {
        var target = CGVector.zero
        if typing {
            target = CGVector(dx: 0, dy: 3.6)
        } else if let pointer, let center {
            let dx = pointer.x - center.x, dy = pointer.y - center.y
            let d = max(1, hypot(dx, dy)), m = min(1, d / 260) * 3.4
            target = CGVector(dx: dx / d * m, dy: dy / d * m * 0.8)
        }
        guard abs(target.dx - look.dx) > 0.05 || abs(target.dy - look.dy) > 0.05 else { return }
        lookFrom = currentLook(at: .now)
        look = target
        lookChanged = .now
        stir(for: 0.3)
    }

    func currentLook(at time: Date) -> CGVector {
        let p = min(1, max(0, time.timeIntervalSince(lookChanged) / 0.18))
        let e = Ease.out(p)
        return CGVector(dx: lookFrom.dx + (look.dx - lookFrom.dx) * e, dy: lookFrom.dy + (look.dy - lookFrom.dy) * e)
    }
}

/// piopio on the box's top edge: the drawing, and its speech bubble above it. Tap it.
struct PiopioPerch: View {
    let model: Piopio
    var size: CGFloat = 47
    /// The bubble beside it, on its left, instead of above (the New agent page: hats reach where it would go).
    var bubbleBeside = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Inactive while another app is in front: it holds still, as no one is watching it (and it ran all day there).
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                // Hats, confetti and the hop reach past the 120-unit box, so the canvas is half as large again.
                TimelineView(.animation(minimumInterval: model.lively ? 1 / 30 : 1 / 10, paused: reduceMotion || activeState == .inactive)) { timeline in
                    PiopioDrawing(model: model, time: reduceMotion ? .distantPast : timeline.date, size: size, still: reduceMotion)
                }
                .frame(width: size * 1.5, height: size * 1.5)
                .allowsHitTesting(false)
            }
            .overlay(alignment: bubbleBeside ? .topTrailing : .top) {
                if let bubble = model.bubble {
                    Text(bubble)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dsInvFg)
                        .fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.dsInv, in: Capsule())
                        .alignmentGuide(.top) { bubbleBeside ? $0[.top] : $0[.bottom] + 2 }
                        .offset(x: bubbleBeside ? -size - 2 : 0, y: bubbleBeside ? size * 0.18 : 0)
                        .transition(.scale(scale: 0.6, anchor: bubbleBeside ? .trailing : .bottom).combined(with: .opacity))
                        .id(bubble)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Circle())
            .onTapGesture { model.tap() }
            .onGeometryChange(for: CGPoint.self) { proxy in
                let f = proxy.frame(in: .named(HomeView.space))
                return CGPoint(x: f.midX, y: f.midY)
            } action: { model.center = $0 }
            .help("piopio")
            .accessibilityElement()
            .accessibilityLabel("piopio")
            .accessibilityValue(model.bubble ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.tap() }
    }
}

enum Ease {
    static func out(_ x: Double) -> Double { 1 - (1 - x) * (1 - x) }
    static func `in`(_ x: Double) -> Double { x * x }
    /// 0 → 1 → 0 over one period, easing in and out (a CSS 0%/50%/100% loop).
    static func wave(_ t: Double, period: Double, delay: Double = 0) -> Double {
        let p = ((t - delay) / period).truncatingRemainder(dividingBy: 1)
        return (1 - cos(2 * .pi * (p < 0 ? p + 1 : p))) / 2
    }
    /// Where a loop of `period` seconds is, 0..<1 (nil before it starts).
    static func phase(_ t: Double, period: Double, delay: Double = 0) -> Double? {
        guard t >= delay else { return nil }
        return ((t - delay) / period).truncatingRemainder(dividingBy: 1)
    }
}

/// The drawing (docs/design/home, assets/piopio.svg): a 120-unit box, derived from the app icon. Round yellow body,
/// three-feather tuft, glossy eyes, coral cheeks, orange diamond beak, small wings and feet; asleep, a squat body with
/// closed eyes. Every motion is a function of the time, so the canvas only needs redrawing.
private struct PiopioDrawing: View {
    let model: Piopio
    let time: Date
    let size: CGFloat
    let still: Bool

    var body: some View {
        // Read here so SwiftUI redraws on changes even while the timeline is paused (reduce motion).
        let job = model.job, mood = job == nil ? model.mood : .afternoon
        let asleep = model.asleep, flapping = model.typing || model.bubble != nil
        let look = model.currentLook(at: still ? .now : time)
        let hop = model.hopStart.map { time.timeIntervalSince($0) }
        Canvas { context, _ in
            let t = still ? 0 : time.timeIntervalSinceReferenceDate
            let s = size / 120
            context.translateBy(x: size * 0.25, y: size * 0.25)
            context.scaleBy(x: s, y: s)
            if asleep {
                Self.drawAsleep(&context, t: t)
            } else {
                // Bob (2.5pt) and the hop (16pt): points, so divided by the scale; the hop squashes from the feet.
                let bob = still ? 0 : -2.5 * Ease.wave(t, period: mood == .night ? 4.6 : 3.4)
                let h = still ? nil : hop.flatMap(Self.hop)
                context.translateBy(x: 0, y: (bob + (h?.y ?? 0)) / s)
                if let h { Self.scale(&context, h.sx, h.sy, around: CGPoint(x: 60, y: 114)) }
                Self.drawAwake(&context, mood: mood, job: job, t: t, look: look, flapping: flapping && !still)
                if let job {
                    // A new outfit pops on with the hop.
                    let pop = still ? 1 : hop.map { min(1, max(0, $0 / 0.4)) } ?? 1
                    Self.drawJob(&context, job, t: still ? 0 : t, look: look, pop: pop)
                }
            }
        }
    }

    // MARK: Motion

    /// The hop: 0.6s, squash, rise 16pt stretched, land squashed, rest (each step eases out).
    static func hop(_ elapsed: Double) -> (y: Double, sx: Double, sy: Double)? {
        guard elapsed >= 0, elapsed < 0.6 else { return nil }
        let keys: [(t: Double, y: Double, sx: Double, sy: Double)] = [(0, 0, 1, 1), (0.18, 0, 1.1, 0.86), (0.48, -16, 0.94, 1.07), (0.78, 0, 1.08, 0.92), (1, 0, 1, 1)]
        let p = elapsed / 0.6
        let i = keys.lastIndex { $0.t <= p } ?? 0
        let a = keys[i], b = keys[min(i + 1, keys.count - 1)]
        let e = b.t > a.t ? Ease.out((p - a.t) / (b.t - a.t)) : 1
        return (a.y + (b.y - a.y) * e, a.sx + (b.sx - a.sx) * e, a.sy + (b.sy - a.sy) * e)
    }

    /// Eyes close at 96% of the loop.
    static func blink(_ t: Double, period: Double) -> Double {
        guard let p = Ease.phase(t, period: period) else { return 1 }
        if p < 0.93 { return 1 }
        if p < 0.96 { return 1 - 0.92 * Ease.out((p - 0.93) / 0.03) }
        return 0.08 + 0.92 * Ease.out((p - 0.96) / 0.04)
    }

    /// A "z" or a heart floating up: fades in by 30%, out by the end, drifting (8, −18).
    static func float(_ t: Double, period: Double, delay: Double) -> (opacity: Double, dx: Double, dy: Double)? {
        guard let p = Ease.phase(t, period: period, delay: delay) else { return nil }
        let opacity = p < 0.3 ? Ease.out(p / 0.3) : 1 - Ease.out((p - 0.3) / 0.7)
        let e = Ease.out(p)
        return (opacity, 8 * e, 4 - 18 * e)
    }

    static func scale(_ c: inout GraphicsContext, _ sx: Double, _ sy: Double, around p: CGPoint) {
        c.translateBy(x: p.x, y: p.y)
        c.scaleBy(x: sx, y: sy)
        c.translateBy(x: -p.x, y: -p.y)
    }

    static func rotate(_ c: inout GraphicsContext, _ degrees: Double, around p: CGPoint) {
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: .degrees(degrees))
        c.translateBy(x: -p.x, y: -p.y)
    }

    // MARK: Awake

    static func drawAwake(_ c: inout GraphicsContext, mood: PiopioMood, job: PiopioJob?, t: Double, look: CGVector, flapping: Bool) {
        c.fill(ellipse(60, 114, 30, 3.5), with: .color(.black.opacity(0.08)))
        var feet = Path()
        for x in [47.0, 73.0] {
            for dx in [-4.0, 0, 4] { feet.move(to: CGPoint(x: x, y: 108)); feet.addLine(to: CGPoint(x: x + dx, y: dx == 0 ? 115 : 114)) }
        }
        c.stroke(feet, with: .color(Palette.feet), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        if !(job?.hatted ?? mood.hatted) {
            var tuft = c
            rotate(&tuft, -4 + 9 * Ease.wave(t, period: 3.2), around: CGPoint(x: 60, y: 32))
            tuft.fill(curve(56, 30, [(50, 18, 46, 14, 40, 14), (46, 20, 49, 26, 52, 32)]), with: .color(Palette.tuftSide))
            tuft.fill(curve(60, 29, [(59, 15, 60, 8, 64, 4), (65, 14, 65, 22, 64, 30)]), with: .color(Palette.tuftMiddle))
            tuft.fill(curve(64, 31, [(70, 20, 76, 17, 82, 18), (75, 23, 71, 28, 68, 34)]), with: .color(Palette.tuftSide))
        }

        let flap = flapping ? 28 * Ease.wave(t, period: 0.22) : 0
        var left = c
        rotate(&left, flap, around: CGPoint(x: 24, y: 66))
        left.fill(ellipse(18, 76, 9, 15, rotation: 25), with: .color(Palette.wing))
        var right = c
        rotate(&right, -flap, around: CGPoint(x: 96, y: 66))
        right.fill(ellipse(102, 76, 9, 15, rotation: -25), with: .color(Palette.wing))

        c.fill(ellipse(60, 68, 44, 42), with: Palette.body(center: CGPoint(x: 51.2, y: 52.9), radius: 64))
        c.fill(ellipse(44, 48, 14, 8, rotation: -25), with: .color(.white.opacity(0.28)))

        // The face follows the pointer: cheeks by half, eyes by all of it, the beak by 0.8.
        var face = c
        face.translateBy(x: look.dx * 0.5, y: look.dy * 0.5)
        if mood == .valentine {
            face.fill(heart(31, 77, 1.1), with: .color(Palette.valentine))
            face.fill(heart(89, 77, 1.1), with: .color(Palette.valentine))
        } else {
            face.fill(ellipse(31, 77, 8, 5), with: .color(Palette.cheek.opacity(0.75)))
            face.fill(ellipse(89, 77, 8, 5), with: .color(Palette.cheek.opacity(0.75)))
        }
        var eyes = face
        eyes.translateBy(x: look.dx * 0.5, y: look.dy * 0.5)
        let sleepy = mood == .night
        let blink = blink(t, period: sleepy ? 3.2 : 4.6)
        for cx in [42.0, 78.0] {
            var eye = eyes
            scale(&eye, 1, blink, around: CGPoint(x: cx, y: 62))
            if sleepy {
                eye.fill(lowerHalf(cx, 62, 6.5), with: .color(Palette.eye))
                eye.stroke(line(cx - 7.5, 61.5, cx + 7.5, 61.5), with: .color(Palette.eye), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                eye.fill(ellipse(cx, 62, 6.5, 6.5), with: .color(Palette.eye))
                eye.fill(ellipse(cx + 2, 59.5, 2.2, 2.2), with: .color(.white))
            }
        }
        var beak = face
        beak.translateBy(x: look.dx * 0.3, y: look.dy * 0.3)
        beak.fill(polygon([(51, 72), (60, 64), (69, 72), (60, 82)]), with: Palette.beak(top: 64, bottom: 82))
        beak.fill(polygon([(51, 72), (60, 64), (69, 72), (60, 74)]), with: .color(Palette.beakTop))

        if job == nil { drawAccessories(&c, mood: mood, t: t) }
    }

    // MARK: Jobs

    /// Each job's outfit (docs/spec/18 §21): something on the head, something in a wing. `pop` (0…1) is how far the
    /// outfit has popped on since the hop; what's held sways a little.
    static func drawJob(_ c: inout GraphicsContext, _ job: PiopioJob, t: Double, look: CGVector, pop: Double) {
        let ink = Color(hex: 0x3A2A20), paper = Color.white, rule = Color(hex: 0xC9C9C4)
        let sway = -8 * Ease.wave(t, period: 1.6)
        /// Scales a part in from nothing, overshooting a little, around its own centre.
        func popped(_ center: CGPoint, delay: Double = 0, _ draw: (inout GraphicsContext) -> Void) {
            let p = min(1, max(0, (pop - delay) / (1 - delay)))
            guard p > 0 else { return }
            var g = c
            let k = Ease.out(p) * (1 + 0.18 * sin(p * .pi))
            g.opacity = min(1, p * 2)
            scale(&g, k, k, around: center)
            draw(&g)
        }
        /// Something held in a wing: pops in, then sways from where it's held.
        func held(_ pivot: CGPoint, _ draw: @escaping (inout GraphicsContext) -> Void) {
            popped(pivot, delay: 0.15) { g in
                rotate(&g, sway, around: pivot)
                draw(&g)
            }
        }
        let thin = StrokeStyle(lineWidth: 1.2), round = { (w: Double) in StrokeStyle(lineWidth: w, lineCap: .round) }

        switch job {
        case .secretary:
            // Glasses on the eyes, so they follow the look.
            popped(CGPoint(x: 60, y: 62)) { g in
                g.translateBy(x: look.dx, y: look.dy)
                for cx in [42.0, 78.0] {
                    g.fill(ellipse(cx, 62, 10, 10), with: .color(.white.opacity(0.18)))
                    g.stroke(ellipse(cx, 62, 10, 10), with: .color(ink), lineWidth: 2.2)
                }
                var bridge = Path()
                bridge.move(to: CGPoint(x: 52, y: 61)); bridge.addQuadCurve(to: CGPoint(x: 68, y: 61), control: CGPoint(x: 60, y: 57))
                g.stroke(bridge, with: .color(ink), lineWidth: 2.2)
            }
            held(CGPoint(x: 14, y: 96)) { g in
                rotate(&g, -10, around: CGPoint(x: 14, y: 85))
                let pad = Path(roundedRect: CGRect(x: 2, y: 70, width: 24, height: 30), cornerRadius: 2.5)
                g.fill(pad, with: .color(paper)); g.stroke(pad, with: .color(rule), style: thin)
                var lines = Path()
                for (y, w) in [(79.0, 14.0), (85, 14), (91, 9)] { lines.addPath(line(7, y, 7 + w, y)) }
                g.stroke(lines, with: .color(Color(hex: 0x9BB4D6)), style: round(1.5))
            }
            held(CGPoint(x: 100, y: 92)) { g in
                g.stroke(line(100, 92, 114, 64), with: .color(Color(hex: 0xF2A93B)), style: round(5))
                g.stroke(line(114, 64, 116, 59), with: .color(Color(hex: 0xF4B6B0)), style: round(5))
                g.stroke(line(100, 92, 99, 96), with: .color(ink), style: round(2))
            }
        case .doctor:
            popped(CGPoint(x: 60, y: 34)) { g in
                var band = Path()
                band.move(to: CGPoint(x: 22, y: 48)); band.addQuadCurve(to: CGPoint(x: 98, y: 48), control: CGPoint(x: 60, y: 24))
                g.stroke(band, with: .color(Color(hex: 0x7E8A94)), lineWidth: 3)
                g.fill(ellipse(60, 33, 10, 10), with: .color(Color(hex: 0xE7ECEF)))
                g.stroke(ellipse(60, 33, 10, 10), with: .color(Color(hex: 0x8D99A3)), lineWidth: 2)
                g.fill(ellipse(60, 33, 3.5, 3.5), with: .color(Color(hex: 0xB8C2C9)))
                g.fill(ellipse(56, 29, 3, 1.6), with: .color(.white.opacity(0.9)))
            }
            popped(CGPoint(x: 60, y: 100), delay: 0.1) { g in
                var tube = Path()
                tube.move(to: CGPoint(x: 34, y: 90)); tube.addQuadCurve(to: CGPoint(x: 60, y: 106), control: CGPoint(x: 36, y: 108))
                tube.addQuadCurve(to: CGPoint(x: 86, y: 90), control: CGPoint(x: 84, y: 108))
                g.stroke(tube, with: .color(Color(hex: 0x4E5A64)), style: round(2.6))
                g.fill(ellipse(60, 106, 5.5, 5.5), with: .color(Color(hex: 0xC7D0D6)))
                g.stroke(ellipse(60, 106, 5.5, 5.5), with: .color(Color(hex: 0x4E5A64)), lineWidth: 2)
            }
            held(CGPoint(x: 96, y: 100)) { g in
                let kit = Path(roundedRect: CGRect(x: 88, y: 84, width: 16, height: 16), cornerRadius: 3)
                g.fill(kit, with: .color(paper)); g.stroke(kit, with: .color(Color(hex: 0xE2E2DE)), lineWidth: 1)
                var cross = line(96, 87, 96, 97); cross.addPath(line(91, 92, 101, 92))
                g.stroke(cross, with: .color(Color(hex: 0xD9473C)), style: round(3))
            }
        case .detective:
            popped(CGPoint(x: 60, y: 30)) { g in
                var dome = Path()
                dome.move(to: CGPoint(x: 20, y: 44))
                dome.addCurve(to: CGPoint(x: 100, y: 44), control1: CGPoint(x: 18, y: 6), control2: CGPoint(x: 102, y: 6))
                dome.addQuadCurve(to: CGPoint(x: 20, y: 44), control: CGPoint(x: 60, y: 34))
                g.fill(dome, with: .color(Color(hex: 0x8B6A47)))
                var check = g
                check.clip(to: dome)
                var lines = Path()
                for (a, b) in [((30.0, 22.0), (90.0, 22.0)), ((24, 32), (96, 32)), ((44, 12), (40, 40)), ((60, 9), (60, 37)), ((76, 12), (80, 40))] { lines.addPath(line(a.0, a.1, b.0, b.1)) }
                check.stroke(lines, with: .color(Color(hex: 0x6E5236).opacity(0.7)), lineWidth: 1.6)
                var brim = Path()
                brim.move(to: CGPoint(x: 22, y: 44))
                brim.addQuadCurve(to: CGPoint(x: 98, y: 44), control: CGPoint(x: 60, y: 32))
                brim.addQuadCurve(to: CGPoint(x: 92, y: 50), control: CGPoint(x: 100, y: 50))
                brim.addQuadCurve(to: CGPoint(x: 28, y: 50), control: CGPoint(x: 60, y: 42))
                brim.addQuadCurve(to: CGPoint(x: 22, y: 44), control: CGPoint(x: 20, y: 50))
                g.fill(brim, with: .color(Color(hex: 0x6E5236)))
                g.stroke(line(60, 17, 60, 11), with: .color(Color(hex: 0x6E5236)), style: round(3))
            }
            held(CGPoint(x: 110, y: 90)) { g in
                let wood = Color(hex: 0x5A4632)
                g.stroke(line(106, 82, 116, 98), with: .color(wood), style: round(5))
                g.fill(ellipse(100, 72, 12, 12), with: .color(Color(hex: 0xD9ECFA).opacity(0.55)))
                g.stroke(ellipse(100, 72, 12, 12), with: .color(wood), lineWidth: 3.2)
                var glint = Path()
                glint.move(to: CGPoint(x: 94, y: 67)); glint.addQuadCurve(to: CGPoint(x: 101, y: 64), control: CGPoint(x: 97, y: 64))
                g.stroke(glint, with: .color(.white), style: round(2))
            }
        case .chef:
            popped(CGPoint(x: 60, y: 24)) { g in
                let parts = [ellipse(44, 16, 13, 13), ellipse(76, 16, 13, 13), ellipse(60, 8, 15, 15), Path(roundedRect: CGRect(x: 36, y: 16, width: 48, height: 20), cornerRadius: 4)]
                let toque = parts.dropFirst().reduce(parts[0]) { Path($0.cgPath.union($1.cgPath)) }
                g.fill(toque, with: .color(paper))
                g.stroke(toque, with: .color(Color(hex: 0xE2E2DE)), lineWidth: 1.2)
                var pleats = Path()
                for (x, top) in [(48.0, 22.0), (60, 20), (72, 22)] { pleats.addPath(line(x, top, x, 32)) }
                g.stroke(pleats, with: .color(Color(hex: 0xEDEDEA)), lineWidth: 2)
            }
            held(CGPoint(x: 102, y: 96)) { g in
                let wood = Color(hex: 0xB9874E)
                g.stroke(line(107, 72, 101, 98), with: .color(wood), style: round(3.5))
                g.fill(ellipse(108, 66, 6, 8), with: .color(wood))
            }
        case .mailCarrier:
            popped(CGPoint(x: 60, y: 30)) { g in
                var cap = Path()
                cap.move(to: CGPoint(x: 22, y: 42))
                cap.addCurve(to: CGPoint(x: 98, y: 42), control1: CGPoint(x: 22, y: 12), control2: CGPoint(x: 98, y: 12))
                cap.addQuadCurve(to: CGPoint(x: 22, y: 42), control: CGPoint(x: 60, y: 34))
                g.fill(cap, with: .color(Color(hex: 0x2F5D9E)))
                var visor = Path()
                visor.move(to: CGPoint(x: 58, y: 40))
                visor.addQuadCurve(to: CGPoint(x: 104, y: 44), control: CGPoint(x: 86, y: 34))
                visor.addQuadCurve(to: CGPoint(x: 58, y: 44), control: CGPoint(x: 84, y: 48))
                g.fill(visor, with: .color(Color(hex: 0x244A7F)))
                g.fill(ellipse(60, 26, 5, 5), with: .color(Color(hex: 0xF2C94C)))
            }
            held(CGPoint(x: 12, y: 95)) { g in
                rotate(&g, -12, around: CGPoint(x: 12, y: 83))
                let envelope = Path(roundedRect: CGRect(x: -2, y: 74, width: 28, height: 19), cornerRadius: 2)
                g.fill(envelope, with: .color(paper)); g.stroke(envelope, with: .color(rule), style: thin)
                var flap = Path()
                flap.move(to: CGPoint(x: -1, y: 76)); flap.addLine(to: CGPoint(x: 12, y: 86)); flap.addLine(to: CGPoint(x: 25, y: 76))
                g.stroke(flap, with: .color(rule), style: thin)
                g.fill(ellipse(12, 88, 3, 3), with: .color(Color(hex: 0xD9473C)))
            }
        case .coach:
            popped(CGPoint(x: 60, y: 40)) { g in
                var band = Path()
                band.move(to: CGPoint(x: 21, y: 46)); band.addQuadCurve(to: CGPoint(x: 99, y: 46), control: CGPoint(x: 60, y: 22))
                band.addLine(to: CGPoint(x: 98, y: 54)); band.addQuadCurve(to: CGPoint(x: 22, y: 54), control: CGPoint(x: 60, y: 31))
                band.closeSubpath()
                g.fill(band, with: .color(Color(hex: 0xE05A47)))
                var stripe = Path()
                stripe.move(to: CGPoint(x: 22, y: 50)); stripe.addQuadCurve(to: CGPoint(x: 98, y: 50), control: CGPoint(x: 60, y: 27))
                g.stroke(stripe, with: .color(.white), lineWidth: 1.8)
            }
            popped(CGPoint(x: 60, y: 98), delay: 0.1) { g in
                var cord = Path()
                cord.move(to: CGPoint(x: 36, y: 90)); cord.addQuadCurve(to: CGPoint(x: 58, y: 100), control: CGPoint(x: 48, y: 104))
                cord.move(to: CGPoint(x: 84, y: 90)); cord.addQuadCurve(to: CGPoint(x: 62, y: 100), control: CGPoint(x: 72, y: 104))
                g.stroke(cord, with: .color(Color(hex: 0x2F5D9E)), lineWidth: 2)
                let whistle = Path(roundedRect: CGRect(x: 52, y: 98, width: 18, height: 9), cornerRadius: 4.5)
                g.fill(whistle, with: .color(Color(hex: 0xC7D0D6)))
                g.stroke(whistle, with: .color(Color(hex: 0x6B7780)), lineWidth: 1.5)
                g.fill(ellipse(56, 102.5, 2.2, 2.2), with: .color(Color(hex: 0x6B7780)))
            }
        }
    }

    static func drawAccessories(_ c: inout GraphicsContext, mood: PiopioMood, t: Double) {
        switch mood {
        case .night:
            floppyCap(&c, cap: Color(hex: 0x7E95DA), brim: Color(hex: 0xEEF1FB))
            for (x, y) in [(50.0, 22.0), (68, 14), (82, 22)] { c.fill(ellipse(x, y, 2, 2), with: .color(Color(hex: 0xEEF1FB).opacity(0.8))) }
        case .christmas:
            floppyCap(&c, cap: Color(hex: 0xE0453A), brim: .white)
            c.fill(ellipse(60, 104, 34, 7), with: .color(Color(hex: 0x2F8F5B)))
            c.fill(Path(roundedRect: CGRect(x: 70, y: 102, width: 10, height: 18), cornerRadius: 4), with: .color(Color(hex: 0x2F8F5B)))
        case .halloween:
            var cone = Path()
            cone.move(to: CGPoint(x: 38, y: 34)); cone.addLine(to: CGPoint(x: 56, y: -8))
            cone.addQuadCurve(to: CGPoint(x: 66, y: -6), control: CGPoint(x: 62, y: -14))
            cone.addLine(to: CGPoint(x: 82, y: 34)); cone.closeSubpath()
            c.fill(cone, with: .color(Color(hex: 0x4A3763)))
            c.fill(Path(CGRect(x: 40, y: 24, width: 40, height: 7)), with: .color(Color(hex: 0xF08A2E)))
            c.fill(ellipse(60, 35, 46, 7), with: .color(Color(hex: 0x3B2B4F)))
        case .newYear:
            c.fill(polygon([(44, 34), (62, -6), (78, 34)]), with: .color(Palette.gold))
            var stripes = Path()
            for (a, b) in [((50.0, 22.0), (72.0, 18.0)), ((47, 30), (76, 26)), ((54, 12), (68, 9))] { stripes.addPath(line(a.0, a.1, b.0, b.1)) }
            c.stroke(stripes, with: .color(Palette.valentine), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            c.fill(ellipse(62, -6, 5, 5), with: .color(Palette.valentine))
            let colors = [Palette.gold, Palette.valentine, Color(hex: 0x5BB6F0), Color(hex: 0x7AD39A)]
            for (i, (x, y)) in [(14.0, 10.0), (100, 4), (24, 40), (108, 46), (6, 70), (114, 84), (86, -4)].enumerated() {
                guard let p = Ease.phase(t, period: 2.2 + Double(i) * 0.3, delay: Double(i) * 0.35) else { continue }
                let e = Ease.in(p)
                var bit = c
                bit.opacity = p < 0.15 ? p / 0.15 : 1 - (p - 0.15) / 0.85
                bit.translateBy(x: 0, y: -8 + 30 * e)
                rotate(&bit, 220 * e, around: CGPoint(x: x + 2.5, y: y + 4))
                bit.fill(Path(roundedRect: CGRect(x: x, y: y, width: 5, height: 8), cornerRadius: 1), with: .color(colors[i % 4]))
            }
        case .valentine:
            for (cx, cy, scale, color, delay) in [(18.0, 30.0, 0.9, Palette.valentine, 0.0), (102, 22, 0.7, Color(hex: 0xFF9CAB), 1.5)] {
                guard let f = float(t, period: 3, delay: delay) else { continue }
                var h = c
                h.opacity = f.opacity
                h.translateBy(x: f.dx, y: f.dy - 4)
                h.fill(heart(cx, cy, scale), with: .color(color))
            }
        case .morning, .afternoon:
            break
        }
    }

    static func floppyCap(_ c: inout GraphicsContext, cap: Color, brim: Color) {
        c.fill(curve(28, 40, [(32, 14, 58, 0, 84, 4), (98, 6, 106, 16, 108, 30), (100, 22, 92, 20, 86, 22), (90, 28, 92, 34, 92, 40)]), with: .color(cap))
        c.fill(Path(roundedRect: CGRect(x: 24, y: 33, width: 72, height: 11), cornerRadius: 5.5), with: .color(brim))
        c.fill(ellipse(108, 32, 6.5, 6.5), with: .color(brim))
    }

    // MARK: Asleep

    static func drawAsleep(_ c: inout GraphicsContext, t: Double) {
        c.fill(ellipse(60, 112, 40, 4), with: .color(.black.opacity(0.08)))
        var body = c
        let breath = Ease.wave(t, period: 3.6)
        scale(&body, 1 + 0.025 * breath, 1 - 0.035 * breath, around: CGPoint(x: 60, y: 112))
        body.fill(curve(58, 40, [(54, 30, 50, 27, 45, 27), (50, 32, 52, 36, 54, 42)]), with: .color(Palette.tuftSide))
        body.fill(curve(62, 39, [(66, 30, 71, 28, 76, 29), (70, 33, 67, 37, 65, 43)]), with: .color(Palette.tuftSide))
        body.fill(ellipse(60, 78, 46, 34), with: Palette.body(center: CGPoint(x: 50.8, y: 65.8), radius: 60))
        body.fill(ellipse(44, 58, 14, 7, rotation: -20), with: .color(.white.opacity(0.28)))
        var eyes = Path()
        for x in [36.0, 72.0] { eyes.move(to: CGPoint(x: x, y: 72)); eyes.addQuadCurve(to: CGPoint(x: x + 12, y: 72), control: CGPoint(x: x + 6, y: 77)) }
        body.stroke(eyes, with: .color(Palette.eye), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        body.fill(ellipse(31, 84, 8, 5), with: .color(Palette.cheek.opacity(0.65)))
        body.fill(ellipse(89, 84, 8, 5), with: .color(Palette.cheek.opacity(0.65)))
        body.fill(polygon([(53, 80), (60, 74), (67, 80), (60, 88)]), with: Palette.beak(top: 74, bottom: 88))
        body.fill(polygon([(53, 80), (60, 74), (67, 80), (60, 82)]), with: .color(Palette.beakTop))
        // Two z's floating up, 1.4s apart.
        for (x, y, size, color, delay) in [(92.0, 40.0, 14.0, Color(hex: 0xB9B6AE), 0.0), (100, 28, 10, Color(hex: 0xCFCCC4), 1.4)] {
            guard let f = float(t, period: 2.8, delay: delay) else { continue }
            var z = c
            z.opacity = f.opacity
            z.draw(Text("z").font(.system(size: size, weight: .bold)).foregroundStyle(color), at: CGPoint(x: x + f.dx, y: y + f.dy - 4), anchor: .bottomLeading)
        }
    }

    // MARK: Shapes

    static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, rotation: Double = 0) -> Path {
        let path = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        guard rotation != 0 else { return path }
        let turn = CGAffineTransform(translationX: cx, y: cy).rotated(by: rotation * .pi / 180).translatedBy(x: -cx, y: -cy)
        return path.applying(turn)
    }

    /// An SVG "M x y C … C … Z".
    static func curve(_ x: Double, _ y: Double, _ curves: [(Double, Double, Double, Double, Double, Double)]) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x, y: y))
        for c in curves { p.addCurve(to: CGPoint(x: c.4, y: c.5), control1: CGPoint(x: c.0, y: c.1), control2: CGPoint(x: c.2, y: c.3)) }
        p.closeSubpath()
        return p
    }

    static func polygon(_ points: [(Double, Double)]) -> Path {
        var p = Path()
        p.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        p.closeSubpath()
        return p
    }

    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2))
        return p
    }

    /// The lower half of a circle (the night's half-closed eye).
    static func lowerHalf(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
        let k = 0.5523 * r
        var p = Path()
        p.move(to: CGPoint(x: cx - r, y: cy))
        p.addCurve(to: CGPoint(x: cx, y: cy + r), control1: CGPoint(x: cx - r, y: cy + k), control2: CGPoint(x: cx - k, y: cy + r))
        p.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + k, y: cy + r), control2: CGPoint(x: cx + r, y: cy + k))
        p.closeSubpath()
        return p
    }

    static func heart(_ cx: Double, _ cy: Double, _ s: Double) -> Path {
        curve(cx, cy + 4 * s, [(cx - 8 * s, cy - 2 * s, cx - 4 * s, cy - 8 * s, cx, cy - 3 * s), (cx + 4 * s, cy - 8 * s, cx + 8 * s, cy - 2 * s, cx, cy + 4 * s)])
    }
}

/// The chick's own colours: the same in light and dark (it's the app icon's bird).
private enum Palette {
    static let feet = Color(hex: 0xEE7A30)
    static let tuftSide = Color(hex: 0xF7C11E)
    static let tuftMiddle = Color(hex: 0xFBCB22)
    static let wing = Color(hex: 0xF2B415)
    static let eye = Color(hex: 0x2B1D14)
    static let cheek = Color(hex: 0xFF8466)
    static let beakTop = Color(hex: 0xFFB86B)
    static let valentine = Color(hex: 0xFF6B81)
    static let gold = Color(hex: 0xF4B63F)

    static func body(center: CGPoint, radius: Double) -> GraphicsContext.Shading {
        .radialGradient(Gradient(stops: [.init(color: Color(hex: 0xFFEA5C), location: 0), .init(color: Color(hex: 0xFBCB22), location: 0.6), .init(color: Color(hex: 0xEFA80E), location: 1)]),
                        center: center, startRadius: 0, endRadius: radius)
    }

    static func beak(top: Double, bottom: Double) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [Color(hex: 0xFFA857), Color(hex: 0xEE6F2B)]), startPoint: CGPoint(x: 60, y: top), endPoint: CGPoint(x: 60, y: bottom))
    }
}

extension Color {
    /// 0xRRGGBB in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
