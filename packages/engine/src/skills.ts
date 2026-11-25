/**
 * Skills you make (backlog D9, PAR12, docs/spec/40 SH0): pi's own skill folders, written as pi reads them (Agent Skills:
 * a folder with SKILL.md, `name` and `description` in its frontmatter). Yours live in `~/.pi/agent/skills` (every
 * project) or a project's `.pi/skills` (that project only); a package's are read here but never written.
 */
import { existsSync, mkdirSync, readFileSync, renameSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { physical, projectPath, under } from "@piopio/pi-extensions";
import { writeFileAtomic } from "./atomic.js";
import { EngineError } from "./models.js";

export type SkillDraft = { name: string; description: string; body: string; manual?: boolean };
export type SkillFile = SkillDraft & { /** Frontmatter lines Piopio doesn't edit (license, metadata…), kept as they were. */ other: string[] };

/** A skill's name as pi wants it: lowercase letters, numbers and single hyphens, at most 64 characters. */
export function skillName(text: string): string {
	return text
		.normalize("NFD")
		.replace(/[̀-ͯ]/g, "")
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "")
		.slice(0, 64)
		.replace(/-+$/g, "");
}

const quote = (s: string) => (/^[\w .,()/'-]*$/.test(s) && !s.includes(": ") ? s : JSON.stringify(s));

export function formatSkill(skill: SkillDraft, other: readonly string[] = []): string {
	const head = [`name: ${skill.name}`, `description: ${quote(skill.description.replace(/\s+/g, " ").trim())}`, ...(skill.manual ? ["disable-model-invocation: true"] : []), ...other];
	return `---\n${head.join("\n")}\n---\n\n${skill.body.trim()}\n`;
}

/** SKILL.md's frontmatter and body (a file with none is all body). */
export function parseSkill(text: string): SkillFile {
	const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(text);
	if (!m) return { name: "", description: "", body: text.trim(), other: [] };
	const out: SkillFile = { name: "", description: "", body: m[2]!.trim(), other: [] };
	for (const line of m[1]!.split(/\r?\n/)) {
		const kv = /^([\w-]+):\s*(.*)$/.exec(line);
		const value = kv?.[2]?.trim() ?? "";
		const unquoted = /^".*"$/.test(value) ? (JSON.parse(value) as string) : value.replace(/^'(.*)'$/, "$1");
		if (kv?.[1] === "name") out.name = unquoted;
		else if (kv?.[1] === "description") out.description = unquoted;
		else if (kv?.[1] === "disable-model-invocation") out.manual = value === "true";
		else out.other.push(line);
	}
	return out;
}

/**
 * Where a skill of yours goes: every project, or one project's `.pi/skills`, which must really be in the project
 * (paths.ts `projectPath`: a repository's `.pi/skills -> ~/.pi/agent/skills` would make a project's skill everyone's).
 */
export function skillsRoot(agentDir: string, project?: string): string {
	if (!project) return join(agentDir, "skills");
	const root = projectPath(project, join(".pi", "skills"));
	if (!root) throw new EngineError("INVALID", "This project's .pi/skills is a link to a folder outside it, so Piopio won't write skills there.");
	return root;
}

/** Whether Piopio may write this SKILL.md: where it really is lies in one of your skill folders, not a package's. */
export function editable(path: string, roots: readonly string[]): boolean {
	const p = physical(path);
	return p.endsWith("/SKILL.md") && roots.some((r) => under(p, physical(r)) && p !== physical(r));
}

/**
 * Writes a skill: a new folder named after it, or the one it was in (`previous`, its SKILL.md), renamed when the name
 * changed. Frontmatter Piopio doesn't edit is kept. Returns the SKILL.md written.
 */
export function writeSkill(root: string, draft: SkillDraft, previous?: string): string {
	const name = skillName(draft.name);
	if (!name) throw new EngineError("INVALID", "A skill needs a name.");
	if (!draft.description.trim()) throw new EngineError("INVALID", "Say when the skill is used: it's what the model reads to decide to load it.");
	const folder = join(root, name);
	let other: string[] = [];
	if (previous) {
		if (existsSync(previous)) other = parseSkill(readFileSync(previous, "utf8")).other;
		const from = dirname(previous);
		if (resolve(from) !== resolve(folder)) {
			if (existsSync(folder)) throw new EngineError("INVALID", `There's already a skill called ${name}.`);
			mkdirSync(dirname(folder), { recursive: true });
			renameSync(from, folder);
		}
	} else if (existsSync(join(folder, "SKILL.md"))) throw new EngineError("INVALID", `There's already a skill called ${name}.`);
	mkdirSync(folder, { recursive: true });
	const path = join(folder, "SKILL.md");
	writeFileAtomic(path, formatSkill({ ...draft, name }, other));
	return path;
}
