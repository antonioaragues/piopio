import Testing
@testable import PiopioKit

@Test func unifiedDiffNumbersLinesAndPairsRuns() {
    let patch = "diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -3,4 +3,5 @@ class A {\n keep\n-old one\n-old two\n+new one\n+new two\n+new three\n tail\n\\ No newline at end of file"
    let diff = UnifiedDiff(patch)
    #expect(diff.added == 3 && diff.removed == 2)
    #expect(diff.rows.map(\.kind) == [.hunk, .context, .removed, .removed, .added, .added, .added, .context])
    #expect(diff.rows[1].old == 3 && diff.rows[1].new == 3)
    #expect(diff.rows[2].old == 4 && diff.rows[2].new == nil)
    #expect(diff.rows[4].new == 4)
    #expect(diff.rows[7].old == 6 && diff.rows[7].new == 7)
    let pairs = diff.pairs
    #expect(pairs.count == 6) // hunk, keep, 3 paired change rows, tail
    #expect(pairs[2].left?.text == "old one" && pairs[2].right?.text == "new one")
    #expect(pairs[4].left == nil && pairs[4].right?.text == "new three")
}
