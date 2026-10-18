import Testing
@testable import PiopioKit

private let sample = """
# Title

Intro with **bold** and `code`.
Second line of the same paragraph.

- one
- two
  continued
  - nested
1. first
2) second

> quoted
> text

```swift
let x = 1

print(x)
```

| Name | Value |
|:-----|------:|
| a | 1 |
| b |

---
- [x] done
- [ ] todo
"""

@Test func parsesBlocks() {
    let blocks = MarkdownStream(text: sample).blocks
    #expect(blocks.count == 9)
    #expect(blocks[0] == .heading(level: 1, text: "Title"))
    #expect(blocks[1] == .paragraph("Intro with **bold** and `code`.\nSecond line of the same paragraph."))
    guard case .list(let items) = blocks[2] else { Issue.record("expected list"); return }
    #expect(items.map(\.text) == ["one", "two continued", "nested"])
    #expect(items.map(\.indent) == [0, 0, 2])
    guard case .list(let ordered) = blocks[3] else { Issue.record("expected ordered list"); return }
    #expect(ordered.map(\.number) == [1, 2])
    #expect(blocks[4] == .quote("quoted\ntext"))
    #expect(blocks[5] == .code(language: "swift", code: "let x = 1\n\nprint(x)", closed: true))
    #expect(blocks[6] == .table(header: ["Name", "Value"], alignments: [.leading, .trailing], rows: [["a", "1"], ["b", ""]]))
    #expect(blocks[7] == .rule)
    guard case .list(let tasks) = blocks[8...].first(where: { if case .list = $0 { true } else { false } }) else { Issue.record("expected tasks"); return }
    #expect(tasks.map(\.task) == [true, false])
}

@Test func streamingInAnyChunkingMatchesOneShot() {
    let expected = MarkdownStream(text: sample).blocks
    for size in [1, 2, 3, 7, 16, 64] {
        var stream = MarkdownStream()
        var i = sample.startIndex
        while i < sample.endIndex {
            let j = sample.index(i, offsetBy: size, limitedBy: sample.endIndex) ?? sample.endIndex
            stream.append(String(sample[i..<j]))
            i = j
        }
        stream.finish()
        #expect(stream.blocks == expected, "chunk size \(size)")
    }
}

@Test func closedBlocksNeverChangeWhileStreaming() {
    var stream = MarkdownStream()
    var seen: [MarkdownBlock] = []
    for ch in sample {
        stream.append(String(ch))
        #expect(Array(stream.closed.prefix(seen.count)) == seen)
        seen = stream.closed
    }
}

@Test func openCodeFenceStreamsAsCode() {
    var stream = MarkdownStream()
    stream.append("Look:\n\n```ts\nconst a = 1\n")
    #expect(stream.closed == [.paragraph("Look:")])
    #expect(stream.open == .code(language: "ts", code: "const a = 1", closed: false))
    stream.append("```\nafter")
    #expect(stream.closed.last == .code(language: "ts", code: "const a = 1", closed: true))
    #expect(stream.open == .paragraph("after"))
}
