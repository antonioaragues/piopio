import Testing
@testable import PiopioKit

// Re-audit 2026-11-25 §3.3: a card with only skills said "Write it: " on Save, and the Edit… sheet turned Save into
// Dismiss without saying an item was unfinished.

@Test func saveSaysWhereEverythingGoesSkillsToo() {
    let rule = LearnItem(to: .project, text: "Run the tests with pnpm")
    let fact = LearnItem(to: .aboutMe, text: "Prefers English")
    let skill = LearnItem(to: .skill, text: "When writing release notes", name: "release-notes", body: "Steps")
    #expect(LearnItem.destinations([skill], file: nil) == "the skill release-notes")
    #expect(LearnItem.destinations([LearnItem(to: .skill, text: "x", body: "y", addTo: "deploy")], file: nil) == "the skill deploy")
    #expect(LearnItem.destinations([skill, skill], file: nil) == "2 skills")
    #expect(LearnItem.destinations([rule, fact, skill], file: "CLAUDE.md") == "CLAUDE.md, About me and the skill release-notes")
    #expect(LearnItem.destinations([rule, fact], file: nil) == "AGENTS.md and About me")
}

@Test func anUnfinishedItemSaysWhatItNeeds() {
    #expect(LearnItem(to: .project, text: "Keep it").missing.isEmpty)
    #expect(LearnItem(to: .aboutMe, text: "  ").missing == ["words"])
    #expect(LearnItem(to: .skill, text: "When…").missing == ["a name", "instructions"])
    #expect(LearnItem(to: .skill, text: "When…", body: "More", addTo: "deploy").missing.isEmpty)
    #expect(LearnItem.listed(["a name", "instructions"]) == "a name and instructions")
}
