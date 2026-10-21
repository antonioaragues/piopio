import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// The Inbox (06-agents §12, docs/design 4d): approvals, messages agents sent you on their own, failed runs and
/// budget notes, across agents. The detail shows the conversation it came from and, for an approval, what the agent
/// proposes, which you can edit before approving.
struct InboxView: View {
    let engine: EngineController
    /// Selects an agent's page (Open conversation).
    @Binding var agentSelection: String?
    @AppStorage("inboxFilter") private var needsYouOnly = true
    /// An item to show (an approval id from a card or a notification), set by `.openInbox`.
    @AppStorage("inboxFocus") private var focus = ""
    @State private var selected: String?

    private var items: [InboxItem] { engine.inbox.filter { !needsYouOnly || $0.needsYou } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Inbox").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Picker("", selection: $needsYouOnly) {
                        Text("Needs you").tag(true)
                        Text("All").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in row(item) }
                    }
                    .padding(.horizontal, 8)
                }
                .overlay {
                    if items.isEmpty {
                        Text(needsYouOnly ? "Nothing needs you." : "Nothing here yet.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    }
                }
            }
            .frame(width: 380)
            Rectangle().fill(Color.dsLine).frame(width: 0.5)
            if let item = engine.inbox.first(where: { $0.id == selected }) {
                InboxDetail(engine: engine, item: item) { open(item) }
                    .id(item.id)
            } else {
                Text("Pick an item.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await engine.loadInbox() }
        .onAppear(perform: applyFocus)
        .onChange(of: focus) { _, _ in applyFocus() }
        .onChange(of: engine.inbox) { _, _ in
            applyFocus()
            if selected == nil || !engine.inbox.contains(where: { $0.id == selected }) { selected = items.first?.id }
        }
        .onChange(of: selected) { _, id in
            guard let item = engine.inbox.first(where: { $0.id == id }) else { return }
            Task { await engine.markInboxRead([item]) }
        }
    }

    private func applyFocus() {
        guard !focus.isEmpty, let item = engine.inbox.first(where: { $0.approval?.approvalId == focus || $0.id == focus }) else { return }
        if !item.needsYou { needsYouOnly = false }
        selected = item.id
        focus = ""
    }

    private func open(_ item: InboxItem) {
        let conversation = item.conversationId ?? "person:owner"
        UserDefaults.standard.set(conversation.hasPrefix("run:") ? AgentPage.Tab.runs.rawValue : conversation == "person:owner" ? AgentPage.Tab.chat.rawValue : AgentPage.Tab.conversations.rawValue, forKey: "agentTab")
        agentSelection = item.agent.id
    }

    private func row(_ item: InboxItem) -> some View {
        Button { selected = item.id } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(item.avatar == nil ? 0.85 : 0.14))
                    Text(item.avatar ?? String(item.agentName.prefix(1)).uppercased())
                        .font(.system(size: item.avatar == nil ? 12 : 15, weight: .semibold))
                        .foregroundStyle(item.avatar == nil ? Color.white : Color.dsFg)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.agentName).font(.system(size: 13, weight: item.needsYou ? .semibold : .medium)).foregroundStyle(Color.dsFg)
                        Spacer()
                        Text(BuildSessionView.relative(item.at)).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(Self.color(item)).frame(width: 6, height: 6)
                        Text(Self.kindLabel(item)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2)
                    }
                    Text(item.approval?.title ?? item.body).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .background(selected == item.id ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func kindLabel(_ item: InboxItem) -> String {
        switch item.kind {
        case "approval":
            switch item.approval?.status {
            case .pending?: return "Approval"
            case .approved?: return "Approved"
            case .denied?: return "Declined"
            case .expired?: return "Expired"
            default: return "Cancelled"
            }
        case "message": return "Message for you"
        case "run_failed": return "Run failed"
        case "budget": return item.title
        case "paused": return "Paused"
        default: return item.title
        }
    }

    static func color(_ item: InboxItem) -> Color {
        switch item.kind {
        case "approval": item.approval?.status == .pending ? .dsAmber : item.approval?.status == .approved ? .dsGreen : Color.dsFg3
        case "run_failed": .dsRed
        case "message": .accentColor
        case "budget": .dsAmber
        default: Color.dsFg3
        }
    }
}

/// One Inbox item: the conversation it's about, and an approval's proposed action with Reject / Edit / Approve.
private struct InboxDetail: View {
    let engine: EngineController
    let item: InboxItem
    let open: () -> Void
    @State private var editing = false
    @State private var text = ""
    @State private var always = false
    @State private var error: String?
    @State private var busy = false

    private var conversation: ContainerRef? {
        guard let id = item.conversationId else { return nil }
        return ContainerRef(kind: .agent, id: item.agent.id, conversationId: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.agentName) · \(InboxView.kindLabel(item))").font(.system(size: 14, weight: .semibold))
                    Text(item.approval == nil ? item.title : "\(item.agentName) wants to: \(item.approval!.title)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer()
                if item.conversationId != nil { Button("Open conversation", action: open).buttonStyle(PillStyle(compact: true)) }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            ZStack(alignment: .bottom) {
                if let conversation {
                    AgentRunTranscript(engine: engine, ref: conversation)
                } else {
                    Text(item.body).font(.system(size: 13)).foregroundStyle(Color.dsFg2).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let approval = item.approval, approval.status == .pending { proposal(approval) }
            }
        }
    }

    /// docs/design 4d "Proposed by …": the action, editable before approving.
    private func proposal(_ a: ApprovalItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color.dsAmber).frame(width: 7, height: 7)
                Text("Proposed by \(item.agentName)").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("expires \(AgentRunsView.when(a.expiresAt))").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.actionLabel(a)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                if editing {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: Self.textField(a) == nil ? .monospaced : .default))
                        .frame(minHeight: 60, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                } else {
                    Text(Self.textField(a).flatMap { a.args[$0]?.stringValue } ?? a.title).font(.system(size: 13)).textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Color.dsRed) }
            HStack(spacing: 8) {
                Button("Reject") { decide(false) }.buttonStyle(PillStyle(compact: true))
                Button(editing ? "Cancel edit" : "Edit") { toggleEdit(a) }.buttonStyle(PillStyle(compact: true))
                Toggle(a.always, isOn: $always).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                Spacer()
                Button(editing ? "Approve edited ↩" : "Approve ↩") { decide(true, edited: editing ? a : nil) }
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                    .keyboardShortcut(.return, modifiers: [])
            }
            .disabled(busy)
        }
        .padding(14)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsAccentLine, lineWidth: 1))
        .background(Color.dsAccentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card + 4).inset(by: -4))
        .padding(16)
    }

    private func toggleEdit(_ a: ApprovalItem) {
        if !editing {
            if let field = Self.textField(a) { text = a.args[field]?.stringValue ?? "" } else { text = a.args.prettyJSON }
        }
        editing.toggle()
    }

    private func decide(_ approve: Bool, edited a: ApprovalItem? = nil) {
        var args: JSONValue?
        if let a {
            if let field = Self.textField(a), case .object(var o) = a.args {
                o[field] = .string(text)
                args = .object(o)
            } else {
                guard let data = text.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = parsed else {
                    error = "That isn't a JSON object."
                    return
                }
                args = parsed
            }
        }
        busy = true
        error = nil
        Task {
            do {
                try await engine.decide(item.agent, approvalId: item.approval!.approvalId, approve: approve, args: args, always: approve && always)
            } catch {
                self.error = (error as? EngineError)?.message ?? String(describing: error)
            }
            busy = false
        }
    }

    /// The one argument worth editing as text (a message's words), or nil to edit the JSON.
    static func textField(_ a: ApprovalItem) -> String? {
        switch a.tool {
        case "send_message": "text"
        case "schedule": "prompt"
        case "remember": "fact"
        default: nil
        }
    }

    static func actionLabel(_ a: ApprovalItem) -> String {
        switch a.tool {
        case "send_message": "Send message · to \(a.args["to"]?.stringValue ?? "")"
        case "schedule": "Schedule · \(a.args["when"]?.stringValue ?? "")"
        case "remember": "Save to memory"
        default: a.tool
        }
    }
}

private extension JSONValue {
    /// Indented JSON, keys sorted (for editing an approval's arguments).
    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// The menu bar's Inbox: what needs you, newest first; picking one opens it.
struct InboxMenu: View {
    let engine: EngineController

    var body: some View {
        let waiting = engine.inbox.filter(\.needsYou)
        if waiting.isEmpty { Text("Nothing needs you") }
        ForEach(waiting.prefix(8)) { item in
            Button("\(item.agentName): \(item.approval?.title ?? item.body)".prefix(80)) { show(item.approval?.approvalId ?? item.id) }
        }
        Divider()
        Button("Open Inbox") { show(nil) }
    }

    private func show(_ id: String?) {
        WindowOpener.shared.showMain()
        NotificationCenter.default.post(name: .openInbox, object: id)
    }
}
