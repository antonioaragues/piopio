import PiopioKit
import PiopioTranscript
import SwiftUI

/// First run (docs/design v2, 12b): the chick introduces itself, asks for an OpenRouter key and checks it as you
/// paste, then offers three first steps. Fills the window; Skip leaves everything for Settings.
struct WelcomeView: View {
    let engine: EngineController
    let done: (FirstStep?) -> Void
    @State private var key = ""
    @State private var check: KeyCheck = .idle
    @State private var checkTask: Task<Void, Never>?
    @State private var connected = false

    enum KeyCheck: Equatable { case idle, checking, verified, failed(String) }
    enum FirstStep { case build, chat, briefing }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    say {
                        Text("Pío pío! I'm Piopio.").font(.system(size: 22, weight: .bold))
                        Text("I work with you in your code, talk through anything, and run small agents that keep going while you're away. Everything stays on this Mac or in your own accounts.\n\nFirst I need a model to think with. Paste an OpenRouter key; it goes straight into your Keychain.")
                            .font(.system(size: 15)).lineSpacing(15 * 0.55 - 4).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                        keyCard.padding(.top, 6)
                    }
                    if connected {
                        say {
                            Text("That works. What should we do first?").font(.system(size: 15, weight: .medium))
                            VStack(spacing: 8) {
                                choice("folder", "Look at a project", "Build · open a folder and start a session") { done(.build) }
                                choice("bubble.left", "Just ask something", "Chat · a question, a draft, an idea") { done(.chat) }
                                choice("sun.max", "Get a morning briefing tomorrow", "Agents · hatches the Daily briefing agent") { done(.briefing) }
                            }
                            .padding(.top, 4)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 90)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 4) {
                Button("Skip setup") { done(nil) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Text("· you can change all of this in Settings").foregroundStyle(Color.dsFg3)
            }
            .font(.system(size: 12.5))
            .frame(height: 52)
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color.dsWin)
        .animation(.easeOut(duration: 0.2), value: connected)
    }

    /// One message from the chick: its avatar on the left, the content beside it.
    private func say<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Chick(size: 48, ring: 4)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(.top, 8)
        }
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("OR").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.39, green: 0.40, blue: 0.95).gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenRouter").font(.system(size: 13, weight: .semibold))
                    Text("One key, hundreds of models").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                switch check {
                case .idle: EmptyView()
                case .checking: ProgressView().controlSize(.mini)
                case .verified: Text("✓ Verified").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsGreen)
                case .failed(let m): Text(m).font(.system(size: 12)).foregroundStyle(Color.dsRed).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                SecureField("sk-or-v1-…", text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.dsWin, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.dsLine, lineWidth: 0.5))
                    .onSubmit(save)
                    .onChange(of: key) { _, value in verify(value) }
                    .disabled(connected)
                Button(connected ? "Saved" : "Use this key") { save() }
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(connected || key.trimmingCharacters(in: .whitespaces).isEmpty || check == .checking)
            }
            Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!).font(.system(size: 12))
        }
        .padding(14)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(check == .verified ? Color.dsAccentLine : Color.dsLine, lineWidth: check == .verified ? 1 : 0.5))
        .frame(maxWidth: 480)
    }

    private func choice(_ icon: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color.accentColor).frame(width: 30, height: 30)
                    .background(Color.dsAccentSoft, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 12).frame(height: 54)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 480)
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
                connected = true
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
