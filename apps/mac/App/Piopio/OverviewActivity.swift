import PiopioKit
import SwiftUI

/// Overview › Activity (docs/spec/34 §7): what Piopio did in the range, each number against the range before; above
/// it a year of days (OV5), and Disk last (§7.1). Only what Piopio can count: no "time saved", no streaks or scores.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let activity {
                YearOfDays(days: activity.year).padding(.bottom, 6)
                ForEach(activity.groups) { group in
                    OverviewSection(group.title) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(group.rows) { row in ActivityRowView(row: row, before: before) }
                        }
                    }
                }
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

    // MARK: Disk (§7.1)

    @ViewBuilder private var disk: some View {
        OverviewSection("Disk", trailing: {
            if let storage { Text(Self.bytes(storage.totalBytes)).foregroundStyle(Color.dsFg2).monospacedDigit() }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                if let storage {
                    ForEach(storage.items) { item in diskRow(item) }
                }
                // The browser's data lives in WebKit, which doesn't say how big it is: only the action.
                HStack(spacing: 10) {
                    Text("Browser data").font(.system(size: 13))
                    Text(browserCleared ? "cleared" : "sign-ins, cookies and cache of Piopio's browser").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    Spacer()
                    Button("Clear browser data…") { confirmBrowser = true }.buttonStyle(SelectorStyle()).font(.system(size: 12.5))
                }
                .padding(.vertical, 7)
                if let cleaned { FinePrint(cleaned).padding(.top, 6) }
                if let storage { FinePrint("In \(storage.path). Nothing outside it is counted.").padding(.top, 8) }
            }
        }
    }

    private func diskRow(_ item: StorageResult.Item) -> some View {
        HStack(spacing: 10) {
            Text(item.label).font(.system(size: 13)).lineLimit(1)
            if let detail = item.detail { Text(detail).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
            Spacer()
            if let action = item.action, action.count > 0 {
                Button("\(action.label) · frees \(Self.bytes(action.freesBytes))") { confirming = action }
                    .buttonStyle(SelectorStyle()).font(.system(size: 12.5))
            }
            Text(Self.bytes(item.bytes)).font(.system(size: 13)).foregroundStyle(Color.dsFg2).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5).opacity(0.6) }
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

/// A year of days (OV5): a 7-row grid, a column a week, each square from `track` to `fg2` by how much happened that
/// day (four levels against the year's busiest day). Today is outlined. Month names above; nothing else.
private struct YearOfDays: View {
    let days: [ActivityDay]
    private let cell: CGFloat = 9
    private let gap: CGFloat = 2

    var body: some View {
        let weeks = columns
        let peak = max(days.map(\.count).max() ?? 0, 1)
        let today = OverviewPage.dayKey(Date())
        VStack(alignment: .leading, spacing: 4) {
            // Month names over the week a month starts in, when there's room.
            ZStack(alignment: .topLeading) {
                ForEach(monthLabels(weeks), id: \.column) { label in
                    Text(label.name).font(.system(size: 10.5)).foregroundStyle(Color.dsFg3)
                        .offset(x: CGFloat(label.column) * (cell + gap))
                }
            }
            .frame(height: 13, alignment: .topLeading)
            HStack(alignment: .top, spacing: gap) {
                ForEach(weeks.indices, id: \.self) { w in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            if let day = weeks[w][d] {
                                square(level: level(day.count, peak: peak), today: day.day == today)
                                    .help("\(Self.label(day.day)) · \(Int(day.count)) thing\(Int(day.count) == 1 ? "" : "s") done")
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A year of days: \(days.filter { $0.count > 0 }.count) days with activity")
    }

    private func square(level: Int, today: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(level == 0 ? Color.dsTrack : Color.dsFg2.opacity([0.3, 0.5, 0.75, 1][level - 1]))
            .frame(width: cell, height: cell)
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(today ? Color.dsFg : .clear, lineWidth: 1))
    }

    private func level(_ count: Double, peak: Double) -> Int {
        count <= 0 ? 0 : min(4, max(1, Int((count / peak * 4).rounded(.up))))
    }

    /// The days as weeks (columns) of seven, starting on the week's first day; days outside the range are empty.
    private var columns: [[ActivityDay?]] {
        let calendar = Calendar.current
        guard let first = days.first.flatMap({ Self.date($0.day) }) else { return [] }
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let cells: [ActivityDay?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        return stride(from: 0, to: cells.count, by: 7).map { start in
            (0..<7).map { start + $0 < cells.count ? cells[start + $0] : nil }
        }
    }

    private func monthLabels(_ weeks: [[ActivityDay?]]) -> [(column: Int, name: String)] {
        var out: [(column: Int, name: String)] = []
        var last: String?
        for (i, week) in weeks.enumerated() {
            guard let day = week.compactMap({ $0 }).first else { continue }
            let month = String(day.day.prefix(7))
            if month != last {
                last = month
                // Room for a name: three columns after the previous one.
                if let previous = out.last, i - previous.column < 3 { continue }
                out.append((i, Self.date(day.day)?.formatted(.dateTime.month(.abbreviated)) ?? ""))
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
