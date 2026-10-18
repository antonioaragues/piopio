import PiopioKit
import SwiftUI

/// Searchable list of the engine's models with price and context size.
struct ModelPicker: View {
    let engine: EngineController
    let selected: ModelRef?
    let onPick: (ModelRef) -> Void
    @State private var query = ""
    @State private var reasoningOnly = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search models", text: $query)
                    .textFieldStyle(.roundedBorder)
                Toggle("Reasoning", isOn: $reasoningOnly).toggleStyle(.button).controlSize(.small)
            }
            .padding(10)
            Divider()
            List(filtered) { model in
                Button { onPick(model.ref) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(model.name).fontWeight(isSelected(model) ? .semibold : .regular)
                                if model.supports.reasoning { Image(systemName: "brain").foregroundStyle(.secondary).font(.caption) }
                                if model.supports.vision { Image(systemName: "eye").foregroundStyle(.secondary).font(.caption) }
                            }
                            Text(model.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(price(model)).font(.caption.monospacedDigit())
                            Text(context(model)).font(.caption).foregroundStyle(.secondary)
                        }
                        if isSelected(model) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 460, height: 420)
    }

    private var filtered: [ModelInfo] {
        let terms = query.lowercased().split(separator: " ")
        return engine.models.filter { m in
            (!reasoningOnly || m.supports.reasoning) && terms.allSatisfy { m.name.lowercased().contains($0) || m.id.lowercased().contains($0) }
        }
    }

    private func isSelected(_ m: ModelInfo) -> Bool { selected?.provider == m.provider && selected?.id == m.id }

    private func price(_ m: ModelInfo) -> String {
        if m.pricing.input == 0, m.pricing.output == 0 { return "free" }
        return String(format: "$%.2f / $%.2f", m.pricing.input, m.pricing.output)
    }

    private func context(_ m: ModelInfo) -> String {
        m.contextWindow >= 1_000_000 ? String(format: "%.1fM ctx", m.contextWindow / 1_000_000) : "\(Int(m.contextWindow / 1000))k ctx"
    }
}
