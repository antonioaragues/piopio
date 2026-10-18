import Foundation
import PiopioKit

/// Deterministic synthetic transcripts that look like real chat/coding sessions.
struct Corpus {
    private var rng: SplitMix64

    init(seed: UInt64 = 42) { rng = SplitMix64(seed: seed) }

    private static let words = """
    the agent session model stream durable object engine protocol render layout text view cache commit entry
    token context window budget router topic space memory schedule channel telegram whatsapp approval checkpoint
    diff branch worktree commit review comment build test failing passing swift typescript node sqlite socket json
    quickly carefully simply actually because however therefore meanwhile instead although usually rarely often
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    private static let code: [(lang: String, lines: [String])] = [
        ("swift", ["struct Session: Identifiable {", "    let id: String", "    var title: String", "    // Recompute lazily", "    func summary() -> String {", "        return \"\\(title) (\\(id))\"", "    }", "}", "let sessions = try await client.call(\"sessions.list\", ListSessionsParams())", "for s in sessions where s.ref.kind == .thread { print(s.title, 42) }"]),
        ("ts", ["export async function submit(ref: ContainerRef, text: string) {", "  const runtime = await sessions.runtime(ref);", "  // queue when busy", "  if (runtime.snapshot().state.status === \"running\") {", "    return { disposition: \"queued\" as const };", "  }", "  await runtime.submit(text, { whenBusy: \"followUp\" });", "  return { disposition: \"started\" as const, at: Date.now() };", "}"]),
        ("python", ["def route(message: str, topics: list[str]) -> str | None:", "    # pick the closest topic", "    best = max(topics, key=lambda t: score(message, t), default=None)", "    return best if best and score(message, best) > 0.42 else None"]),
        ("bash", ["pnpm install", "pnpm -r build && pnpm test", "git checkout -b piopio/fix-routing", "echo \"done\" # 3 files changed"]),
    ]

    mutating func word() -> String { Self.words[rng.next(Self.words.count)] }

    mutating func sentence() -> String {
        let n = 6 + rng.next(14)
        var parts: [String] = []
        for i in 0..<n {
            var w = word()
            switch rng.next(30) {
            case 0: w = "**\(w)**"
            case 1: w = "*\(w)*"
            case 2: w = "`\(w)()`"
            case 3: w = "[\(w)](https://example.com/\(w))"
            default: break
            }
            parts.append(i == 0 ? w.prefix(1).uppercased() + w.dropFirst() : w)
        }
        return parts.joined(separator: " ") + "."
    }

    mutating func paragraph() -> String { (0..<(2 + rng.next(5))).map { _ in sentence() }.joined(separator: " ") }

    mutating func codeBlock() -> String {
        let sample = Self.code[rng.next(Self.code.count)]
        let count = 4 + rng.next(36)
        let lines = (0..<count).map { sample.lines[$0 % sample.lines.count] }
        return "```\(sample.lang)\n\(lines.joined(separator: "\n"))\n```"
    }

    mutating func list() -> String {
        let ordered = rng.next(3) == 0
        return (0..<(2 + rng.next(6))).map { i in
            let marker = ordered ? "\(i + 1)." : "-"
            let nested = !ordered && rng.next(5) == 0 ? "\n  - \(sentence())" : ""
            return "\(marker) \(sentence())\(nested)"
        }.joined(separator: "\n")
    }

    mutating func table() -> String {
        let cols = 3 + rng.next(4)
        let header = "| " + (0..<cols).map { _ in word().capitalized }.joined(separator: " | ") + " |"
        let delim = "|" + String(repeating: "---|", count: cols)
        let rows = (0..<(3 + rng.next(8))).map { _ in "| " + (0..<cols).map { _ in rng.next(3) == 0 ? "\(rng.next(1000))" : word() }.joined(separator: " | ") + " |" }
        return ([header, delim] + rows).joined(separator: "\n")
    }

    mutating func answer(blocks: Int) -> String {
        var out: [String] = []
        if rng.next(3) == 0 { out.append("## " + word().capitalized + " " + word()) }
        for _ in 0..<blocks {
            switch rng.next(20) {
            case 0...9: out.append(paragraph())
            case 10...13: out.append(list())
            case 14...16: out.append(codeBlock())
            case 17: out.append(table())
            case 18: out.append("> " + sentence())
            default: out.append("### " + word().capitalized)
            }
        }
        return out.joined(separator: "\n\n")
    }

    /// `count` timeline items: user → (tools) → assistant, repeated.
    mutating func transcript(count: Int) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var n = 0
        func next() -> String { n += 1; return "i\(n)" }
        while items.count < count {
            items.append(.user(UserItem(id: next(), at: "", text: sentence() + (rng.next(3) == 0 ? " " + sentence() : ""))))
            for _ in 0..<rng.next(3) where items.count < count {
                let tool = ["read", "bash", "edit", "grep"][rng.next(4)]
                items.append(.tool(ToolItem(id: next(), at: "", callId: "c\(n)", tool: tool, args: .object(["path": .string("src/\(word()).ts")]), status: .done, output: (0..<(1 + rng.next(12))).map { _ in sentence() }.joined(separator: "\n"), details: nil, durationMs: Double(rng.next(900)), parentCallId: nil)))
            }
            if items.count < count {
                let text = answer(blocks: 1 + rng.next(9))
                items.append(.assistant(AssistantItem(id: next(), at: "", parts: [AssistantPart(type: .text, text: text, redacted: nil)], model: "faux/lab", usage: nil, status: .done, error: nil)))
            }
        }
        return items
    }
}

/// Small deterministic RNG (no Foundation randomness, so runs are reproducible).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ upperBound: Int) -> Int { Int(nextUInt64() % UInt64(upperBound)) }
}
