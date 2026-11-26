import PiopioKit
import SwiftUI

/// Your subagents in Settings › Extensions (roadmap PAR12, docs/spec/05-build §4 "Custom subagents"): pi's agent files
/// in ~/.pi/agent/agents, which a conversation's `task` hands work to by name. A project's own, in its .pi/agents, load
/// while it's trusted and aren't listed here. New subagent, or a row, opens its sheet.
struct YourSubagentsCard: View {
    let engine: EngineController
    @State private var subagents: [CustomSubagentInfo] = []
    @State private var editing: SubagentEditTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Your subagents") {
                Button("New subagent") { editing = SubagentEditTarget(path: nil) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
            }
            ListCard {
                if subagents.isEmpty {
                    Text("None yet. A subagent has its own instructions, and can have fewer tools or another model: a scout that only reads, a reviewer, a test runner.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 52, alignment: .leading)
                }
                ForEach(Array(subagents.enumerated()), id: \.element.id) { i, agent in
                    Button { editing = SubagentEditTarget(path: agent.path) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 14)).foregroundStyle(Color.dsFg2).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(agent.name).font(.system(size: 13.5, weight: .semibold))
                                    if let summary = Self.summary(agent) { Text(summary).font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
                                }
                                Text(agent.description).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                    if i < subagents.count - 1 { RowDivider() }
                }
            }
            FinePrint("Saved in ~/.pi/agent/agents, where pi's subagents find them too. A conversation hands one work when its description fits the task, or when you ask for it by name.")
                .padding(.top, 10)
        }
        .task {
            await load()
            // PIOPIO_DEMO_SUBAGENT=<name>|new: captures open that subagent's sheet, or a new one.
            guard let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_SUBAGENT"] else { return }
            editing = SubagentEditTarget(path: demo == "new" ? nil : subagents.first { $0.name == demo }?.path)
        }
        .sheet(item: $editing) { target in
            SubagentSheet(engine: engine, path: target.path) { editing = nil; Task { await load() } }
        }
    }

    /// "read, grep · haiku": its tools and model, when it narrows them.
    static func summary(_ agent: CustomSubagentInfo) -> String? {
        let parts = [agent.tools.map { $0.joined(separator: ", ") }, agent.model].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        subagents = ((try? await engine.client?.call("subagents.list", SubagentsListParams(), as: SubagentsResult.self).subagents) ?? [])
            .filter { $0.where == .yours }
    }
}

struct SubagentEditTarget: Identifiable {
    let path: String?
    var id: String { path ?? "new" }
}

/// One subagent: its name, what it's for, its instructions, which tools it gets and its model. Delete moves its file
/// to the Trash.
struct SubagentSheet: View {
    let engine: EngineController
    let path: String?
    let done: () -> Void
    @State private var name = ""
    @State private var usedFor = ""
    @State private var instructions = ""
    @State private var someTools = false
    @State private var tools: Set<String> = ["read", "grep", "find", "ls"]
    @State private var otherTools = ""
    @State private var model = ""
    @State private var error: String?
    @State private var confirmDelete = false

    /// pi's and Piopio's common tools, offered as boxes; any other name goes in the field below them.
    static let common = ["read", "grep", "find", "ls", "bash", "edit", "write", "web_search", "web_fetch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(path == nil ? "New subagent" : "Subagent").font(.system(size: 15, weight: .semibold))
            field("Name", hint: "Lowercase with hyphens; the conversation names it to hand it a task") {
                TextField("scout", text: $name).textFieldStyle(.roundedBorder)
            }
            field("Use it for", hint: "What the conversation reads to decide to hand it work") {
                TextField("Reading a part of the code and reporting what's there, briefly", text: $usedFor, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            }
            field("Instructions", hint: "Markdown, added to its system prompt: how to work and what to report back") {
                TextEditor(text: $instructions).font(.system(size: 12, design: .monospaced)).frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.dsLine, lineWidth: 0.5))
            }
            field("Tools", hint: someTools ? "Never more than the conversation that hands it the task has" : "The same tools and permissions as the conversation that hands it the task") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $someTools) {
                        Text("The conversation's").tag(false)
                        Text("Only these").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if someTools {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 6) {
                            ForEach(Self.common, id: \.self) { tool in
                                Toggle(tool, isOn: Binding(get: { tools.contains(tool) }, set: { on in if on { tools.insert(tool) } else { tools.remove(tool) } }))
                                    .toggleStyle(.checkbox).font(.system(size: 12, design: .monospaced))
                            }
                        }
                        // Verbatim: as a LocalizedStringKey, `*…*` and `__…__` are Markdown and the asterisks vanish.
                        TextField("", text: $otherTools, prompt: Text(verbatim: "Others, by name (web_*, mcp__github__*)")).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    }
                }
            }
            field("Model", hint: "provider/id or an id, as in pi; empty, or not on this Mac, it uses the conversation's") {
                TextField("The conversation's", text: $model).textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
            HStack(spacing: 10) {
                if path != nil {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(PillStyle(kind: .strong, compact: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || usedFor.trimmingCharacters(in: .whitespaces).isEmpty || (someTools && chosenTools.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive, action: delete)
        } message: { Text("Its file goes to the Trash; conversations stop offering it.") }
    }

    private var chosenTools: [String] {
        let others = otherTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Self.common.filter { tools.contains($0) } + others.filter { !Self.common.contains($0) }
    }

    private func field(_ title: String, hint: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
            content()
            Text(hint).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
    }

    private func load() async {
        guard let path, let got = try? await engine.client?.call("subagents.get", SubagentPathParams(path: path), as: SubagentResult.self) else { return }
        name = got.info.name; usedFor = got.info.description; instructions = got.instructions; model = got.info.model ?? ""
        if let list = got.info.tools {
            someTools = true
            tools = Set(list.filter { Self.common.contains($0) })
            otherTools = list.filter { !Self.common.contains($0) }.joined(separator: ", ")
        }
    }

    private func save() {
        let model = self.model.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await engine.client?.call("subagents.save", SubagentSaveParams(path: path, name: name, description: usedFor, tools: someTools ? chosenTools : nil, model: model.isEmpty ? nil : model, instructions: instructions), as: SubagentSaveResult.self)
                done()
            } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }

    private func delete() {
        guard let path else { return }
        Task {
            do { try await engine.spaceCall("subagents.delete", SubagentPathParams(path: path)); done() }
            catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }
}
