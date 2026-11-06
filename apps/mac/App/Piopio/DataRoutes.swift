import PiopioKit
import SwiftUI

// Where your content goes (docs/spec/07-shared §1.3): background model work runs on this Mac by default, learned facts
// only once you pick a model, and nothing switches to another provider by itself. Settings › Models shows every
// route in one card; Settings › Memory picks the model for learned facts.

extension EngineController {
    /// A provider's name, and whether it runs on this Mac (a local endpoint such as Ollama or LM Studio).
    func providerPlace(_ id: String) -> (name: String, local: Bool) {
        let p = providers.first { $0.id == id }
        return (p?.name ?? id, p?.endpoint?.local == true)
    }

    /// Where a utility choice sends its content, in a word, and why when it can't run.
    func place(of choice: UtilityChoice, onDevice: OnDeviceStatus?) -> (place: String, note: String?) {
        switch choice {
        case .off: return ("Off", nil)
        case .onDevice:
            if let onDevice, !onDevice.available { return ("Skipped", onDevice.reason) }
            return ("This Mac", nil)
        case .model(let ref):
            let p = providerPlace(ref.provider)
            return (p.local ? "This Mac" : p.name, model(ref).map(ModelChip.short) ?? ref.id)
        }
    }
}

/// A pill menu: On this Mac (Apple's model), a model you pick, or Off.
struct UtilityChoicePicker: View {
    let engine: EngineController
    let choice: UtilityChoice
    let onDevice: OnDeviceStatus?
    let set: (UtilityChoice) -> Void
    @State private var pickingModel = false

    var body: some View {
        Menu {
            item("On this Mac (Apple)", choice == .onDevice) { set(.onDevice) }
            item(modelTitle ?? "A model…", modelTitle != nil) { pickingModel = true }
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
        case .onDevice: onDevice?.available == false ? "On this Mac · unavailable" : "On this Mac"
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

/// "What leaves this Mac": each kind of content and where it goes now.
struct DataRoutesCard: View {
    let engine: EngineController
    let onDevice: OnDeviceStatus?

    private var settings: EngineSettings? { engine.settings }

    var body: some View {
        CardTitle("What leaves this Mac")
        ListCard {
            route("Your conversations", conversations.detail, conversations.place)
            route("Background work", "Titles, topic summaries, suggested replies, notebook suggestions, commit messages", utility.place, note: utility.note)
            route("Learned facts", "What agents learn by themselves from conversations (Settings › Memory)", learning.place, note: learning.note)
            route("Web search", "Only when a chat or agent searches: the search words, not the conversation", webSearch)
            route("Memory search", memorySearch.detail, memorySearch.place, last: true)
        }
        FinePrint("Connected apps and MCP servers get what their tools are given. Nothing goes to Piopio: there's no Piopio server.").padding(.top, 8)
    }

    private var conversations: (place: String, detail: String) {
        guard let ref = engine.model(for: .chat) else { return ("Each model", "To the model each one uses") }
        let p = engine.providerPlace(ref.provider)
        return (p.local ? "This Mac" : p.name, "To the model each one uses (\(engine.model(ref).map(ModelChip.short) ?? ref.id) by default). Models on this Mac keep them here.")
    }

    private var utility: (place: String, note: String?) { engine.place(of: settings?.models?.utility ?? .onDevice, onDevice: onDevice) }
    private var learning: (place: String, note: String?) { engine.place(of: settings?.models?.learning ?? .off, onDevice: onDevice) }

    private var webSearch: String {
        engine.providers.contains { $0.id == "openrouter" && $0.isConnected } ? "OpenRouter" : "Unavailable"
    }

    private var memorySearch: (place: String, detail: String) {
        settings?.memory.searchesByMeaning == true
            ? ("OpenRouter", "Memories are sent to be indexed by meaning (Settings › Memory)")
            : ("This Mac", "By words; nothing is sent (Settings › Memory)")
    }

    private func route(_ title: String, _ detail: String, _ place: String, note: String? = nil, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(place).font(.system(size: 12.5, weight: .medium)).foregroundStyle(place == "This Mac" || place == "Off" ? Color.dsFg2 : Color.dsFg)
                    if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).multilineTextAlignment(.trailing).frame(maxWidth: 220, alignment: .trailing) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if !last { RowDivider(inset: 14) }
        }
    }
}
