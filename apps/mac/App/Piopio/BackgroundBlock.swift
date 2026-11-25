import PiopioKit
import PiopioTranscript
import SwiftUI

/// Background (docs/spec/43, docs/design/background): the last block of a Build session's Summary column. What the
/// conversation left running and what it ran, its background commands (TM4) and its subagents (37): running rows with
/// the time ticking and Stop on hover, then "Finished N", folded, newest first, five then "and N more". Not drawn when
/// there's nothing to list. Clear, in the head, takes what finished off the list (BG11).
struct BackgroundBlock: View {
    let running: [BackgroundRow]
    let finished: [BackgroundRow]
    /// This conversation: its fold is remembered for it.
    let conversationId: String
    let open: (BackgroundRow) -> Void
    let stop: (BackgroundRow) -> Void
    /// A command's address: the project preview.
    let preview: (String) -> Void
    /// Clear: what finished leaves the list (spec 43 BG11).
    let clear: () -> Void
    /// PIOPIO_DEMO_BACKGROUND_FINISHED=1: captures open with Finished unfolded.
    @State private var finishedOpen = ProcessInfo.processInfo.environment["PIOPIO_DEMO_BACKGROUND_FINISHED"] == "1"
    @State private var all = false
    /// Your fold for this conversation; open while something runs until you fold it.
    @State private var folded: Bool?

    private static let shortList = 5

    /// Something to show: the column draws the block, and Plan isn't the last block.
    static func shows(running: [BackgroundRow], finished: [BackgroundRow]) -> Bool { !running.isEmpty || !finished.isEmpty }

    var body: some View {
        let both = Set((running + finished).map(\.kind)).count > 1
        VStack(alignment: .leading, spacing: 0) {
            if running.isEmpty {
                // Nothing runs: the head is the fold of what finished ("3 finished ›").
                head(open: $finishedOpen, help: finishedOpen ? "Hide what ran" : "The commands and subagents this conversation ran")
                if finishedOpen { finishedList.padding(.top, 8) }
            } else {
                head(open: openBinding, help: isOpen ? "Hide the background work" : "What this conversation left running")
                if isOpen {
                    VStack(alignment: .leading, spacing: 0) {
                        // The time ticks each second while something works.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(alignment: .leading, spacing: 0) {
                                if both {
                                    let commands = running.filter { $0.kind == .command }, subagents = running.filter { $0.kind == .subagent }
                                    if !commands.isEmpty { BlockSubheading("Commands"); rows(commands, now: context.date) }
                                    if !subagents.isEmpty { BlockSubheading("Subagents"); rows(subagents, now: context.date) }
                                } else {
                                    rows(running, now: context.date)
                                }
                            }
                        }
                        if !finished.isEmpty {
                            Button { withAnimation(.easeOut(duration: 0.15)) { finishedOpen.toggle() } } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                                        .rotationEffect(.degrees(finishedOpen ? 90 : 0))
                                    Text("Finished \(finished.count)").font(.system(size: 12.5))
                                }
                                .foregroundStyle(Color.dsFg2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)
                            .accessibilityValue(finishedOpen ? "Expanded" : "Collapsed")
                            if finishedOpen { finishedList.padding(.top, 4) }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .onAppear { folded = Self.remembered(conversationId) }
        .onChange(of: conversationId) { _, id in folded = Self.remembered(id) }
    }

    /// `BlockFold`'s head with Clear before the chevron while something has finished: "Background  2 running
    /// Clear ⌄", or "3 finished Clear ⌄" when nothing runs. The title and the count fold it, as the chevron does.
    private func head(open: Binding<Bool>, help: String) -> some View {
        let toggle = { withAnimation(.easeOut(duration: 0.15)) { open.wrappedValue.toggle() } }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Background").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    // While something runs, "Finished N" is a row of its own, so the head counts only what runs.
                    Text(BackgroundWork.summary(running: running.count, finished: running.isEmpty ? finished.count : 0))
                        .font(.system(size: 13)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityValue(open.wrappedValue ? "Expanded" : "Collapsed")
            if !finished.isEmpty {
                SummaryLink("Clear") { withAnimation(.easeOut(duration: 0.15)) { clear() } }
                    .help("Remove the finished ones from this list (their output stays in the terminal)")
                    .accessibilityLabel("Clear finished")
            }
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityHidden(true)
        }
    }

    private var isOpen: Bool { !(folded ?? false) }
    private var openBinding: Binding<Bool> {
        Binding(get: { isOpen }, set: { open in
            folded = !open
            Self.remember(folded: !open, for: conversationId)
        })
    }

    private var finishedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows(all ? finished : Array(finished.prefix(Self.shortList)), now: .now)
            if finished.count > Self.shortList {
                SummaryLink(all ? "Show fewer" : "and \(finished.count - Self.shortList) more") {
                    withAnimation(.easeOut(duration: 0.15)) { all.toggle() }
                }
                .padding(.top, 4)
            }
        }
    }

    private func rows(_ list: [BackgroundRow], now: Date) -> some View {
        ForEach(list) { row in
            BackgroundRowView(row: row, now: now, open: { open(row) }, stop: { stop(row) }, preview: preview)
        }
    }

    /// When you last cleared this conversation's finished work: what had ended by then isn't listed.
    static func clearedAt(_ id: String) -> Date? {
        ((UserDefaults.standard.dictionary(forKey: "backgroundClearedAt") as? [String: Double])?[id]).map(Date.init(timeIntervalSince1970:))
    }

    static func clear(_ id: String, at date: Date = .now) {
        var all = (UserDefaults.standard.dictionary(forKey: "backgroundClearedAt") as? [String: Double]) ?? [:]
        all[id] = date.timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: "backgroundClearedAt")
    }

    // Folded per conversation, as Changes is (`inspectorChangesOpen`); only a fold is kept.
    private static func remembered(_ id: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: "backgroundFolded") as? [String: Bool])?[id]
    }

    private static func remember(folded: Bool, for id: String) {
        var all = (UserDefaults.standard.dictionary(forKey: "backgroundFolded") as? [String: Bool]) ?? [:]
        all[id] = folded ? true : nil
        UserDefaults.standard.set(all, forKey: "backgroundFolded")
    }
}

/// A row: the glyph, the name (a command in monospace) with its grey line, and on the right the time while it runs,
/// which Stop replaces on hover.
private struct BackgroundRowView: View {
    let row: BackgroundRow
    let now: Date
    let open: () -> Void
    let stop: () -> Void
    let preview: (String) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            SubagentGlyph(state: row.state).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(row.kind == .command ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .foregroundStyle(Color.dsFg).lineLimit(1).truncationMode(.middle)
                if let line = row.line, !line.isEmpty {
                    if row.kind == .command, row.running, let url = row.urls.first {
                        // The dev server's address opens the project preview (22 §6.1).
                        Button { preview(url) } label: {
                            HStack(spacing: 3) {
                                Text(line)
                                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                            }
                            .font(.system(size: 11.5)).foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(url) in the preview")
                    } else {
                        Text(line).font(.system(size: 11.5)).foregroundStyle(row.alerting ? Color.dsWarn : Color.dsFg3).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if row.running {
                if hovering {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(Color.dsFg2)
                            .frame(width: 20, height: 18)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(row.kind == .command ? "Stop it and what it started" : "Stop this subagent")
                    .accessibilityLabel("Stop \(row.title)")
                } else if let elapsed = row.elapsed(at: now) {
                    Text(elapsed).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3).padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help(row.kind == .command ? "Open in the terminal" : "Open beside the conversation")
        // Its Stop and address stay their own buttons; the row itself opens with VoiceOver's action.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.kind == .command ? "Command" : "Subagent") \(row.title)")
        .accessibilityAction(named: row.kind == .command ? "Open in the terminal" : "Open beside the conversation", open)
    }
}
