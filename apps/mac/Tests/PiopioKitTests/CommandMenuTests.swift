import PiopioKit
import Testing

@Test func commandsMatchByNameThenKeywordThenDescription() {
    #expect(CommandMenu.score("go", names: ["goal"]) == 0)
    #expect(CommandMenu.score("me", names: ["grill-me"]) == 1)
    #expect(CommandMenu.score("sched", names: ["automation"], keywords: ["schedule", "remind"]) == 2)
    #expect(CommandMenu.score("free", names: ["compact"], description: "Summarize older messages to free context") == 3)
    // One letter matches names only, or every description would.
    #expect(CommandMenu.score("f", names: ["compact"], description: "free context") == nil)
    // A skill is found by its name and by what's typed for it.
    #expect(CommandMenu.score("gre", names: ["greet", "skill:greet"]) == 0)
    #expect(CommandMenu.score("skill:", names: ["greet", "skill:greet"]) == 0)

    let rows = [("compact", "Summarize older messages"), ("side", "btw"), ("summarize", "")]
    let found = CommandMenu.filter(rows, query: "sum") { (names: [$0.0], keywords: [], description: $0.1) }
    #expect(found.map(\.0) == ["summarize", "compact"])
}

@Test func aLeadingCommandBecomesAChip() {
    let known: Set = ["goal", "skill:greet"]
    #expect(CommandMenu.leading("/goal ", commands: known)! == ("goal", ""))
    #expect(CommandMenu.leading("/goal tests pass\nand lint", commands: known)! == ("goal", "tests pass\nand lint"))
    #expect(CommandMenu.leading("/skill:greet  Anna", commands: known)! == ("skill:greet", " Anna"))
    #expect(CommandMenu.leading("/goal", commands: known) == nil)
    #expect(CommandMenu.leading("/other x", commands: known) == nil)
    #expect(CommandMenu.leading("say /goal x", commands: known) == nil)
}
