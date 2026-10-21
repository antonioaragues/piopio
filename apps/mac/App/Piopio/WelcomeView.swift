import PiopioKit
import PiopioTranscript
import SwiftUI

/// First run (docs/design 5a): connect a model provider. Providers are a list; OpenRouter is the first.
struct WelcomeView: View {
    let engine: EngineController
    let done: () -> Void
    @State private var key = ""
    @State private var check: KeyCheck = .idle
    @State private var checkTask: Task<Void, Never>?

    enum KeyCheck: Equatable { case idle, checking, verified, failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // docs/design 5a: the app icon (the chick, light or dark with the system).
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                        .padding(.top, 30)
                    Text("Welcome to Piopio").font(.system(size: 28, weight: .bold)).tracking(-0.5).padding(.top, 22)
                    Text("Build, chat and run agents on the pi harness. Everything stays on this Mac or in your own accounts.")
                        .font(.system(size: 13.5)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center).frame(maxWidth: 440).padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect a model provider").font(.system(size: 13, weight: .semibold))
                        VStack(spacing: 0) {
                            openRouterRow
                            Rectangle().fill(Color.dsLine).frame(height: 0.5)
                            HStack(spacing: 10) {
                                Image(systemName: "circle").foregroundStyle(Color.dsFg3)
                                Text("ChatGPT subscription").font(.system(size: 13))
                                Text("Sign in with OpenAI").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                                Spacer()
                                Badge("Soon")
                            }
                            .padding(12)
                            .opacity(0.7)
                        }
                        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
                        Text("Stored in your Keychain. You can add more providers later.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    .frame(width: 460)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack {
                HStack(spacing: 4) {
                    Capsule().fill(Color.accentColor).frame(width: 18, height: 5)
                    Circle().fill(Color.dsFg3.opacity(0.4)).frame(width: 5, height: 5)
                }
                Spacer()
                Button("Later") { done() }.buttonStyle(.plain).foregroundStyle(Color.dsFg2).font(.system(size: 13))
                Button("Continue") { save() }
                    .buttonStyle(PillStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || check == .checking)
            }
            .padding(.horizontal, 22)
            .frame(height: 60)
        }
        .frame(width: 760, height: 560)
        .background(Color.dsWin)
    }

    private var openRouterRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "largecircle.fill.circle").foregroundStyle(Color.accentColor)
                Text("OpenRouter").font(.system(size: 13, weight: .semibold))
                Text("API key · many models").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
                switch check {
                case .idle: EmptyView()
                case .checking: ProgressView().controlSize(.mini)
                case .verified: Text("✓ Verified").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsGreen)
                case .failed(let m): Text(m).font(.system(size: 12)).foregroundStyle(Color.dsRed).lineLimit(1)
                }
            }
            SecureField("sk-or-v1-…", text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.dsLine, lineWidth: 0.5))
                .onSubmit(save)
                .onChange(of: key) { _, value in verify(value) }
            Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!).font(.system(size: 12))
        }
        .padding(12)
        .background(Color.dsAccentSoft)
    }

    private func verify(_ value: String) {
        checkTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12, let client = engine.client else {
            check = .idle
            return
        }
        check = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result = try? await client.call("models.verifyKey", VerifyKeyParams(provider: "openrouter", key: trimmed), as: VerifyKeyResult.self)
            guard !Task.isCancelled else { return }
            check = result?.ok == true ? .verified : .failed(result?.message ?? "Couldn't check the key.")
        }
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            do {
                try await engine.saveKey(key)
                done()
            } catch {
                check = .failed("Couldn't save to the Keychain.")
            }
        }
    }
}

/// Small rounded badge ("Soon", "CLOUD").
struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.badge))
    }
}
