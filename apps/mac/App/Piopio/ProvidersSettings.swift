import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// A provider sign-in in progress (docs/spec/10-model-providers FR1): pi runs it in the engine, this follows
/// its steps — a browser page, a device code, a key or a pasted code — until it's done or fails.
@MainActor @Observable final class ProviderLogin {
    let provider: ProviderInfo
    let method: AuthMethod
    var loginId: String?
    var url: URL?
    var instructions: String?
    var deviceCode: String?
    var verificationURL: URL?
    var progress: String?
    var info: String?
    var prompt: ProviderAuthEvent?
    var finished = false
    var error: String?

    init(provider: ProviderInfo, method: AuthMethod) {
        self.provider = provider
        self.method = method
    }

    func apply(_ event: ProviderAuthEvent) {
        switch event {
        case .authUrl(let address, let steps):
            url = URL(string: address)
            instructions = steps
            if let url { NSWorkspace.shared.open(url) }
        case .deviceCode(let code, let uri, _):
            deviceCode = code
            verificationURL = URL(string: uri)
        case .progress(let message): progress = message
        case .info(let message, _): info = message
        case .prompt: prompt = event
        case .promptClosed(let id): if case .prompt(id, _, _, _, _)? = prompt { prompt = nil }
        case .done:
            finished = true
            error = nil
        case .failed(let message):
            finished = true
            error = message.isEmpty ? "Couldn't connect." : message
        }
    }
}

/// Where an endpoint or detected server lives, shown as "localhost:4000".
enum ProvidersCard {
    static func host(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host() else { return url }
        return u.port.map { "\(host):\($0)" } ?? host
    }
}

/// The provider's initials on a color of its own (no brand logos).
struct ProviderTile: View {
    let provider: ProviderInfo
    var size: CGFloat = 32

    var body: some View {
        let initials: String = switch provider.id {
        case "openrouter": "OR"
        case "openai": "GPT"
        case "openai-api": "API"
        default: String(provider.name.split(separator: " ").compactMap(\.first).prefix(2)).uppercased()
        }
        Text(initials).font(.system(size: initials.count > 2 ? size * 0.28 : size * 0.34, weight: .semibold)).foregroundStyle(Color.dsFg2)
            .frame(width: size, height: size)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

/// Connecting a provider: whatever step pi is on — a browser page, a device code, a key — then done or why not.
struct ProviderSignInSheet: View {
    let engine: EngineController
    let login: ProviderLogin
    @State private var text = ""
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProviderTile(provider: login.provider, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(login.provider.name)").font(.system(size: 17, weight: .bold))
                    Text(login.provider.methods.first { $0.type == login.method }?.label ?? "").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
            Text(billingNote).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            content
            HStack {
                Spacer()
                if login.finished {
                    if login.error != nil {
                        Button("Close") { Task { await engine.cancelLogin() } }.buttonStyle(PillStyle())
                        Button("Try Again") { Task { await engine.connect(login.provider, method: login.method) } }.buttonStyle(PillStyle(kind: .primary))
                    } else {
                        Button("Done") { Task { await engine.cancelLogin() } }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Cancel") { Task { await engine.cancelLogin() } }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                    if let prompt = login.prompt, case .prompt(_, let kind, _, _, _) = prompt, kind != .select {
                        Button("Continue") { submit() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .onChange(of: login.prompt) { _, _ in text = ""; focused = true }
    }

    @ViewBuilder private var content: some View {
        if login.finished {
            if let error = login.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Connected. Its models are in the model picker now.", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg3)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let code = login.deviceCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter this code on the sign-in page:").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                        HStack(spacing: 10) {
                            Text(code).font(.system(size: 24, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                copied = true
                            }
                            .buttonStyle(PillStyle(compact: true))
                        }
                        if let url = login.verificationURL {
                            Button("Open \(url.host() ?? "the sign-in page")") { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle(kind: .primary, compact: true))
                        }
                    }
                } else if let url = login.url {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(login.instructions ?? "Finish signing in in your browser. This sheet updates when you're done.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                        Button("Open the browser again") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                    }
                }
                if let prompt = login.prompt { promptView(prompt) }
                if login.prompt == nil, login.deviceCode == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(login.progress ?? (login.url == nil ? "Starting…" : "Waiting for the browser…")).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                    }
                }
                if let info = login.info { Text(info).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    @ViewBuilder private func promptView(_ event: ProviderAuthEvent) -> some View {
        if case .prompt(_, let kind, let message, let placeholder, let options) = event {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).font(.system(size: 12.5, weight: .medium))
            switch kind {
            case .select:
                VStack(spacing: 6) {
                    ForEach(options ?? [], id: \.id) { option in
                        Button { Task { await engine.answerLogin(option.id) } } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg)
                                if let d = option.description { Text(d).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .secret:
                SecureField(placeholder ?? "", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).focused($focused).onSubmit(submit)
            case .text, .manualCode:
                TextField(placeholder ?? (kind == .manualCode ? "Paste the address the browser ended on" : ""), text: $text)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13)).focused($focused).onSubmit(submit)
            }
        }
        }
    }

    private var billingNote: String {
        let p = login.provider
        if login.method == .oauth, login.provider.methods.first(where: { $0.type == .oauth })?.subscription == true {
            return "Requests use your \(p.id == "openai" ? "ChatGPT" : p.name) plan and its limits. They aren't billed to OpenRouter or an API account."
        }
        if p.id == "openai-api" { return "Requests are billed to the OpenAI API account this key belongs to, separately from a ChatGPT subscription." }
        return "Requests are billed to your \(p.name) account. The key is stored in the macOS Keychain."
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { await engine.answerLogin(value) }
    }
}

/// An endpoint's initials ("LiteLLM (home)" → "LH") on a color of its own.
struct EndpointTile: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        let words = name.split(separator: " ").map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        let initials = (words.count > 1 ? String(words[0].prefix(1) + words[1].prefix(1)) : String(words.first?.prefix(2) ?? "?")).uppercased()
        Text(initials).font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(Color.dsFg2)
            .frame(width: size, height: size)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}
