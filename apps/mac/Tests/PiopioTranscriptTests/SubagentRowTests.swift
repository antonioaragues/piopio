import AppKit
import Testing
@testable import PiopioKit
@testable import PiopioTranscript

// A subagent in its parent's transcript (docs/spec/37): one live row, opened beside; its result rows aren't drawn.

private func rowModel(_ text: NSAttributedString) -> SubagentRowModel? {
    var found: SubagentRowModel?
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
        if let a = value as? SubagentRowAttachment { found = a.model; stop.pointee = true }
    }
    return found
}

private func task(_ status: ToolStatus, session: String?, state: String?, agent: String? = nil) -> ToolItem {
    var args: [String: JSONValue] = ["description": .string("Security of the engine"), "prompt": .string("…")]
    if let agent { args["agent"] = .string(agent) }
    var details: [String: JSONValue] = ["type": .string("task")]
    if let session { details["sessionId"] = .string(session) }
    if let state { details["status"] = .string(state) }
    return ToolItem(id: "t1", at: "", callId: "c1", tool: "task", args: .object(args), status: status, details: .decoded(.object(details)))
}

@Test @MainActor func aSubagentIsOneLiveRow() {
    var renderer = ItemRenderer()
    // Starting: the call has no session yet.
    let starting = rowModel(renderer.render(.tool(task(.running, session: nil, state: nil))))
    #expect(starting?.state == "starting" && starting?.id == nil)
    // Started, before the sessions list knows it: working.
    #expect(rowModel(renderer.render(.tool(task(.done, session: "ses_1", state: "started"))))?.state == "working")

    // The sessions list says where it stands: its line while it works, how it ended after.
    renderer.subagents = [SubagentInfo(id: "ses_1", title: "Security of the engine", state: "working", line: "Reading oauth.ts")]
    let working = rowModel(renderer.render(.tool(task(.done, session: "ses_1", state: "started"))))
    #expect(working?.status == "Reading oauth.ts")
    #expect(working?.open == false)
    let start = Date(timeIntervalSince1970: 0)
    renderer.subagents = [SubagentInfo(id: "ses_1", title: "Security of the engine", state: "done", startedAt: start, endedAt: start.addingTimeInterval(112), costUsd: 0.031)]
    renderer.openSubagent = "ses_1"
    let done = rowModel(renderer.render(.tool(task(.done, session: "ses_1", state: "started"))))
    #expect(done?.status == "done · 1m 52s · $0.03")
    #expect(done?.open == true)
    #expect(SubagentInfo(id: "x", title: "", state: "queued").status == "queued · starts when one finishes")
    #expect(SubagentInfo(id: "x", title: "", state: "failed", startedAt: start, endedAt: start.addingTimeInterval(40)).status == "failed · 40s")

    // Claude Code and Codex keep their card (SB7).
    #expect(rowModel(renderer.render(.tool(task(.running, session: nil, state: nil, agent: "claude")))) == nil)
}

@Test @MainActor func aResultThatOnlySaysHowItEndedIsNotDrawn() {
    let renderer = ItemRenderer()
    let finished = renderer.render(.user(UserItem(id: "u1", at: "", text: "[Task] “Security of the engine” (ses_1) finished. It cost $0.03.\n\n> 5 findings")))
    #expect(finished.length == 0)
    // The Watchdog's note is on the row instead, in amber while it lasts.
    let stuck = renderer.render(.user(UserItem(id: "u2", at: "", text: "[Task] “Security of the engine” (ses_1) looks stuck: nothing new for 10 minutes.")))
    #expect(stuck.length == 0)
    let alerting = SubagentInfo(id: "ses_1", title: "Security", state: "working", line: "Reading a.ts", alert: "looks stuck: nothing new for 10 minutes")
    #expect(alerting.alerting && alerting.status == "looks stuck: nothing new for 10 minutes")
    #expect(!SubagentInfo(id: "ses_1", title: "Security", state: "done", alert: "looks stuck").alerting)
}

/// A subagent's first message is Piopio's brief, not a bubble of yours.
@Test @MainActor func aSubagentsBriefSaysItsFromPiopio() {
    var renderer = ItemRenderer()
    renderer.briefFrom = "Piopio"
    renderer.briefId = "u1"
    let brief = renderer.render(.user(UserItem(id: "u1", at: "", text: "Read the engine for security issues.")))
    #expect(brief.string.contains("From Piopio · the brief") || disclosureTitle(brief) == "From Piopio · the brief")
    let later = renderer.render(.user(UserItem(id: "u2", at: "", text: "And the README?")))
    #expect(disclosureTitle(later) == nil)
}

private func disclosureTitle(_ text: NSAttributedString) -> String? {
    var found: String?
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
        if let a = value as? DisclosureAttachment { found = a.card.title; stop.pointee = true }
    }
    return found
}
