import PiopioKit
import SwiftUI

// Background model work (docs/spec/07-shared §1.3): titles, summaries, suggested replies, commit messages and learned
// facts. Automatic by default: each conversation's own provider. Settings › Models can pin another choice.

/// A pill menu: Automatic, Apple's on-device model, a model you pick, or Off.
struct UtilityChoicePicker: View {
    let engine: EngineController
    let choice: UtilityChoice
    let onDevice: OnDeviceStatus?
    let set: (UtilityChoice) -> Void
    @State private var pickingModel = false

    var body: some View {
        Menu {
            item("Automatic", choice == .auto) { set(.auto) }
            item(modelTitle ?? "A model…", modelTitle != nil) { pickingModel = true }
            if onDevice?.available == true { item("Apple's model, on this Mac", choice == .onDevice) { set(.onDevice) } }
            Divider()
            item("Off", choice == .off) { set(.off) }
        } label: {
            Text(label).font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.button).buttonStyle(PillStyle(compact: true)).fixedSize()
        .popover(isPresented: $pickingModel) {
            ModelPicker(engine: engine, selected: picked, role: .chat) { m in set(.model(m)); pickingModel = false }
        }
    }

    private var picked: ModelRef? { if case .model(let ref) = choice { ref } else { nil } }
    private var modelTitle: String? { picked.map { engine.model($0).map(ModelChip.short) ?? $0.id } }

    private var label: String {
        switch choice {
        case .auto: "Automatic"
        case .onDevice: onDevice?.available == false ? "Apple's model · unavailable" : "Apple's model"
        case .off: "Off"
        case .model: modelTitle ?? "A model"
        }
    }

    @ViewBuilder private func item(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
