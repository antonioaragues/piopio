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
    if case .offer? = sideOfferModel(r.render(offer))?.content {} else { Issue.record("no offer card") }
    #expect(r.render(propose).string.contains("closed"))
    r.openProposals = ["c3": .distantFuture]
    #expect(r.render(propose).string.contains("Start"))
    r.keptHere = ["c2"]
    // Answered here: the question and your answer in a box, as Claude keeps them.
    let kept = r.render(offer)
    #expect(kept.string.contains("Dating app") && kept.string.contains("Do it here"))
    #expect(kept.attribute(.piopioCard, at: 0, effectiveRange: nil) as? String == CardStyle.link.rawValue)
    r.keptHere = []
    r.sides = [SideInfo(id: "thr_1", title: "Dating app", state: "queued", from: "c2")]
    guard case .side(let s)? = sideOfferModel(r.render(offer))?.content else { Issue.record("no side row"); return }
    #expect(s.id == "thr_1" && SideOfferModel.state(s) == "queued")
}

@Test func doItHereIsTheMessageAfterTheOffer() {
    let offer = TimelineItem.tool(ToolItem(id: "t1", at: "", callId: "c1", tool: "side_offer", args: .object(["title": .string("A")]), status: .done))
    let later = TimelineItem.tool(ToolItem(id: "t2", at: "", callId: "c2", tool: "side_offer", args: .object(["title": .string("B")]), status: .done))
    let here = TimelineItem.user(UserItem(id: "u1", at: "", text: "Do it here."))
    let other = TimelineItem.user(UserItem(id: "u2", at: "", text: "Something else"))
    #expect(TranscriptDocument.keptHere([offer, here, later, other]) == ["c1"])
    #expect(TranscriptDocument.keptHere([offer, other, here]).isEmpty)
    #expect(TranscriptDocument.keptHerePairs([offer, here, later, other]).map(\.reply) == ["u1"])
    // The offer's box shows the answer, so the "Do it here." bubble doesn't repeat it.
    var r = ItemRenderer()
    #expect(r.render(here).string.contains("Do it here."))
    r.hereReplies = ["u1"]
    #expect(r.render(here).length == 0)
    #expect(r.render(other).string.contains("Something else"))
}

@Test func anAnsweredQuestionKeepsTheQuestionAndTheAnswerInABox() {
    var item = ToolItem(id: "t", at: "", callId: "q", tool: "ask_user", args: .object(["question": .string("Should I build phase 1?")]), status: .done,
                        output: "The user answered: Yes, build it")
    let r = ItemRenderer()
    let box = r.render(.tool(item))
    #expect(box.string.contains("Should I build phase 1?") && box.string.contains("Yes, build it"))
    #expect(box.attribute(.piopioCard, at: 0, effectiveRange: nil) as? String == CardStyle.link.rawValue)
    item.status = .interrupted
    item.details = nil
    item.output = nil
    #expect(r.render(.tool(item)).string.contains("Stopped before you answered"))
    item.status = .running
    #expect(r.render(.tool(item)).length == 0)
}

@Test func aSideWaitingOnYouIsACardOnlyWhileItStillWaits() {
    let report = TimelineItem.user(UserItem(id: "u1", at: "", text: "[Side] “Logo” (thr_2) needs the user: it's waiting for an approval there."))
    var r = ItemRenderer()
    r.sides = [SideInfo(id: "thr_2", title: "Logo", state: "needs_you")]
    #expect(r.render(report).string.contains("Logo needs you"))
    r.sides[0].state = "working"
    #expect(r.render(report).string.contains("Logo · needed you"))
}
