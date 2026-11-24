import { describe, expect, test } from "vitest";
import { addRules, removeRules } from "../src/learn.js";

describe("/learn's rules in AGENTS.md (docs/spec/14 M5)", () => {
	test("a rule goes after the last line of its section; a new section goes at the end", () => {
		const before = "# piopio\n\nIntro.\n\n## Testing\n\n- Run swift tests with scripts/swift-test.sh.\n\n## Style\n\n- English in docs.\n";
		const { content, added } = addRules(before, [
			{ text: "Run unit tests with `pnpm test:unit`.", section: "testing" },
			{ text: "- Never edit apps/mac/App/build/.", section: "Generated files" },
		]);
		expect(added).toEqual(["- Run unit tests with `pnpm test:unit`.", "- Never edit apps/mac/App/build/."]);
		expect(content).toBe(
			"# piopio\n\nIntro.\n\n## Testing\n\n- Run swift tests with scripts/swift-test.sh.\n- Run unit tests with `pnpm test:unit`.\n\n## Style\n\n- English in docs.\n\n## Generated files\n\n- Never edit apps/mac/App/build/.\n",
		);
	});

	test("a rule already there isn't added twice; no section means Lessons; an empty file gets one", () => {
		expect(addRules("## Lessons\n\n- Use pnpm.\n", [{ text: "Use pnpm." }]).added).toEqual([]);
		expect(addRules("", [{ text: "Use pnpm." }]).content).toBe("## Lessons\n\n- Use pnpm.\n");
	});

	test("undo takes out exactly what was added, and a section left empty goes too", () => {
		const before = "# piopio\n\n## Testing\n\n- Swift: scripts/swift-test.sh.\n";
		const { content, added } = addRules(before, [{ text: "Unit: pnpm test:unit.", section: "Testing" }, { text: "Don't edit build/.", section: "Generated" }]);
		expect(removeRules(content, added)).toBe(before);
		expect(removeRules(addRules("", [{ text: "Use pnpm." }]).content, ["- Use pnpm."])).toBe("");
	});
});
