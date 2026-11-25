import PiopioKit
import SwiftUI

/// Edit… on a /learn card (docs/spec/14 M5, docs/design/learn): each thing's words and where it goes, or drop it.
/// Save writes what's ready; one still missing something says what, and isn't written. Dropping everything dismisses
/// the card.
struct LearnEditSheet: View {
    let edit: LearnEdit
    let save: ([LearnItem]) -> Void
    let cancel: () -> Void
    /// The items as rows with ids of their own: an item's id is made of its words, so it changes as you type, and a
    /// row keyed by it would be a new row (losing the field you're typing in) at each key.
    @State private var rows: [Row]
    private struct Row: Identifiable { let id = UUID(); var item: LearnItem }

    init(edit: LearnEdit, save: @escaping ([LearnItem]) -> Void, cancel: @escaping () -> Void) {
        self.edit = edit
        _rows = State(initialValue: edit.items.map { Row(item: $0) })
        self.save = save
        self.cancel = cancel
    }

    /// What Save writes: the items that aren't missing anything.
    private var kept: [LearnItem] { rows.map(\.item).filter(\.missing.isEmpty) }
    private var unfinished: Int { rows.count - kept.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What to keep").font(.system(size: 15, weight: .semibold))
                Text("Change the words, where each goes, or drop it. Nothing is written until Save.")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($rows) { $row in self.row($row.item) { rows.removeAll { $0.id == row.id } } }
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            HStack(spacing: 10) {
                if unfinished > 0 {
                    Text(unfinished == 1 ? "1 isn't finished and won't be saved" : "\(unfinished) aren't finished and won't be saved")
                        .font(.system(size: 12)).foregroundStyle(Color.dsAmber)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                // Dismiss only once you've dropped everything; while something's unfinished, Save waits for it.
                Button(rows.isEmpty ? "Dismiss" : "Save \(kept.count)") { save(kept) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillStyle(kind: .strong, compact: true))
                    .disabled(!rows.isEmpty && kept.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: min(620, CGFloat(170 + rows.reduce(0) { $0 + ($1.item.to == .skill ? 230 : 96) })))
    }

    private func row(_ item: Binding<LearnItem>, drop: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: item.to) {
                    if edit.hasProject { Text(edit.file ?? "AGENTS.md").tag(LearnItem.Destination.project) }
                    Text("About me").tag(LearnItem.Destination.aboutMe)
                    Text(item.wrappedValue.addTo.map { "Add to \($0)" } ?? "A skill").tag(LearnItem.Destination.skill)
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Where it goes")
                if item.wrappedValue.to == .skill {
                    TextField("Name", text: Binding(get: { item.wrappedValue.addTo ?? item.wrappedValue.name ?? "" }, set: { item.wrappedValue.name = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 170).disabled(item.wrappedValue.addTo != nil)
                        .help("Lowercase with hyphens: it's how /skill:name calls it")
                    if edit.hasProject {
                        Toggle("Only this project", isOn: Binding(get: { item.wrappedValue.projectOnly ?? false }, set: { item.wrappedValue.projectOnly = $0 ? true : nil }))
                            .toggleStyle(.checkbox).font(.system(size: 12)).disabled(item.wrappedValue.addTo != nil)
                    }
                }
                if item.wrappedValue.to == .project {
                    TextField("Section", text: Binding(get: { item.wrappedValue.section ?? "" }, set: { item.wrappedValue.section = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                        .help("The section of \(edit.file ?? "AGENTS.md") it goes under")
                }
                Spacer()
                Button(action: drop) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Don't keep this")
                    .accessibilityLabel("Don't keep this")
            }
            TextField(item.wrappedValue.to == .skill ? "Used when…" : "", text: item.text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
                .help(item.wrappedValue.to == .skill ? "When the skill is used: what the model reads to decide to load it" : "")
            if item.wrappedValue.to == .skill {
                TextEditor(text: Binding(get: { item.wrappedValue.body ?? "" }, set: { item.wrappedValue.body = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.dsLine, lineWidth: 0.5))
            }
            if let why = item.wrappedValue.why { Text(why).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
            let missing = item.wrappedValue.missing
            if !missing.isEmpty { Text("Needs \(LearnItem.listed(missing))").font(.system(size: 11.5)).foregroundStyle(Color.dsAmber) }
        }
    }
}
