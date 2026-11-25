import { existsSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import { editable, formatSkill, parseSkill, skillName, skillsRoot, writeSkill } from "../src/skills.js";

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

	// Re-audit 2026-11-25 (V8): the checks compared spellings, so a symlink in a project led anywhere.
	test("a skill folder that links outside the project or the skill folders is neither written nor edited", () => {
		const base = realpathSync(mkdtempSync(join(tmpdir(), "piopio-skills-link-")));
		const agentDir = join(base, "agent");
		const project = join(base, "project");
		mkdirSync(join(agentDir, "skills"), { recursive: true });
		mkdirSync(join(project, ".pi"), { recursive: true });
		symlinkSync(join(agentDir, "skills"), join(project, ".pi", "skills"));
		expect(() => skillsRoot(agentDir, project)).toThrow(/link to a folder outside/);
		const root = join(base, "root");
		mkdirSync(join(base, "elsewhere", "x"), { recursive: true });
		mkdirSync(root);
		symlinkSync(join(base, "elsewhere", "x"), join(root, "x"));
		expect(editable(join(root, "x", "SKILL.md"), [root])).toBe(false);
		expect(editable(join(root, "..", "elsewhere", "x", "SKILL.md"), [root])).toBe(false);
	});
});
