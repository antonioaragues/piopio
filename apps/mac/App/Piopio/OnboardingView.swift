import PiopioKit
import SwiftUI

/// First launch: store the OpenRouter key in the Keychain.
struct OnboardingView: View {
    let engine: EngineController
    let done: () -> Void
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Piopio").font(.title.bold())
            Text("Piopio talks to models through OpenRouter with your own key. It's stored in your Keychain and only sent to OpenRouter.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("OpenRouter API key (sk-or-…)", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.callout)
                Spacer()
                Button("Later") { done() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() {
        Task {
            do {
                try await engine.saveKey(key)
                done()
            } catch {
                self.error = "Couldn't save to the Keychain: \(error.localizedDescription)"
            }
        }
    }
}

struct SettingsView: View {
    let engine: EngineController
    @State private var key = ""
    @State private var saved = false
    @State private var showModels = false

    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("API key") {
                    HStack {
                        SecureField(engine.hasKey ? "Saved in Keychain" : "sk-or-…", text: $key)
                            .frame(width: 260)
                        Button("Save") {
                            Task {
                                try? await engine.saveKey(key)
                                key = ""
                                saved = true
                            }
                        }
                        .disabled(key.isEmpty)
                        if engine.hasKey {
                            Button("Remove", role: .destructive) { Task { await engine.removeKey() } }
                        }
                    }
                }
                if saved { Text("Saved.").foregroundStyle(.secondary) }
            }
            Section("Chat") {
                LabeledContent("Default model for new threads") {
                    Button(engine.model(engine.preferredModel)?.name ?? engine.preferredModel?.id ?? "Choose…") { showModels = true }
                        .popover(isPresented: $showModels) {
                            ModelPicker(engine: engine, selected: engine.preferredModel) { model in
                                engine.setPreferredModel(model)
                                showModels = false
                            }
                        }
                }
            }
            Section("Engine") {
                LabeledContent("Data folder") { Text(engine.home.path).textSelection(.enabled).foregroundStyle(.secondary) }
                LabeledContent("Status") { Text(statusText).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    private var statusText: String {
        switch engine.status {
        case .starting: "Starting…"
        case .ready: engine.faux ? "Running (scripted model)" : "Running"
        case .failed(let m): "Failed: \(m)"
        }
    }
}
