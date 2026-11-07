import AppKit
import PiopioKit
import SwiftUI

// The parts of a Summary column (docs/design/summary/ia.html), style A: groups in order of attention (Now, Made, Plan,
// Context, Setup), each a card with the verb on the left in grey and what it answers on the right, like the agent's
// info panel. Shared by Build sessions and chats.

/// A group's heading: 12pt grey, with what belongs on its right (a count, a link, the context meter).
struct GroupHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.trailing = trailing() }

    var body: some View {
        HStack(spacing: 8) {
            SectionLabel(title).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing
        }
    }
}

/// A line of the card: the verb on the left in grey, what it answers on the right.
struct CardRow<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).fixedSize()
                .frame(width: 68, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A clickable value in a card: the name, then grey details on the right.
struct ItemButton<Trailing: View>: View {
    let title: String
    let help: String
    var dim = false
    let action: () -> Void
    let trailing: Trailing

    init(title: String, help: String, dim: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.help = help; self.dim = dim; self.action = action; self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: dim ? 12.5 : 13)).foregroundStyle(dim ? Color.dsFg2 : Color.dsFg)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                trailing
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A value that unfolds into its detail below (Read, Uses, Knows), with a small chevron.
struct FoldButton<Label: View>: View {
    let open: Bool
    let help: String
    let action: () -> Void
    let label: Label

    init(open: Bool, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.open = open; self.help = help; self.action = action; self.label = label()
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { action() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                label
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

/// A blue text action (links are the only blue in the chrome).
struct SummaryLink: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            .lineLimit(1).fixedSize()
    }
}

extension View {
    /// A group: vertical padding and the hairline below it (Setup, always last, has none).
    func summaryGroup() -> some View {
        padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }
}

/// The column's footer: what this conversation cost.
struct SummaryFooter: View {
    let label: String
    let cost: Double

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                Spacer()
                Text(cost > 0 && cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)).font(.system(size: 12).monospacedDigit())
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

// MARK: Now

/// The Now group, only while it works or waits on you: a bold line and a grey one.
struct NowGroup: View {
    let waiting: Bool
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                StatusDot(status: waiting ? .waiting : .running)
                Text(waiting ? "Waiting for you" : title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            }
            if let detail { Text(detail).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3) }
        }
        .summaryGroup()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Context

/// The Context group's header: how full, the tokens in the tooltip, and Compact where the conversation can.
struct ContextMeter: View {
    let thread: ThreadModel
    let context: SessionState.Context
    var compact = false
    @State private var compacting = false

    var body: some View {
        let fraction = min(1, (context.tokens ?? 0) / max(1, context.window))
        HStack(spacing: 7) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dsLine)
                Capsule().fill(fraction > 0.85 ? Color.dsFg : Color.dsFg2).frame(width: max(3, 40 * fraction))
            }
            .frame(width: 40, height: 3)
            // One line whatever the panel's width: squeezed, it wrapped a letter per line ("1 / % / fu / ll").
            Text("\(Int((fraction * 100).rounded()))% full").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg2)
                .lineLimit(1).fixedSize()
            if compact, (context.tokens ?? 0) > 0 {
                SummaryLink(compacting ? "Compacting…" : "Compact") {
                    compacting = true
                    Task { await thread.compact(); compacting = false }
                }
                .fixedSize()
                .disabled(thread.isRunning || compacting)
                .help("Summarize the conversation so far to free up room")
            }
        }
        .fixedSize()
        .help("\(context.tokens.map { ContextRing.short($0) } ?? "–") of \(ContextRing.short(context.window)) tokens")
    }
}

// MARK: Setup

/// Setup › Uses: what this conversation may use (web search in chats, connected apps, MCP servers), the names of
/// those on, unfolding into a switch each for this conversation only. Settings decides what's on everywhere.
struct UsesRow: View {
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary
    /// Chats: web search is one of the things it uses.
    var web = false
    @State private var servers: [McpServerInfo] = []
    @State private var open = false

    var body: some View {
        let choices = ToolChoices.compute(engine: engine, ref: summary.ref, debate: summary.debate != nil, servers: servers)
        let off = Set(summary.toolsOff ?? [])
        let on = choices.filter { $0.available && !off.contains($0.id) }
        let names = (web && thread.webEnabled ? ["the web"] : []) + on.map(\.title)
        let total = choices.count + (web ? 1 : 0)
        CardRow("Uses") {
            if total == 0 {
                Text("No apps").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                SummaryLink("Connect…") { ToolChoices.openSettings("Connectors") }
                    .help("Connect apps and MCP servers in Settings")
            } else {
                FoldButton(open: open, help: "Turn things off for this conversation") { open.toggle() } label: {
                    Text(names.isEmpty ? "Nothing on" : names.joined(separator: ", ")).font(.system(size: 13))
                        .foregroundStyle(names.isEmpty ? Color.dsFg3 : Color.dsFg).lineLimit(2).multilineTextAlignment(.leading)
                    if names.count < total {
                        Text("\(names.count) of \(total)").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                }
                if open {
                    if web {
                        HStack(spacing: 9) {
                            Text("Web search").font(.system(size: 13))
                            Spacer(minLength: 4)
                            Toggle("", isOn: Binding(get: { thread.webEnabled }, set: { on in Task { await thread.setWeb(on) } }))
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .accessibilityLabel("Web search in this conversation")
                        }
                        .frame(minHeight: 26)
                    }
                    ForEach(choices) { choice in ToolChoiceRow(choice: choice, off: off, thread: thread, icon: false) }
                    HStack(spacing: 8) {
                        Text("Only here. Settings decides the rest.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        SummaryLink("Connect…") { ToolChoices.openSettings("Connectors") }
                    }
                }
            }
        }
        .task(id: summary.ref.id) { servers = await ToolChoices.load(engine: engine, cwd: summary.ref.kind == .build ? summary.cwd : nil) }
    }
}

/// Setup › Skills: instructions the model can load when a task needs them (pi's skills: SKILL.md folders, found in
/// pi's and the shared agent skill folders, and in pi packages). Folded, a count; open, each one with what it's for
/// and where it comes from, so a skill installed by another tool (an "open-knowledge-…") isn't a mystery.
struct SkillsRow: View {
    let thread: ThreadModel
    @State private var skills: [SessionCommand] = []
    @State private var open = false

    private static let explanation = "Skills are instructions the model loads by itself when a task needs them, or that you call with / in the box. They come from skill folders on this Mac and from pi packages."

    var body: some View {
        CardRow("Skills") {
            if skills.isEmpty {
                HStack(spacing: 8) {
                    Text("None").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    SummaryLink("Add skills…") { ToolChoices.openSettings("Extensions") }
                }
                .help(Self.explanation)
            } else {
                FoldButton(open: open, help: open ? "Hide the skills" : "What each skill is for, and where it comes from") { open.toggle() } label: {
                    Text("\(skills.count) skill\(skills.count == 1 ? "" : "s")").font(.system(size: 13))
                }
                .help(Self.explanation)
                if open { list.padding(.top, 4) }
            }
        }
        .task(id: thread.ref.id) { skills = await thread.commands().filter { $0.kind == .skill } }
    }

    private var list: some View {
        let sources = Set(skills.compactMap(\.source))
        return VStack(alignment: .leading, spacing: 12) {
            Text(Self.explanation).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            ForEach(skills) { skill in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.name(skill)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg)
                    if !skill.description.isEmpty {
                        Text(skill.description).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    // Each skill's folder only when they come from different places; otherwise once, below.
                    if sources.count > 1, let source = skill.source {
                        Text(source).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
                    }
                }
                .help("Type /\(skill.name) to use it")
            }
            VStack(alignment: .leading, spacing: 4) {
                if sources.count == 1, let source = sources.first {
                    Text("From \(source)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Text("Type / in the box to use one.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    SummaryLink("Manage…") { ToolChoices.openSettings("Extensions") }
                }
            }
        }
    }

    /// pi names skill commands "skill:<name>"; the card shows the name.
    static func name(_ skill: SessionCommand) -> String {
        skill.name.hasPrefix("skill:") ? String(skill.name.dropFirst(6)) : skill.name
    }
}
