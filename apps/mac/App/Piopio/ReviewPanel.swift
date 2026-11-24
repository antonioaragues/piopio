import PiopioKit
import PiopioTranscript
import SwiftUI

/// A review by an agent, on the session it reviewed (docs/spec/05-build "Review by an agent", roadmap PAR4): what it
/// looked at, how it went, and each finding with its file and line, Fix and Dismiss. Grey ink: severity is a word, the
/// file a link, one black action (Fix all).
struct ReviewPanel: View {
    let review: ReviewInfo
    let session: ThreadModel
    @State private var folded = false
    @State private var listHeight: CGFloat = 0

    private var open: [ReviewFinding] { review.findings.filter { $0.state == .open } }
    private var shown: [ReviewFinding] { review.findings.filter { $0.state != .dismissed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !folded, review.status == .done, !shown.isEmpty {
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                // As tall as its findings, up to 260 (a ScrollView alone takes all 260, empty or not), then it scrolls.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, f in
                            row(f)
                            if i < shown.count - 1 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 62) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), 260))
            }
        }
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Review of \(review.target)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                Text(status).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Open review") { NotificationCenter.default.post(name: .selectBuildSession, object: review.reviewer.id) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            if review.status == .done, open.count > 1 {
                Button("Fix all \(open.count)") { Task { await session.fix(open, from: review) } }
                    .buttonStyle(PillStyle(kind: .strong, compact: true))
            }
            if review.status == .done, !shown.isEmpty {
                Button { folded.toggle() } label: { Image(systemName: folded ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Color.dsFg3)
                    .help(folded ? "Show the findings" : "Fold")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var status: String {
        switch review.status {
        case .running: return "Reviewing…"
        case .failed: return review.summary ?? "The review didn't finish."
        case .done:
            let counts = [ReviewFinding.Severity.bug, .risk, .nit].compactMap { s -> String? in
                let n = review.findings.filter { $0.severity == s && ($0.state == .open || $0.state == .fixing) }.count
                return n > 0 ? "\(n) \(Self.word(s, n))" : nil
            }
            let head = counts.isEmpty ? (review.findings.contains { $0.state == .fixed } ? "All fixed" : "Nothing to fix") : counts.joined(separator: ", ")
            return [head, review.summary].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func row(_ f: ReviewFinding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.word(f.severity, 1).capitalized)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(f.severity == .nit ? Color.dsFg3 : Color.dsFg2)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg)
                Button { session.viewing = FileTarget(path: f.file, line: f.line) } label: {
                    Text("\(f.file)\(f.line.map { ":\($0)" } ?? "")").font(.system(size: 11.5, design: .monospaced))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .help("Open the file at that line")
                Text(f.detail).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                if let s = f.suggestion, !s.isEmpty {
                    Text(s).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if f.state == .fixing {
                    Text("Fixing").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                } else if f.state == .fixed {
                    Label("Fixed", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                } else {
                    Button("Fix") { Task { await session.fix([f], from: review) } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg)
                    Button("Dismiss") { Task { await session.setFinding(f, .dismissed) } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    static func word(_ s: ReviewFinding.Severity, _ n: Int) -> String {
        switch s {
        case .bug: n == 1 ? "bug" : "bugs"
        case .risk: n == 1 ? "risk" : "risks"
        case .nit: n == 1 ? "nit" : "nits"
        }
    }
}

/// Asks which pull request to review (05-build "Review by an agent" RV1).
struct ReviewPullRequestSheet: View {
    let session: ThreadModel
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review a pull request").font(.system(size: 15, weight: .semibold))
            Text("An agent reviews it in a session of its own, in Read only, and lists what it finds. Any pull request of this project's GitHub repository, yours or someone else's.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            TextField("Number, like 42", text: $number)
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Starting…" : "Review", action: start).keyboardShortcut(.defaultAction).disabled(busy || Int(number.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func start() {
        guard let n = Int(number.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) else { return }
        busy = true
        Task {
            if let ref = await session.review(pr: n) {
                dismiss()
                NotificationCenter.default.post(name: .selectBuildSession, object: ref.id)
            }
            busy = false
        }
    }
}
