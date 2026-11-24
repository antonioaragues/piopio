import PiopioKit
import SwiftUI

/// Edit… on a /learn card (docs/spec/14 M5, docs/design/learn): each thing's words and where it goes, or drop it.
/// Save writes what's left; dropping everything dismisses the card.
struct LearnEditSheet: View {
    @State var edit: LearnEdit
    let save: ([LearnItem]) -> Void
    let cancel: () -> Void

    init(edit: LearnEdit, save: @escaping ([LearnItem]) -> Void, cancel: @escaping () -> Void) {
        _edit = State(initialValue: edit)
        self.save = save
        self.cancel = cancel
    }

    /// What Save writes: items with words; a skill also needs a name and instructions.
    private var kept: [LearnItem] {
        edit.items.filter { item in
            let has = { (s: String?) in !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return has(item.text) && (item.to != .skill || (has(item.name) || has(item.addTo)) && has(item.body))
        }
    }

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
                    ForEach($edit.items) { $item in row($item) }
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(kept.isEmpty ? "Dismiss" : "Save \(kept.count)") { save(kept) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillStyle(kind: .strong, compact: true))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: min(620, CGFloat(170 + edit.items.reduce(0) { $0 + ($1.to == .skill ? 230 : 96) })))
    }

    private func row(_ item: Binding<LearnItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: item.to) {
                    if edit.hasProject { Text(edit.file ?? "AGENTS.md").tag(LearnItem.Destination.project) }
                    Text("About me").tag(LearnItem.Destination.aboutMe)
                    Text(item.wrappedValue.addTo.map { "Add to \($0)" } ?? "A skill").tag(LearnItem.Destination.skill)
                }
                .labelsHidden().fixedSize()
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
                Button { edit.items.removeAll { $0.id == item.wrappedValue.id } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Don't keep this")
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
        }
    }
}
