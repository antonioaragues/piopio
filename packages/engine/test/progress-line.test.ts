import { expect, test } from "vitest";
import { progressLine } from "../src/progress-line.js";

/** A subagent's live line is plain language, never the raw command (docs/spec/37 SB3). */
test("a subagent's line: what it does, in words", () => {
	expect(progressLine("read", { path: "/Users/me/piopio/packages/engine/src/oauth.ts", offset: 40 })).toBe("Reading oauth.ts");
	expect(progressLine("edit", { path: "apps/mac/App/Piopio/SideViews.swift" })).toBe("Editing SideViews.swift");
	expect(progressLine("grep", { pattern: "Keychain" })).toBe("Searching for Keychain");
	expect(progressLine("ls", { path: "packages/engine/src" })).toBe("Looking through src");
	expect(progressLine("bash", { command: "cd /x && rg foo", description: "Checking the project tests" })).toBe("Checking the project tests");
	expect(progressLine("bash", { command: "cd /Users/me/piopio && sed -n '400,460p;640,700p' packages/engine/src/sessions.ts" })).toBe("Reading sessions.ts");
	expect(progressLine("bash", { command: "cd /x && ls && echo '---' && cat README.md" })).toBe("Looking through the files");
	expect(progressLine("bash", { command: "rg -n 'parent.line' packages" })).toBe("Searching for parent.line");
	expect(progressLine("bash", { command: "cd packages/engine && npx vitest run tasks" })).toBe("Running the tests");
	expect(progressLine("bash", { command: "swift build -c release" })).toBe("Building");
	expect(progressLine("bash", { command: "python3 script.py" })).toBe("Running python3");
	expect(progressLine("bash", {})).toBe("Running a command");
	expect(progressLine("web_search", { query: "Fly.io machines auto stop" })).toBe("Searching the web for Fly.io machines auto stop");
	expect(progressLine("web_fetch", { url: "https://www.hetzner.com/cloud" })).toBe("Reading hetzner.com");
	expect(progressLine("mcp__linear__list_issues", {})).toBe("Using linear");
	expect(progressLine("read_conversation", {})).toBe("Read conversation");
});
