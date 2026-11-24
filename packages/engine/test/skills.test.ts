import { existsSync, mkdtempSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import { editable, formatSkill, parseSkill, skillName, writeSkill } from "../src/skills.js";

describe("skills you make (D9, PAR12)", () => {
	test("names are pi's: lowercase, hyphens, no accents, 64 at most", () => {
		expect(skillName("Release Piopio!")).toBe("release-piopio");
		expect(skillName("  Informe mensual de facturas ")).toBe("informe-mensual-de-facturas");
		expect(skillName("x".repeat(80))).toHaveLength(64);
	});

	test("SKILL.md round-trips, keeping frontmatter Piopio doesn't edit", () => {
		const text = `---\nname: pdf-tools\ndescription: "Extract text: tables too. Use for PDFs."\nlicense: MIT\ndisable-model-invocation: true\n---\n\n# PDF\n\nRun it.\n`;
		const p = parseSkill(text);
		expect(p).toEqual({ name: "pdf-tools", description: "Extract text: tables too. Use for PDFs.", manual: true, body: "# PDF\n\nRun it.", other: ["license: MIT"] });
		expect(parseSkill(formatSkill(p, p.other))).toEqual(p);
	});

	test("writing makes the folder, refuses a name in use, and a new name renames the folder", () => {
		const root = mkdtempSync(join(tmpdir(), "piopio-skills-"));
		const path = writeSkill(root, { name: "Release Piopio", description: "When asked to cut a release.", body: "1. Bump the version." });
		expect(path).toBe(join(root, "release-piopio", "SKILL.md"));
		expect(() => writeSkill(root, { name: "release piopio", description: "x", body: "y" })).toThrow(/already a skill/);
		mkdirSync(join(root, "release-piopio", "scripts"));
		writeFileSync(join(root, "release-piopio", "scripts", "go.sh"), "echo");
		const moved = writeSkill(root, { name: "release", description: "When asked to release.", body: "1. Bump." }, path);
		expect(moved).toBe(join(root, "release", "SKILL.md"));
		expect(existsSync(join(root, "release", "scripts", "go.sh"))).toBe(true);
		expect(readFileSync(moved, "utf8")).toBe("---\nname: release\ndescription: When asked to release.\n---\n\n1. Bump.\n");
		expect(editable(moved, [root])).toBe(true);
		expect(editable("/elsewhere/x/SKILL.md", [root])).toBe(false);
	});
});
