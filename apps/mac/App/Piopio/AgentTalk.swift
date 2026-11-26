import PiopioKit
import PiopioTranscript
import SwiftUI

// Making an agent by talking (docs/spec/21 D4, design 5a): answers to tap while it learns its job, the card it shows
// when it "comes alive", and a trial run.

/// Answers to tap, above the composer: a new agent's three ideas, or the options of the question it just asked.
/// They go once you answer (by tapping or in your own words).
struct AgentQuickReplies: View {
    let thread: ThreadModel

    var body: some View {
        _ = thread.revision
        let options = Self.options(thread.document.items)
        return Group {
            if !options.isEmpty, !thread.isRunning {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { Task { await thread.send(option) } }
                                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.dsFg)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Color.dsCard, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: DS.column)
            }
        }
    }

    /// The newest question's options (`ask_owner`) or the greeting's ideas, unless you've answered since.
    static func options(_ items: [TimelineItem]) -> [String] {
        for item in items.reversed() {
            switch item {
            case .user: return []
            case .tool(let t) where t.tool == "ask_owner" && t.status != .error:
                guard case .array(let list)? = t.args["options"] else { return [] }
                return list.compactMap(\.stringValue)
            case .assistant(let a):
                if let s = a.outbound?.suggestions, !s.isEmpty { return s }
            default: continue
            }
        }
        return []
    }

    /// "Question 2 of 3", while it's asking.
    static func question(_ items: [TimelineItem]) -> String? {
        for item in items.reversed() {
            switch item {
            case .user: return nil
            case .tool(let t) where t.tool == "ask_owner" && t.status != .error:
                if case .number(let n)? = t.args["number"] { return "Question \(Int(n)) of 3" }
                return nil
            default: continue
            }
        }
        return nil
    }
}

/// The card a new agent shows once it has set itself up (design 5a-3): who it is and what was decided, with what
/// needs your OK marked. "Looks good" closes it and offers nothing more to do than watch a trial run.
struct AgentIdentityCard: View {
    let engine: EngineController
    let summary: SessionSummary
    let def: AgentDef
    let runs: AgentRunsResult?
    let rename: () -> Void
    let looksGood: () -> Void
    let change: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SidebarAvatar(id: summary.ref.id, name: def.name, glyph: def.avatar, size: 44)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(AgentHue.color(summary.ref.id).opacity(0.18)).padding(-6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("I'm \(def.name)").font(.system(size: 17, weight: .semibold))
                    Button("Rename · change icon", action: rename).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                row("Does") { Text(def.description ?? "What you told me").foregroundStyle(Color.dsFg) }
                row("When") { Text(when).foregroundStyle(Color.dsFg) }
                row("Uses") {
                    (Text(uses.allowed.isEmpty && uses.asks.isEmpty ? "Only talking" : uses.allowed.joined(separator: " · ")).foregroundStyle(Color.dsFg)
                        + Text(uses.asks.isEmpty ? "" : "\(uses.allowed.isEmpty ? "" : " · ")\(uses.asks.joined(separator: " · "))").foregroundStyle(Color.dsFg)
                        + Text(uses.asks.isEmpty ? "" : "  needs your OK").foregroundStyle(Color.dsAmber))
                }
                row("Reaches") { Text(def.channels?["telegram"] != nil ? "You, here in Piopio and on Telegram" : "You, here in Piopio").foregroundStyle(Color.dsFg) }
            }
            HStack(spacing: 10) {
                Button("Looks good", action: looksGood).buttonStyle(PillStyle(kind: .primary))
                    .help("It runs once now, so you see how it looks")
                Button("Change something", action: change).buttonStyle(PillStyle())
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: 680, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.dsFg3).frame(width: 64, alignment: .leading)
            value().font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Weekdays at 8:00", "When an email from the bank arrives", "Only when you ask".
    private var when: String {
        var parts = (def.schedules ?? []).map { CronText.describe($0.cron) }
        // A routine it set itself: its time in words when it repeats, else what it waits for.
        parts += (runs?.upcoming ?? []).filter { $0.kind == .watch || $0.kind == .reminder }.map { u in u.cron.map(CronText.describe) ?? (u.label.components(separatedBy: " · ").first ?? u.label) }
        return parts.isEmpty ? "Only when you ask" : parts.prefix(3).joined(separator: "; ")
    }

    /// What it may use on its own, and what asks you first.
    private var uses: (allowed: [String], asks: [String]) {
        let rules = def.policies?.requireApproval ?? []
        func asks(_ names: [String]) -> Bool { rules.contains { r in r == "*" || names.contains { r == $0 || r.hasPrefix($0 + ":") || r.hasPrefix($0) } } }
        var allowed: [String] = [], asking: [String] = []
        let tools = Set(def.tools.builtin)
        func add(_ title: String, _ names: [String]) { if asks(names) { asking.append(title) } else { allowed.append(title) } }
        if tools.contains("web_search") || tools.contains("web_fetch") { add("Web", ["web_search", "web_fetch"]) }
        if tools.contains("memory") { add("Memory", ["memory"]) }
        if tools.contains("send_message") { add("Messages", ["send_message"]) }
        for app in def.tools.apple ?? [] { add(app.capitalized, ["apple_\(app)_"]) }
        return (allowed, asking)
    }
}

