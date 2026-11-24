import AppKit
import PiopioKit
import SwiftUI
import UniformTypeIdentifiers

/// Overview (docs/spec/34): one page, three tabs (OV2). Spend is what Piopio costs, from the engine's usage ledger;
/// Setup is the map of what you have and where it runs (OverviewSetup.swift); Activity is what got done, a year of
/// days and Disk (OverviewActivity.swift). Piopio's estimate and a provider's bill are different scopes: they sit side
/// by side and are never added. Unknown prices are counted, never shown as $0; a plan is not free.
struct OverviewPage: View {
    let engine: EngineController
    /// Only what one agent spent (its "$… this month" opens it), else everything.
    let agent: String?
    @Binding var item: SidebarItem
    @AppStorage("overviewRange") private var rangeRaw = SpendRange.month.rawValue
    @AppStorage("overviewGroupBy") private var groupRaw = SpendGroupBy.what.rawValue
    /// Spend · Setup · Activity, remembered like the range; ⌘K's "Setup" and "Activity" set it before opening.
    @AppStorage(OverviewTab.key) private var tabRaw = OverviewTab.spend.rawValue
    @State private var spend: SpendResult?
    @State private var budgets: [Budget] = []
    @State private var error: String?
    @State private var showsAll = false
    @State private var opened: SpendGroup?
    @State private var hovered: String?
    /// The Piopio budget's popover (Set a budget… / Change…) and what's typed in it.
    @State private var editingBudget = false
    @State private var budgetText = ""

    private var range: SpendRange { SpendRange(rawValue: rangeRaw) ?? .month }
    /// Filtered to an agent, the page is that agent's Spend.
    private var tab: OverviewTab { agent == nil ? (OverviewTab(rawValue: tabRaw) ?? .spend) : .spend }
    private var groupBy: SpendGroupBy { SpendGroupBy(rawValue: groupRaw) ?? .what }
    private var agentName: String? { agent.map { id in engine.agents.first { $0.ref.id == id }?.title ?? "this agent" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if agent == nil {
                    NeutralSegmented(selection: $tabRaw, options: OverviewTab.allCases.map { ($0.rawValue, $0.title) })
                        .frame(width: 270)
                        .padding(.bottom, 20)
                }
                switch tab {
                case .spend: spendTab
                case .setup: OverviewSetupTab(engine: engine, item: $item)
                case .activity: OverviewActivityTab(engine: engine, range: range, item: $item)
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 44)
            .padding(.bottom, 90)
            .frame(maxWidth: 760 + 96)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dsWin)
        .task(id: "\(rangeRaw)|\(groupRaw)|\(agent ?? "")") { if tab == .spend { await load() } }
        .task(id: tabRaw) { if tab == .spend && spend == nil { await load() } }
        // While past conversations are read in, look again every few seconds.
        .task(id: spend?.backfilling == true) {
            guard spend?.backfilling == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await load()
                if spend?.backfilling != true { break }
            }
        }
        .sheet(item: $opened) { group in
            SpendItemsSheet(engine: engine, range: range, groupBy: groupBy, group: group) { ref in
                opened = nil
                if let target = engine.item(for: ref.id) { item = target }
            }
        }
    }

    @ViewBuilder private var spendTab: some View {
        VStack(alignment: .leading, spacing: 0) {
                if let agentName {
                    HStack(spacing: 6) {
                        Text("Only \(agentName)").foregroundStyle(Color.dsFg2)
                        Button("Show everything") { item = .overview(nil) }.buttonStyle(SelectorStyle())
                    }
                    .font(.system(size: 12.5))
                    .padding(.bottom, 12)
                }
                if let spend {
                    if spend.calls == 0 && spend.backfilling != true {
                        empty(spend)
                    } else {
                        headline(spend)
                        byDay(spend).padding(.top, 26)
                        groupsSection(spend)
                        // Piopio's one remark on the page (docs/design/overview Redesign, A): in yolk, with the chick.
                        if agent == nil, let suggestions = spend.suggestions, !suggestions.isEmpty { cheaper(Array(suggestions.prefix(3))).padding(.top, 26) }
                        if agent == nil { plainSection("Budgets") { budgetGrid } }
                    }
                    if spend.backfilling == true {
                        FinePrint("Reading past conversations… the numbers fill in as it goes.").padding(.top, 14)
                    }
                } else if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Color.dsFg2).padding(.top, 20)
                } else {
                    ProgressView().controlSize(.small).padding(.top, 30).frame(maxWidth: .infinity)
                }
        }
    }

    // MARK: Header

    /// Title, then (from OV2) the Spend · Setup · Activity control, and the range on the right as plain text.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Overview").font(.system(size: 20, weight: .bold)).tracking(-0.3)
            Spacer()
            if tab == .spend {
                Button("Export CSV") { export() }
                    .buttonStyle(PillStyle(compact: true))
                    .disabled((spend?.calls ?? 0) == 0)
                    .help("The requests in this range, one row per request: when, where, what, the model and the cost. No messages.")
            }
            // The range applies to Spend and Activity (OV2); Setup is how things are now.
            if tab != .setup { rangeMenu }
        }
        .padding(.bottom, 18)
    }

    private var rangeMenu: some View {
            Menu {
                ForEach(SpendRange.allCases, id: \.self) { r in
                    Button { rangeRaw = r.rawValue } label: { if r == range { Label(Self.rangeName(r), systemImage: "checkmark") } else { Text(Self.rangeName(r)) } }
                }
            } label: { Text(Self.rangeName(range)).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2) }
                .menuStyle(.button).buttonStyle(SelectorStyle()).menuIndicator(.hidden).fixedSize()
    }

    static func rangeName(_ r: SpendRange) -> String {
        switch r {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .month: "This month"
        case .lastMonth: "Last month"
        case .twelveMonths: "12 months"
        }
    }

    // MARK: Headline (§5.1)

    /// The provider's own number for this range, when it reports one (OpenRouter: today and this month).
    private var billed: Double? {
        guard agent == nil, let usage = engine.usage, usage.connected else { return nil }
        switch range {
        case .today: return usage.todayUsd
        case .month: return usage.monthUsd
        default: return nil
        }
    }

    /// "$18.42 so far in November", then "About $24 by the 30th · OpenRouter billed $21.06 ⓘ". Every explanation is a
    /// tooltip; the page carries numbers (Redesign A).
    private func headline(_ s: SpendResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            (Text(money(s.knownUsd)).foregroundStyle(Color.dsFg) + Text(" \(phrase(s))").foregroundStyle(Color.dsFg3).fontWeight(.medium))
                .font(.system(size: 30, weight: .semibold)).tracking(-0.4).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityLabel("Piopio's estimate: \(money(s.knownUsd)) \(phrase(s))")
            HStack(spacing: 5) {
                ForEach(Array(facts(s).enumerated()), id: \.offset) { i, fact in
                    if i > 0 { Text("·").foregroundStyle(Color.dsFg3) }
                    HStack(spacing: 4) {
                        fact.text
                        if let info = fact.info { InfoMark(text: info) }
                    }
                }
            }
            .font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            if let asOf = s.cloudAsOf.flatMap(Self.date) {
                Text("Cloud usage up to \(asOf.formatted(Calendar.current.isDateInToday(asOf) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated).hour().minute()))")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    .help("Your cloud couldn't be reached since then; what it spent after isn't counted yet.")
            }
        }
    }

    /// "so far in November", "today", "these 7 days", "in October", "these 12 months".
    private func phrase(_ s: SpendResult) -> String {
        switch range {
        case .today: "today"
        case .sevenDays: "these 7 days"
        case .month: "so far in \(monthName(s.from))"
        case .lastMonth: "in \(monthName(s.from))"
        case .twelveMonths: "these 12 months"
        }
    }

    /// The second line's parts: the forecast, the bill, what has no price, what a plan paid; each with its ⓘ.
    private func facts(_ s: SpendResult) -> [(text: Text, info: String?)] {
        var out: [(text: Text, info: String?)] = []
        let strong = { (v: String) in Text(v).foregroundStyle(Color.dsFg).fontWeight(.semibold) }
        if let forecast = s.forecastUsd {
            out.append((Text("About ") + strong(money(forecast)) + Text(" by the \(lastDay(s))"), "Straight-line from the days so far. An estimate, not a bill."))
        } else if range == .month || range == .sevenDays, let today = s.days.first(where: { $0.day == Self.dayKey(Date()) }), today.macUsd + today.cloudUsd > 0 {
            out.append((strong(money(today.macUsd + today.cloudUsd)) + Text(" today"), nil))
        }
        if let billed {
            let why = why(s).map { " \($0)" } ?? ""
            out.append((Text("OpenRouter billed ") + strong(money(billed)), "OpenRouter's own number for this key\(engine.usage?.keyHint.map { " (\($0))" } ?? ""). It includes other apps that use the key, and the two are never added.\(why)"))
        }
        if s.unknownCalls > 0 {
            out.append((Text("\(s.unknownCalls) without a price"), "\(s.unknownCalls) request\(s.unknownCalls == 1 ? "" : "s") had no price, so \(s.unknownCalls == 1 ? "it isn't" : "they aren't") in the estimate. Never counted as $0."))
        }
        if s.planCalls > 0 {
            out.append((Text("\(Self.tokens(s.planTokens)) on your plan"), "\(s.planCalls) request\(s.planCalls == 1 ? "" : "s") billed to a subscription plan: shown as tokens, never as dollars."))
        }
        return out
    }

    /// "30th": the range's last day, as an ordinal.
    private func lastDay(_ s: SpendResult) -> String {
        guard let to = Self.date(s.to) else { return "end of the month" }
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: Calendar.current.component(.day, from: to.addingTimeInterval(-1)))) ?? "end of the month"
    }

    /// One line on why the bill and the estimate differ by more than 10%. They're never added.
    private func why(_ s: SpendResult) -> String? {
        // Without a bill there's nothing to explain: the estimate's own line already counts requests without a price.
        guard let billed, max(billed, s.knownUsd) > 0.01 else { return nil }
        let diff = billed - s.knownUsd
        guard abs(diff) > 0.1 * max(billed, s.knownUsd) else { return nil }
        var reasons: [String] = []
        if diff > 0 { reasons.append("it includes other apps that use this key") }
        if s.unknownCalls > 0 { reasons.append("\(s.unknownCalls) request\(s.unknownCalls == 1 ? "" : "s") had no price") }
        if diff < 0 { reasons.append("the estimate counts other providers too, and OpenRouter's number can lag a few minutes") }
        let head = diff > 0 ? "The bill is \(money(diff)) more than the estimate" : "The estimate is \(money(-diff)) more than the bill"
        return "\(head): \(reasons.joined(separator: ", and ")). The two are never added."
    }

    // MARK: By day (§5.2)

    private func byDay(_ s: SpendResult) -> some View {
        let keys = Self.keys(s)
        let byKey = Dictionary(s.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let todayKey = range == .twelveMonths ? String(Self.dayKey(Date()).prefix(7)) : Self.dayKey(Date())
        let peak = max(s.days.map { $0.macUsd + $0.cloudUsd }.max() ?? 0, 0.01)
        let mac = s.days.reduce(0) { $0 + $1.macUsd }, cloud = s.days.reduce(0) { $0 + $1.cloudUsd }
        let height: CGFloat = 132
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                // One grid line at the peak, labelled.
                VStack(spacing: 0) {
                    HStack { Spacer(); Text(money(peak)).font(.system(size: 10.5)).foregroundStyle(Color.dsFg3) }
                    Rectangle().fill(Color.dsLine).frame(height: 0.5)
                    Spacer(minLength: 0)
                }
                .frame(height: height + 14, alignment: .top)
                HStack(alignment: .bottom, spacing: keys.count > 40 ? 3 : 5) {
                    ForEach(keys, id: \.self) { key in
                        bar(byKey[key], key: key, today: key == todayKey, future: key > todayKey, peak: peak, height: height)
                            .frame(maxWidth: keys.count <= 7 ? 44 : .infinity)
                    }
                }
                .frame(height: height, alignment: .bottom)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
            .overlay(alignment: .topLeading) {
                if let hovered, let day = byKey[hovered] { tip(day).offset(y: -6) }
            }
            HStack {
                Text(axisLabel(keys.first)).frame(maxWidth: .infinity, alignment: .leading)
                if keys.count > 2 { Text(axisLabel(keys[keys.count / 2])) }
                Text(axisLabel(keys.last)).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Each \(range == .twelveMonths ? "month" : "day"): This Mac \(money(mac))\(cloud > 0 ? ", cloud \(money(cloud))" : "")")
    }

    private func bar(_ day: SpendDay?, key: String, today: Bool, future: Bool, peak: Double, height: CGFloat) -> some View {
        let mac = day?.macUsd ?? 0, cloud = day?.cloudUsd ?? 0
        let h = max(CGFloat((mac + cloud) / peak) * height, future ? 3 : (mac + cloud > 0 ? 2 : 0))
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            if future {
                Rectangle().fill(Color.dsTrack).frame(height: 3)
            } else {
                // One colour, by amount (Redesign A): the bar's share of the peak picks the step. Mac and cloud are in
                // the tooltip.
                let share = (mac + cloud) / peak
                Rectangle()
                    .fill(hovered == key ? DataColor.seq[4] : DataColor.amount(share))
                    .opacity(today ? 0.45 : 1)
                    .frame(height: h)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .overlay { if today { UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4).stroke(Color.dsFg2, lineWidth: 1.2).padding(-1.5) } }
                    .help(today ? (range == .twelveMonths ? "This month, outlined until it ends" : "Today, outlined until the day ends") : "")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .contentShape(Rectangle())
        .onHover { on in
            if on, day != nil { hovered = key } else if hovered == key { hovered = nil }
        }
    }

    private func tip(_ day: SpendDay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(axisLabel(day.day, long: true)) · \(money(day.macUsd + day.cloudUsd))").font(.system(size: 12, weight: .semibold))
            if day.cloudUsd > 0 {
                Text("This Mac \(money(day.macUsd)) · Cloud \(money(day.cloudUsd))").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            ForEach(day.top, id: \.label) { t in
                HStack { Text(t.label).lineLimit(1); Spacer(); Text(money(t.usd)).monospacedDigit() }
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            }
            if day.unknownCalls > 0 {
                Text("\(day.unknownCalls) request\(day.unknownCalls == 1 ? "" : "s") without a price, not in this amount")
                    .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 220, alignment: .leading)
        .background(Color.dsField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.dsLine, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 15, y: 10)
        .allowsHitTesting(false)
    }

    // MARK: By what (§5.3)

    private func groupsSection(_ s: SpendResult) -> some View {
        let shown = showsAll ? s.groups : Array(s.groups.prefix(8))
        let rest = s.groups.dropFirst(8)
        let biggest = max(s.groups.map { $0.plan ? 0 : $0.usd }.max() ?? 0, 0.000_001)
        return plainSection("Where it went", trailing: {
            Menu {
                ForEach(SpendGroupBy.allCases, id: \.self) { g in
                    Button { groupRaw = g.rawValue; showsAll = false } label: { if g == groupBy { Label(Self.groupName(g), systemImage: "checkmark") } else { Text(Self.groupName(g)) } }
                }
            } label: { Text("by \(Self.groupName(groupBy).lowercased())").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2) }
                .menuStyle(.button).buttonStyle(SelectorStyle()).menuIndicator(.hidden).fixedSize()
        }) {
            VStack(alignment: .leading, spacing: 0) {
                if s.groups.isEmpty {
                    FinePrint("Nothing spent in this range.").padding(.vertical, 6)
                }
                ForEach(shown) { g in groupRow(g, biggest: biggest) }
                if !showsAll && !rest.isEmpty {
                    let known = rest.reduce(0) { $0 + $1.usd }, unknown = rest.reduce(0) { $0 + $1.unknownCalls }
                    Button { showsAll = true } label: {
                        Text("\(rest.count) more · \(money(known)) known\(unknown > 0 ? ", \(unknown) without a price" : "")")
                    }
                    .buttonStyle(SelectorStyle()).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func groupRow(_ g: SpendGroup, biggest: Double) -> some View {
        Button { opened = g } label: {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(g.label).lineLimit(1).truncationMode(.tail)
                    if let note = note(g) { Text(note).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                }
                .frame(width: 250, alignment: .leading)
                Meter(value: g.plan ? 0 : g.usd / biggest, fill: DataColor.seq[3])
                Text(g.plan ? Self.tokens(g.tokens) : money(g.usd)).monospacedDigit().frame(width: 76, alignment: .trailing)
                Text(g.plan ? "plan" : "\(Int((g.share * 100).rounded()))%").font(.system(size: 12)).foregroundStyle(Color.dsFg3).monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 13))
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(g.plan ? "On your plan: \(Self.tokens(g.tokens)), not billed per request" : g.unknownCalls > 0 ? "\(g.unknownCalls) request\(g.unknownCalls == 1 ? "" : "s") without a price are not in this amount" : "\(g.calls) request\(g.calls == 1 ? "" : "s")")
    }

    private func note(_ g: SpendGroup) -> String? {
        var parts: [String] = []
        if g.plan { parts.append("on your plan") }
        if g.unknownCalls > 0 { parts.append("\(g.unknownCalls) without a price") }
        if groupBy == .what, g.id.hasPrefix("agent:"), let a = engine.agents.first(where: { "agent:\($0.ref.id)" == g.id }) {
            parts.insert("agent · \(a.agent?.location == "cloud" ? "cloud" : "This Mac")", at: 0)
        } else if groupBy == .what, g.id.hasPrefix("automation:") { parts.insert("automation", at: 0) }
        else if groupBy == .what, g.id == "piopio" { parts.insert("titles, memory, search", at: 0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func groupName(_ g: SpendGroupBy) -> String {
        switch g {
        case .what: "What"
        case .model: "Model"
        case .provider: "Provider"
        case .project: "Project"
        case .where: "Where"
        }
    }

    // MARK: Budgets (§5.4)

    /// Every budget as a meter, two to a row (Redesign A): Piopio's own in yolk first, then agents' and automations'
    /// in grey. Past 80% a meter turns amber, the page's warning.
    private var budgetGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)], alignment: .leading, spacing: 18) {
            piopioBudgetCell
            ForEach(budgets) { b in budgetCell(b) }
        }
    }

    /// Piopio this month (OV3): off until you set it; amber past 80%; at 100% background work waits for your OK.
    @ViewBuilder private var piopioBudgetCell: some View {
        let b = engine.piopioBudget
        let limit = b?.limitUsd
        let used = (limit ?? 0) > 0 ? (b?.spentUsd ?? 0) / limit! : 0
        let warn = b?.state == .near || b?.state == .over || (b?.state == .allowed)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Piopio this month").lineLimit(1)
                InfoMark(text: "Everything Piopio spends on this Mac and in your cloud. At 80% you're told once; at 100% automations wait for your OK, and your conversations keep going.")
                Spacer(minLength: 8)
                if let limit, let b {
                    Text("\(money(b.spentUsd)) of \(money(limit))").foregroundStyle(warn ? Color.dsWarn : Color.dsFg2).monospacedDigit().lineLimit(1)
                } else {
                    Text("no budget").foregroundStyle(Color.dsFg3)
                }
            }
            Meter(value: limit == nil ? 0 : used, fill: warn ? Color.dsWarn : DataColor.yolk)
            HStack(spacing: 2) {
                if let limit, let b {
                    Text(piopioBudgetLine(b, limit: limit)).foregroundStyle(warn ? Color.dsWarn : Color.dsFg3).lineLimit(1)
                    Spacer(minLength: 6)
                    Button("Change…") { budgetText = String(format: "%.0f", limit); editingBudget = true }
                        .buttonStyle(SelectorStyle()).foregroundStyle(Color.dsFg2)
                        .popover(isPresented: $editingBudget, arrowEdge: .bottom) { budgetEditor }
                    Button("Turn off") { setBudget(nil) }.buttonStyle(SelectorStyle()).foregroundStyle(Color.dsFg2)
                } else {
                    Text("Off until you set one").foregroundStyle(Color.dsFg3)
                    Spacer(minLength: 6)
                    Button("Set a budget…") { budgetText = ""; editingBudget = true }
                        .buttonStyle(SelectorStyle()).foregroundStyle(Color.dsFg2)
                        .popover(isPresented: $editingBudget, arrowEdge: .bottom) { budgetEditor }
                }
            }
            .font(.system(size: 12))
        }
        .font(.system(size: 13))
    }

    private func piopioBudgetLine(_ b: PiopioBudget, limit: Double) -> String {
        var parts: [String] = []
        if let resets = Self.date(b.resets) { parts.append("resets \(resets.formatted(.dateTime.day().month(.abbreviated)))") }
        if b.state == .allowed { parts.append("going on at your OK") }
        return parts.joined(separator: " · ")
    }

    /// A dollar amount: at 80% you're told once; at 100% automations wait for your OK. Your conversations never stop.
    private var budgetEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Piopio's budget this month").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                Text("$").foregroundStyle(Color.dsFg2)
                TextField("20", text: $budgetText).textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit(saveBudget)
            }
            Text("At 80% you're told once. At 100% automations wait for your OK; your own conversations keep going.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { editingBudget = false }.buttonStyle(PillStyle(compact: true))
                Button("Save") { saveBudget() }.buttonStyle(PillStyle(kind: .primary, compact: true))
                    .disabled(budgetValue == nil)
            }
        }
        .padding(16).frame(width: 280)
    }

    private var budgetValue: Double? {
        let text = budgetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(text), v > 0 else { return nil }
        return v
    }

    private func saveBudget() {
        guard let v = budgetValue else { return }
        editingBudget = false
        setBudget(v)
    }

    private func setBudget(_ value: Double?) {
        Task {
            do { try await engine.setBudget(value) } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    // MARK: Cheaper next time (§5.5)

    /// At most three, each the number it's based on and one action: Piopio's one remark on the page, in soft yolk.
    private func cheaper(_ list: [SpendSuggestion]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Chick(size: 26)
            VStack(alignment: .leading, spacing: 8) {
                Text("Cheaper next time").font(.system(size: 13, weight: .semibold))
                ForEach(list) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(s.text).font(.system(size: 13)).foregroundStyle(Color.dsFg)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let action = s.action {
                            Button(action.label) { perform(action) }
                                .buttonStyle(PillStyle(kind: .primary, compact: true))
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DataColor.yolkSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func perform(_ action: SpendSuggestion.Action) {
        switch action.kind {
        case .automation:
            if let id = action.id { item = .automation(id) }
        case .agent:
            if let id = action.id { item = engine.item(for: id) ?? .agent(id) }
        case .onDevice:
            Task {
                await engine.updateSettings(SettingsPatch(models: .init(utility: .onDevice)))
                await load()
            }
        }
    }

    private func budgetCell(_ b: Budget) -> some View {
        let used = b.limitUsd > 0 ? b.spentUsd / b.limitUsd : 0
        // Past 80% is the warning (34 §5.4).
        let warn = used >= 0.8
        return Button { open(b) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(b.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(money(b.spentUsd)) of \(money(b.limitUsd))").foregroundStyle(warn ? Color.dsWarn : Color.dsFg2).monospacedDigit().lineLimit(1)
                }
                Meter(value: used, fill: warn ? Color.dsWarn : Color.dsFg2)
                Text(budgetLine(b)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func budgetLine(_ b: Budget) -> String {
        let kind = b.kind == .agent ? "agent" : "automation"
        if b.period == .run { return "\(kind) · its latest run" }
        if let resets = b.resets.flatMap(Self.date) { return "\(kind) · resets \(resets.formatted(.dateTime.day().month(.abbreviated)))" }
        return kind
    }

    private func open(_ b: Budget) {
        if let id = b.automation { item = .automation(id) } else if let ref = b.ref, let target = engine.item(for: ref.id) { item = target }
    }

    // MARK: Empty

    private func empty(_ s: SpendResult) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar").font(.system(size: 22)).foregroundStyle(Color.dsFg3)
            Text(agentName.map { "\($0) hasn't spent anything \(rangePhrase)" } ?? "Nothing spent \(rangePhrase)").font(.system(size: 15, weight: .semibold))
            Text("Each request Piopio makes is counted here as it happens: conversations, Build, agents, automations and Piopio's own work. Nothing leaves this Mac.")
                .font(.system(size: 13)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center).frame(maxWidth: 380)
            if range != .twelveMonths {
                Button("Show 12 Months") { rangeRaw = SpendRange.twelveMonths.rawValue }.buttonStyle(PillStyle(compact: true)).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var rangePhrase: String {
        switch range {
        case .today: "today"
        case .sevenDays: "in the last 7 days"
        case .month: "this month"
        case .lastMonth: "last month"
        case .twelveMonths: "in the last 12 months"
        }
    }

    // MARK: Parts

    /// A 13pt title (and something on the right), then its content; space above, no hairline (Redesign A).
    private func plainSection<Trailing: View, Content: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing()
            }
            content()
        }
        .padding(.top, 28)
    }

    private func load() async {
        guard let client = engine.client else { error = "Connect to the engine to see what Piopio costs."; return }
        do {
            let filter = agent.map { SpendFilter(agent: $0) }
            async let s = client.call("stats.spend", SpendParams(range: range, groupBy: groupBy, filter: filter), as: SpendResult.self)
            async let b = client.call("stats.budgets", Empty(), as: Budgets.self)
            spend = try await s
            let got = try? await b
            budgets = (got?.budgets ?? []).filter { agent == nil || $0.ref?.id == agent }
            if got?.piopio != nil { await engine.loadBudget() }
            error = nil
        } catch {
            if spend == nil { self.error = error.localizedDescription }
        }
        if range == .today || range == .month { await engine.loadUsage() }
    }

    private func export() {
        guard let client = engine.client else { return }
        let range = range
        Task {
            do {
                let out = try await client.call("stats.export", SpendExportParams(range: range), as: SpendExport.self)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "Piopio spend \(Self.rangeName(range).lowercased()).csv"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try out.csv.write(to: url, atomically: true, encoding: .utf8)
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Formatting

    private func money(_ usd: Double) -> String { MainSidebar.money(usd) }

    static func tokens(_ n: Double) -> String {
        let s = n >= 1_000_000 ? String(format: "%.1fM", n / 1_000_000) : n >= 1_000 ? String(format: "%.0fk", n / 1_000) : String(Int(n))
        return "\(s) tokens"
    }

    private func rangeLabel(_ s: SpendResult) -> String {
        guard let from = Self.date(s.from), let to = Self.date(s.to) else { return Self.rangeName(range).lowercased() }
        let end = min(to.addingTimeInterval(-1), Date())
        switch range {
        case .today: return "today"
        case .twelveMonths: return "\(from.formatted(.dateTime.month(.abbreviated).year())) – \(end.formatted(.dateTime.month(.abbreviated).year()))"
        default:
            let cal = Calendar.current
            if cal.isDate(from, equalTo: end, toGranularity: .month) { return "\(cal.component(.day, from: from))–\(end.formatted(.dateTime.day().month(.abbreviated)))" }
            return "\(from.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }

    private func monthName(_ iso: String) -> String { Self.date(iso)?.formatted(.dateTime.month(.wide)) ?? "the month" }

    private func axisLabel(_ key: String?, long: Bool = false) -> String {
        guard let key else { return "" }
        let f = DateFormatter()
        f.dateFormat = key.count == 7 ? "yyyy-MM" : "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        if key.count == 7 { return d.formatted(.dateTime.month(.abbreviated).year(long ? .defaultDigits : .twoDigits)) }
        return long ? d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) : d.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Every bar of the range, days without spend and the rest of an open month included (future ones as a track).
    static func keys(_ s: SpendResult) -> [String] {
        guard let from = date(s.from), let to = date(s.to), from < to else { return s.days.map(\.day) }
        let cal = Calendar.current
        var out: [String] = []
        var d = from
        let monthly = s.range == .twelveMonths
        while d < to && out.count < 400 {
            out.append(monthly ? String(dayKey(d).prefix(7)) : dayKey(d))
            d = cal.date(byAdding: monthly ? .month : .day, value: 1, to: d) ?? to
        }
        // A key the engine sent that the local walk missed (a time-zone edge) still shows.
        for day in s.days where !out.contains(day.day) { out.append(day.day) }
        return out.sorted()
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }
}

/// What one grouped row counts, costliest first (34 §5.3); each opens the conversation or agent.
private struct SpendItemsSheet: View {
    let engine: EngineController
    let range: SpendRange
    let groupBy: SpendGroupBy
    let group: SpendGroup
    let open: (ContainerRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [SpendItem]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.label).font(.system(size: 15, weight: .semibold))
                    Text("\(OverviewPage.rangeName(range)) · \(group.plan ? OverviewPage.tokens(group.tokens) + " on your plan" : MainSidebar.money(group.usd))\(group.unknownCalls > 0 ? " · \(group.unknownCalls) without a price" : "")")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PillStyle(compact: true)).keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 12)
            if let items {
                if items.isEmpty {
                    FinePrint("Nothing to open: these requests weren't part of a conversation.").padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                                Button { open(it.ref) } label: {
                                    HStack(spacing: 10) {
                                        Text(it.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        if let d = OverviewPage.date(it.lastAt) { Text(d.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                                        Text(it.plan ? OverviewPage.tokens(it.tokens) : MainSidebar.money(it.usd)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                    }
                                    .font(.system(size: 13))
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(engine.item(for: it.ref.id) == nil)
                                if i < items.count - 1 { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                            }
                        }
                    }
                }
            } else if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420, alignment: .top)
        .task {
            do {
                guard let client = engine.client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Connect to the engine.") }
                items = try await client.call("stats.items", SpendItemsParams(range: range, groupBy: groupBy, group: group.id), as: SpendItems.self).items
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Overview's tabs (OV2). ⌘K's "Setup" and "Activity" write the key before opening the page.
enum OverviewTab: String, CaseIterable {
    case spend, setup, activity
    static let key = "overviewTab"
    var title: String {
        switch self {
        case .spend: "Spend"
        case .setup: "Setup"
        case .activity: "Activity"
        }
    }
    /// Opens Overview on this tab.
    @MainActor func open() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
        NotificationCenter.default.post(name: .selectItem, object: SidebarItem.overview(nil).raw)
    }
}

/// A bar of 6pt that fills to `value` (0…1): Overview's meters (where it went, budgets).
struct Meter: View {
    let value: Double
    let fill: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dsTrack)
                Capsule().fill(fill).frame(width: max(value > 0 ? height : 0, geo.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A section of Overview: a hairline above, a 12pt title (and something on the right), then its content.
struct OverviewSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).foregroundStyle(Color.dsFg3)
                Spacer()
                trailing()
            }
            .font(.system(size: 12, weight: .medium))
            content()
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
        .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
        .padding(.top, 14)
    }
}
