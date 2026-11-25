import Foundation
import Testing
@testable import PiopioKit
@testable import PiopioTranscript

// The Background block's rows (docs/spec/43): commands and subagents, running first, then finished.

private func process(_ id: String, _ command: String, _ status: BackgroundProcess.Status, exit: Int? = nil,
                     started: String = "2026-11-25T10:00:00.000Z", ended: String? = nil, urls: [String] = [], description: String? = nil) -> BackgroundProcess {
    BackgroundProcess(id: id, command: command, description: description, cwd: "/tmp", status: status, exitCode: exit, startedAt: started, endedAt: ended, urls: urls)
}

private func at(_ s: String) -> Date { ISODate.parse(s)! }

@Test func commandsSayTheirAddressWhileRunningAndHowTheyEnded() {
    let (running, finished) = BackgroundWork.rows(processes: [
        process("p1", "npm run dev", .running, urls: ["http://localhost:5173/"]),
        process("p2", "npm test", .exited, exit: 0, ended: "2026-11-25T10:02:10.000Z"),
        process("p3", "npm run e2e", .exited, exit: 1, ended: "2026-11-25T10:00:12.000Z"),
        process("p4", "npx tsc --watch", .stopped, ended: "2026-11-25T10:00:40.000Z"),
    ], subagents: [])
    #expect(running.map(\.id) == ["p1"])
    #expect(running[0].line == "localhost:5173" && running[0].state == "working")
    // Newest first.
    #expect(finished.map(\.id) == ["p2", "p4", "p3"])
    #expect(finished.map(\.line) == ["exited 0 · 2m 10s", "stopped · 40s", "exit 1 · 12s"])
    #expect(finished.map(\.state) == ["done", "stopped", "failed"])
}

@Test func aLongCommandTakesTheAgentsLabelAsInTheDrawer() {
    let long = process("p1", "node -e \"console.log('Local: http://localhost:4321/')\"", .running, description: "Starting the dev server")
    #expect(BackgroundWork.label(long) == "Starting the dev server")
    #expect(BackgroundWork.label(process("p2", "npm run dev", .running)) == "npm run dev")
}

@Test func subagentsCarryTheirTranscriptLine() {
    let (running, finished) = BackgroundWork.rows(processes: [process("p1", "npm run dev", .running)], subagents: [
        SubagentInfo(id: "s1", title: "Audit the OAuth flow", state: "working", line: "Reading oauth.ts", startedAt: at("2026-11-25T09:59:00.000Z")),
        SubagentInfo(id: "s2", title: "Summarise the fees", state: "queued"),
        SubagentInfo(id: "s3", title: "Find callers", state: "done", startedAt: at("2026-11-25T09:00:00.000Z"), endedAt: at("2026-11-25T09:01:52.000Z"), costUsd: 0.03),
        SubagentInfo(id: "s4", title: "Stuck one", state: "working", line: "Reading a.ts", startedAt: at("2026-11-25T10:01:00.000Z"), alert: "looks stuck: nothing new for 10 minutes"),
    ])
    // Commands first, then subagents oldest first; a queued one (no start yet) last.
    #expect(running.map(\.id) == ["p1", "s1", "s4", "s2"])
    #expect(running[1].line == "Reading oauth.ts")
    #expect(running[2].alerting && running[2].line == "looks stuck: nothing new for 10 minutes")
    #expect(running[3].line == "queued · starts when one finishes" && running[3].elapsed(at: Date()) == nil)
    #expect(finished.map(\.line) == ["done · 1m 52s · $0.03"])
}

@Test func theTimeTicksFromTheStart() {
    let row = BackgroundWork.rows(processes: [process("p1", "npm run dev", .running)], subagents: []).running[0]
    #expect(row.elapsed(at: at("2026-11-25T10:01:04.000Z")) == "1m 04s")
    #expect(row.elapsed(at: at("2026-11-25T10:00:09.000Z")) == "9s")
    #expect(BackgroundWork.duration(3725) == "1h 02m")
}

@Test func theHeadSaysWhatRunsAndWhatFinished() {
    #expect(BackgroundWork.summary(running: 2, finished: 3) == "2 running · 3 finished")
    #expect(BackgroundWork.summary(running: 0, finished: 3) == "3 finished")
    #expect(BackgroundWork.summary(running: 1, finished: 0) == "1 running")
}
