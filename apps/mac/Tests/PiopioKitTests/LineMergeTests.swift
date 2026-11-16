import Testing
@testable import PiopioKit

@Test func memoryLinesAddedOnDiskJoinYourEdits() {
    let base = "# Notes\n\n- Chapter 2 is final.\n"
    let theirs = "# Notes\n\n- Chapter 2 is final.\n- Plot C was flooded.\n"
    let mine = "# Notes\n\n- Chapter 2 is final; don't rewrite it.\n"
    #expect(LineMerge.merge(base: base, theirs: theirs, mine: mine) == "# Notes\n\n- Chapter 2 is final; don't rewrite it.\n- Plot C was flooded.\n")
}

@Test func aLineYouAlreadyHaveIsNotAddedTwice() {
    let base = "# Notes\n"
    let theirs = "# Notes\n- Same line.\n"
    let mine = "# Notes\n- Same line.\n"
    #expect(LineMerge.merge(base: base, theirs: theirs, mine: mine) == mine)
}

@Test func changedOrRemovedLinesOnDiskCantBeCombined() {
    let base = "# Notes\n- A\n- B\n"
    #expect(LineMerge.merge(base: base, theirs: "# Notes\n- A\n", mine: "# Notes\n- A\n- B\n- C\n") == nil)
    #expect(LineMerge.merge(base: base, theirs: "# Notes\n- A changed\n- B\n", mine: base) == nil)
}
