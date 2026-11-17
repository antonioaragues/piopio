import AppKit
import PiopioKit
import Testing
@testable import PiopioTranscript

// Side conversations in the transcript (docs/spec/24 §6): a grey line that says where each stands, a card only for
// what needs you, Merge · Discard while a branch waits.

@Test func sideReportsComeApartWithTheirIds() {
    let text = "[Side] “About page” (bld_1) finished. Its work is on side/about-1.\n\n> Done.\n> Tests pass.\n\n[Side] “Logo” (thr_2) needs the user: it's waiting for an approval there."
    let parts = ItemRenderer.sideReportParts(text)
    #expect(parts.map(\.id) == ["bld_1", "thr_2"])
    #expect(parts.map(\.name) == ["About page", "Logo"])
    #expect(parts[0].verb == "finished" && !parts[0].needsYou)
    #expect(parts[0].body == "Done.\nTests pass.")
    #expect(parts[1].needsYou)
}

@Test func aStartedSideIsALineThatFollowsItsState() {
    let start = TimelineItem.tool(ToolItem(id: "t1", at: "", callId: "c1", tool: "side_start", args: .object(["title": .string("Fix clipping")]), status: .done, output: "Started bld_9 “Fix clipping”"))
    var r = ItemRenderer()
    r.sides = [SideInfo(id: "bld_9", title: "Fix clipping", state: "working", line: "running tests", branch: "side/fix-1", from: "c1")]
    #expect(r.render(start).string.contains("Side conversation · Fix clipping · running tests"))
    r.sides[0].state = "done"
    let done = r.render(start).string
    #expect(done.contains("· done · Merge · Discard"))
    r.sides[0].finished = "merged"
    #expect(r.render(start).string.contains("Fix clipping · merged"))
    #expect(!r.render(start).string.contains("Merge ·"))
}

@Test func anAnsweredOfferBecomesItsSidesLineAndAProposalIsACardWhileOpen() {
    let offer = TimelineItem.tool(ToolItem(id: "t2", at: "", callId: "c2", tool: "side_offer", args: .object(["title": .string("Dating app")]), status: .done))
    let propose = TimelineItem.tool(ToolItem(id: "t3", at: "", callId: "c3", tool: "side_propose", args: .object(["title": .string("Team page"), "why": .string("Spotted in passing")]), status: .done))
    var r = ItemRenderer()
    #expect(r.render(offer).string.contains("This looks like its own task"))
    #expect(r.render(propose).string.contains("closed"))
    r.openProposals = ["c3": .distantFuture]
    #expect(r.render(propose).string.contains("Start"))
    r.sides = [SideInfo(id: "thr_1", title: "Dating app", state: "queued", from: "c2")]
    #expect(r.render(offer).string.contains("Side conversation · Dating app · queued"))
}

@Test func aSideWaitingOnYouIsACardOnlyWhileItStillWaits() {
    let report = TimelineItem.user(UserItem(id: "u1", at: "", text: "[Side] “Logo” (thr_2) needs the user: it's waiting for an approval there."))
    var r = ItemRenderer()
    r.sides = [SideInfo(id: "thr_2", title: "Logo", state: "needs_you")]
    #expect(r.render(report).string.contains("Logo needs you"))
    r.sides[0].state = "working"
    #expect(r.render(report).string.contains("Logo · needed you"))
}
