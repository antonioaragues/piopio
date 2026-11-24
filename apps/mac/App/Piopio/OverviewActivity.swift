import PiopioKit
import SwiftUI

/// Overview › Activity (docs/spec/34 §7; docs/design/overview Redesign, option A): three highlights, one sentence
/// from Piopio about the busiest day, the grid of days in a blue scale, then every number folded behind one line, and
/// Disk last (§7.1). Only what Piopio can count: no "time saved", no streaks or scores.
struct OverviewActivityTab: View {
    let engine: EngineController
    let range: SpendRange
    @Binding var item: SidebarItem
    @State private var activity: ActivityResult?
    @State private var storage: StorageResult?
    @State private var error: String?
    @State private var confirming: StorageResult.Action?
    @State private var cleaned: String?
    @State private var confirmBrowser = false
    @State private var browserCleared = false
    /// The full tables, folded by default and remembered.
    @AppStorage("overviewActivityAll") private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let activity {
                highlights(activity)
                if let busiest = busiest(activity) {
                    HStack(alignment: .center, spacing: 10) {
                        Chick(size: 22)
                        busiest.font(.system(size: 13))
                    }
                    .padding(.top, 24)
                }
                YearOfDays(days: activity.year).padding(.top, 22)
                allNumbers(activity).padding(.top, 22)
                if activity.backfilling == true {
                    FinePrint("Reading past conversations… the numbers fill in as it goes.").padding(.top, 14)
                }
            } else if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Color.dsFg2).padding(.top, 20)
            } else {
                ProgressView().controlSize(.small).padding(.top, 30).frame(maxWidth: .infinity)
            }
            disk
        }
        .task(id: range) { await load() }
        .task { await loadStorage() }
        // While past conversations are read in, look again every few seconds (as Spend does).
        .task(id: activity?.backfilling == true) {
            guard activity?.backfilling == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await load()
                if activity?.backfilling != true { break }
            }
        }
        .alert(confirming.map { "Clean up \($0.count) worktree\($0.count == 1 ? "" : "s")?" } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { action in
            Button("Clean Up", role: .destructive) { Task { await clean(action) } }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("This frees about \(Self.bytes(action.freesBytes)). Only worktrees whose session merged, was discarded or is gone, with nothing uncommitted in them, are removed.")
        }
        .confirmationDialog("Clear the browser's data?", isPresented: $confirmBrowser) {
            Button("Clear", role: .destructive) { Task { await BrowserSettingsPane.clearData(); browserCleared = true } }
        } message: {
            Text("You'll be signed out of every site in Piopio's browser. Its cookies, storage and cache are deleted.")
        }
    }

    /// "last month", "the 7 days before"…: what the comparison is against.
    private var before: String {
        switch range {
        case .today: "yesterday"
        case .sevenDays: "the 7 days before"
        case .month: "last month"
        case .lastMonth: "the month before"
        case .twelveMonths: "the year before"
        }
    }

    // MARK: Highlights

    private struct Highlight: Identifiable {
        let id: String
        let value: String
        let label: String
        let note: String?
        let glyph: String
    }

    /// Three numbers worth a glance: messages you sent, files Piopio changed, automation runs. One that's 0 gives
    /// its place to the biggest of the others (tool calls, conversations started…).
    private func picks(_ a: ActivityResult) -> [Highlight] {
        let rows = Dictionary(a.groups.flatMap(\.rows).map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        var chosen: [ActivityRow] = []
        let pool = ["toolCalls", "started", "buildSessions", "agentRuns", "agentMessages"].compactMap { rows[$0] }.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        for id in ["messages", "files", "autoRuns"] {
            if let row = rows[id], row.value > 0 { chosen.append(row); continue }
            if let next = pool.first(where: { p in !chosen.contains { $0.id == p.id } }) { chosen.append(next) }
            else if let row = rows[id] { chosen.append(row) }
        }
        return chosen.map { row in
            let label: String = switch row.id {
            case "messages": "messages you sent"
            case "files": "files Piopio changed"
            case "autoRuns": "automation runs"
            case "toolCalls": "tool calls"
            case "started": "conversations started"
            case "buildSessions": "Build sessions"
            case "agentRuns": "agent runs"
            default: row.label.lowercased()
            }
            var note: String? = comparison(row)
            if row.id == "files", let sessions = rows["buildSessions"], sessions.value > 0 { note = "in \(Int(sessions.value)) Build session\(sessions.value == 1 ? "" : "s")" }
            if row.id == "autoRuns", let failed = rows["autoFailed"], failed.value > 0 {
                let who = failed.detail.map { $0.replacingOccurrences(of: " failed most", with: "") }
                note = "\(Int(failed.value)) failed\(who.map { " · \($0)" } ?? "")"
            }
            if row.id == "toolCalls", let top = row.detail { note = top }
            let glyph = switch row.id {
            case "messages", "started", "agentMessages": "bubble.left"
            case "files": "pencil"
            case "buildSessions": "hammer"
            case "agentRuns": "bird"
            case "toolCalls": "wrench.and.screwdriver"
            default: "clock.arrow.circlepath"
            }
            return Highlight(id: row.id, value: ActivityRowView.value(row.value, row.unit), label: label, note: note, glyph: glyph)
        }
    }

    private func highlights(_ a: ActivityResult) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(picks(a).enumerated()), id: \.element.id) { i, h in
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: h.glyph).font(.system(size: 13, weight: .medium)).foregroundStyle(DataColor.series(i))
                        .frame(width: 28, height: 28)
                        .background(DataColor.tint(i), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(h.value).font(.system(size: 28, weight: .bold)).tracking(-0.4).monospacedDigit().padding(.top, 10)
                    Text(h.label).font(.system(size: 13)).foregroundStyle(Color.dsFg2).lineLimit(1)
                    Text(h.note ?? " ").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).padding(.top, 1)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "+18 vs last month"; nothing without a range before.
    private func comparison(_ row: ActivityRow) -> String? {
        guard let previous = row.previous else { return nil }
        let diff = row.value - previous
        if abs(diff) < 0.5 { return "same as \(before)" }
        return "\(diff > 0 ? "+" : "−")\(ActivityRowView.value(abs(diff), row.unit)) vs \(before)"
    }

    /// "Your busiest day was Saturday 22 Nov: 194 messages and requests." Facts only (OV5); nothing when all are 0.
    private func busiest(_ a: ActivityResult) -> Text? {
        guard let top = a.year.max(by: { $0.count < $1.count }), top.count > 0, let date = YearOfDays.date(top.day) else { return nil }
        let day = date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        return Text("Your busiest day was ") + Text(day).fontWeight(.semibold) + Text(": \(Int(top.count)) messages and requests.")
    }

    /// Every number, folded behind one line (remembered).
    @ViewBuilder private func allNumbers(_ a: ActivityResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(showsAll ? 90 : 0))
                    Text("All numbers: \(a.groups.map { $0.id == "build" ? "Build" : $0.title.lowercased().replacingOccurrences(of: "piopio", with: "Piopio") }.joined(separator: ", "))").lineLimit(1)
                    Spacer()
                }
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
            if showsAll {
                ForEach(a.groups) { group in
                    OverviewSection(group.title) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(group.rows) { row in ActivityRowView(row: row, before: before) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Disk (§7.1)

    /// One bar coloured by kind (biggest first), its legend with sizes, then the one cleanup as a row with a black
    /// action; the browser's data (no size: WebKit doesn't say) under it.
    @ViewBuilder private var disk: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let storage { Text(Self.bytes(storage.totalBytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
            }
            if let storage {
                let kinds = storage.items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
                DiskBar(parts: kinds.enumerated().map { (DataColor.series($0.offset), $0.element.bytes, $0.element.label) })
                Flow(spacing: 14, lineSpacing: 6) {
                    ForEach(Array(kinds.enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 6) {
                            Circle().fill(DataColor.series(i)).frame(width: 8, height: 8)
                            Text(item.label).foregroundStyle(Color.dsFg2)
                            Text(Self.bytes(item.bytes)).fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .help(item.detail ?? item.label)
                    }
                }
                if let action = storage.items.compactMap(\.action).first(where: { $0.count > 0 }) {
                    HStack(spacing: 10) {
                        Text("\(action.count) worktree\(action.count == 1 ? "" : "s") nothing uses").font(.system(size: 13))
                        Spacer()
                        Button("Free \(Self.bytes(action.freesBytes))") { confirming = action }
                            .buttonStyle(PillStyle(kind: .primary, compact: true))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.dsTrack, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 4)
                }
            }
            // The browser's data lives in WebKit, which doesn't say how big it is: only the action.
            HStack(spacing: 10) {
                Text("Browser data").font(.system(size: 13))
                Text(browserCleared ? "cleared" : "sign-ins, cookies and cache of Piopio's browser").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                Spacer()
                Button("Clear browser data…") { confirmBrowser = true }.buttonStyle(SelectorStyle()).font(.system(size: 12.5))
            }
            .padding(.top, 2)
            if let cleaned { FinePrint(cleaned) }
            if let storage { FinePrint("In \(storage.path). Nothing outside it is counted.") }
        }
        .padding(.top, 30)
    }

    // MARK: Loading

    private func load() async {
        guard let client = engine.client else { error = "Connect to the engine to see what Piopio did."; return }
        do {
            activity = try await client.call("stats.activity", ActivityParams(range: range), as: ActivityResult.self)
            error = nil
        } catch {
            if activity == nil { self.error = error.localizedDescription }
        }
    }

    private func loadStorage() async {
        storage = try? await engine.client?.call("stats.storage", Empty(), as: StorageResult.self)
    }

    private func clean(_ action: StorageResult.Action) async {
        guard let client = engine.client else { return }
        do {
            let r = try await client.call("stats.storage.clean", StorageCleanParams(action: action.id), as: StorageCleanResult.self)
            cleaned = r.removed == 0 ? "Nothing to clean up." : "Removed \(r.removed) worktree\(r.removed == 1 ? "" : "s"), freed \(Self.bytes(r.freedBytes))."
        } catch {
            cleaned = error.localizedDescription
        }
        await loadStorage()
    }

    static func bytes(_ n: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

/// One number of Activity, and how it compares with the range before.
private struct ActivityRowView: View {
    let row: ActivityRow
    let before: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label).font(.system(size: 13)).lineLimit(1)
            if let detail = row.detail { Text(detail).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 12)
            if let comparison { Text(comparison).font(.system(size: 12)).foregroundStyle(Color.dsFg3).monospacedDigit().lineLimit(1) }
            Text(Self.value(row.value, row.unit)).font(.system(size: 13)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    /// "+12 vs last month", "same as last week"; nothing when there was no range before.
    private var comparison: String? {
        guard let previous = row.previous else { return nil }
        let diff = row.value - previous
        if abs(diff) < (row.unit == .ms ? 60_000 : 0.5) { return "same as \(before)" }
        return "\(diff > 0 ? "+" : "−")\(Self.value(abs(diff), row.unit)) vs \(before)"
    }

    static func value(_ v: Double, _ unit: ActivityRow.Unit?) -> String {
        switch unit {
        case .ms:
            let minutes = Int((v / 60_000).rounded())
            if minutes < 1 { return v < 1000 ? "0m" : "\(Int(v / 1000))s" }
            let h = minutes / 60, m = minutes % 60
            return h == 0 ? "\(m)m" : m == 0 ? "\(h)h" : "\(h)h \(m)m"
        default:
            return Int(v.rounded()).formatted()
        }
    }
}

/// The grid of days (OV5): a 7-row grid, a column a week, each square from `track` through four blue steps by how much
/// happened that day (against the busiest one). Today is outlined. Until there's a year of history it shows the last
/// 13 weeks, so it isn't a wall of empty squares. Month names above, a less→more key below; nothing else.
struct YearOfDays: View {
    let days: [ActivityDay]
    private let cell: CGFloat = 14
    private let gap: CGFloat = 4

    var body: some View {
        let shown = window
        let weeks = Self.columns(shown)
        let peak = max(shown.map(\.count).max() ?? 0, 1)
        let today = OverviewPage.dayKey(Date())
        VStack(alignment: .leading, spacing: 5) {
            // Month names over the week a month starts in, when there's room.
            ZStack(alignment: .topLeading) {
                ForEach(Self.monthLabels(weeks), id: \.column) { label in
                    Text(label.name).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                        .offset(x: CGFloat(label.column) * (cell + gap))
                }
            }
            .frame(height: 14, alignment: .topLeading)
            HStack(alignment: .top, spacing: gap) {
                ForEach(weeks.indices, id: \.self) { w in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            if let day = weeks[w][d] {
                                square(level: level(day.count, peak: peak), today: day.day == today)
                                    .help("\(Self.label(day.day)) · \(Int(day.count)) message\(Int(day.count) == 1 ? "" : "s") and requests")
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("less")
                ForEach(1..<5, id: \.self) { l in RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(DataColor.seq[l]).frame(width: 9, height: 9) }
                Text("more")
            }
            .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            .padding(.top, 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Days: \(shown.filter { $0.count > 0 }.count) with activity")
    }

    /// A year when there's a year of history; until then the last 13 weeks, from the start of the week 12 weeks ago.
    private var window: [(day: String, count: Double)] {
        let counts = Dictionary(days.map { ($0.day, $0.count) }, uniquingKeysWith: { a, _ in a })
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if days.count >= 360 { return days.map { ($0.day, $0.count) } }
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = calendar.date(byAdding: .weekOfYear, value: -12, to: thisWeek) ?? today
        var out: [(day: String, count: Double)] = []
        var d = start
        while d <= today {
            let key = OverviewPage.dayKey(d)
            out.append((key, counts[key] ?? 0))
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? today.addingTimeInterval(86_400)
        }
        return out
    }

    private func square(level: Int, today: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(DataColor.seq[level])
            .frame(width: cell, height: cell)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(today ? Color.dsFg2 : .clear, lineWidth: 1.5))
    }

    private func level(_ count: Double, peak: Double) -> Int {
        count <= 0 ? 0 : min(4, max(1, Int((count / peak * 4).rounded(.up))))
    }

    /// The days as weeks (columns) of seven, starting on the week's first day; days outside the range are empty.
    static func columns(_ days: [(day: String, count: Double)]) -> [[(day: String, count: Double)?]] {
        let calendar = Calendar.current
        guard let first = days.first.flatMap({ date($0.day) }) else { return [] }
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let cells: [(day: String, count: Double)?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        return stride(from: 0, to: cells.count, by: 7).map { start in
            (0..<7).map { start + $0 < cells.count ? cells[start + $0] : nil }
        }
    }

    static func monthLabels(_ weeks: [[(day: String, count: Double)?]]) -> [(column: Int, name: String)] {
        var out: [(column: Int, name: String)] = []
        var last: String?
        for (i, week) in weeks.enumerated() {
            guard let day = week.compactMap({ $0 }).first else { continue }
            let month = String(day.day.prefix(7))
            if month != last {
                last = month
                // Room for a name: three columns after the previous one.
                if let previous = out.last, i - previous.column < 3 { continue }
                out.append((i, date(day.day)?.formatted(.dateTime.month(.abbreviated)) ?? ""))
            }
        }
        return out
    }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: day)
    }

    static func label(_ day: String) -> String {
        date(day)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? day
    }
}

/// Disk's one bar: a segment per kind in its colour, 2pt apart, the smallest still visible.
private struct DiskBar: View {
    let parts: [(color: Color, bytes: Double, label: String)]

    var body: some View {
        GeometryReader { geo in
            let total = max(parts.reduce(0) { $0 + $1.bytes }, 1)
            let gaps = CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(p.color)
                        .frame(width: max(3, (geo.size.width - gaps) * CGFloat(p.bytes / total)))
                        .help(p.label)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}
