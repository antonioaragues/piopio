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

    private var kept: [LearnItem] { edit.items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

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
        .frame(width: 520, height: min(560, CGFloat(170 + edit.items.count * 96)))
    }

    private func row(_ item: Binding<LearnItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: item.to) {
                    if edit.hasProject { Text(edit.file ?? "AGENTS.md").tag(LearnItem.Destination.project) }
                    Text("About me").tag(LearnItem.Destination.aboutMe)
                }
                .labelsHidden().fixedSize()
                if item.wrappedValue.to == .project {
                    TextField("Section", text: Binding(get: { item.wrappedValue.section ?? "" }, set: { item.wrappedValue.section = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                        .help("The section of \(edit.file ?? "AGENTS.md") it goes under")
                }
                Spacer()
                Button { edit.items.removeAll { $0.id == item.wrappedValue.id } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Don't keep this")
            }
            TextField("", text: item.text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
            if let why = item.wrappedValue.why { Text(why).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
        }
    }
}
