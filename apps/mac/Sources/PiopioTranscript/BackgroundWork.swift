import Foundation
import PiopioKit

// Background work in the Summary column (docs/spec/43): what a conversation left running and what it ran, its
// background commands (05-build §9 TM4) and its subagents (37), as one list of rows: running first, then finished.

/// One row of the Background block.
public struct BackgroundRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case command, subagent }
    public var kind: Kind
    /// The process id ("p1") or the subagent's session id.
    public var id: String
    /// "npm run dev", or the subagent's title.
    public var title: String
    /// The grey line under the title: a command's address while it runs, what a subagent is doing, or how it ended.
    public var line: String?
    /// The glyph's state, in `SubagentGlyph`'s words: working, queued, done, failed or stopped.
    public var state: String
    /// When it started, for the time that ticks while it runs.
    public var startedAt: Date?
    public var endedAt: Date?
    /// A command's local addresses (a dev server's).
    public var urls: [String] = []
    /// The Watchdog's note is the line (amber).
    public var alerting = false

    /// Running or waiting to: it has Stop, and its time ticks (queued has no time yet).
    public var running: Bool { state == "working" || state == "queued" }
    /// The time that ticks on the right while it works: "1m 04s".
    public func elapsed(at now: Date) -> String? {
        guard state == "working", let startedAt else { return nil }
        return BackgroundWork.duration(now.timeIntervalSince(startedAt))
    }
}

public enum BackgroundWork {
    /// The block's rows: running ones oldest first (commands, then subagents), finished ones newest first.
    public static func rows(processes: [BackgroundProcess], subagents: [SubagentInfo]) -> (running: [BackgroundRow], finished: [BackgroundRow]) {
        let all = processes.map(row) + subagents.map(row)
        let running = all.filter(\.running).sorted { a, b in
            if a.kind != b.kind { return a.kind == .command }
            return (a.startedAt ?? .distantFuture) < (b.startedAt ?? .distantFuture)
        }
        let finished = all.filter { !$0.running }.sorted { ($0.endedAt ?? $0.startedAt ?? .distantPast) > ($1.endedAt ?? $1.startedAt ?? .distantPast) }
        return (running, finished)
    }

    /// The head's answer: "2 running · 3 finished", "3 finished".
    public static func summary(running: Int, finished: Int) -> String {
        [running > 0 ? "\(running) running" : nil, finished > 0 ? "\(finished) finished" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// A background command: its label; while it runs, its address; when it ends, how ("exited 0 · 2m 10s").
    static func row(_ p: BackgroundProcess) -> BackgroundRow {
        let started = ISODate.parse(p.startedAt), ended = p.endedAt.flatMap(ISODate.parse)
        let took = started.flatMap { s in ended.map { duration($0.timeIntervalSince(s)) } }
        let state: String, line: String?
        switch p.status {
        case .running:
            state = "working"
            line = p.urls.first.map(address)
        case .stopped:
            state = "stopped"
            line = (["stopped", took].compactMap { $0 }).joined(separator: " · ")
        case .exited:
            let code = p.exitCode
            state = code == nil || code == 0 ? "done" : "failed"
            line = ([code == 0 ? "exited 0" : code.map { "exit \($0)" } ?? "exited", took].compactMap { $0 }).joined(separator: " · ")
        }
        return BackgroundRow(kind: .command, id: p.id, title: label(p), line: line, state: state, startedAt: started, endedAt: ended, urls: p.urls)
    }

    /// A subagent: its title, and the line its transcript row shows (37 SB2).
    static func row(_ s: SubagentInfo) -> BackgroundRow {
        BackgroundRow(kind: .subagent, id: s.id, title: s.title, line: s.status, state: s.state == "starting" ? "working" : s.state,
                      startedAt: s.startedAt, endedAt: s.endedAt, alerting: s.alerting)
    }

    /// "npm run dev", or the agent's label for it when the command is long: the drawer's tab and the row say the same.
    public static func label(_ p: BackgroundProcess) -> String {
        p.command.count <= 28 ? p.command : (p.description ?? String(p.command.prefix(26)) + "…")
    }

    /// "http://localhost:5173/" → "localhost:5173".
    static func address(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host() else { return url }
        return u.port.map { "\(host):\($0)" } ?? host
    }

    /// "12s", "1m 04s", "1h 02m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}
