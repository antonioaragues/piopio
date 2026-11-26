/**
 * Custom subagents (roadmap PAR12, docs/spec/05-build §4 "Custom subagents"): pi's own agent files, written as pi's
 * subagent extension reads them. Each is a Markdown file whose frontmatter has `name`, `description`, and optionally
 * `tools` (the only tools it gets) and `model`; its body is added to the subagent's system prompt. Yours live in
 * `~/.pi/agent/agents` (every project), a project's in its `.pi/agents`, read only while the project is trusted (its
 * text is the repository's). A project's wins over yours of the same name, as in pi.
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";
import { physical, projectPath, under } from "@piopio/pi-extensions";
import { writeFileAtomic } from "./atomic.js";
import { EngineError } from "./models.js";
import { piTrust } from "./project-trust.js";
import { skillName } from "./skills.js";

export type SubagentDraft = { name: string; description: string; tools?: string[]; model?: string; instructions: string };
export type Subagent = SubagentDraft & { path: string; where: "yours" | "project" };

/** Names `task` keeps for itself: Piopio's own subagent and the coding agents. */
const RESERVED = new Set(["piopio", "claude", "codex", "antigravity", "gemini"]);

/** `tools: read, bash` or `tools: [read, bash]`, as pi accepts; anything else is no list (all of the parent's tools). */
function toolList(value: unknown): string[] | undefined {
	const raw = Array.isArray(value) ? value : typeof value === "string" ? value.split(",") : [];
	const tools = raw.filter((t): t is string => typeof t === "string").map((t) => t.trim()).filter(Boolean);
	return tools.length ? tools : undefined;
}

/** An agent file's definition; undefined when it has no name or description, or its frontmatter isn't YAML. */
export function parseSubagent(text: string): SubagentDraft | undefined {
	let parsed: { frontmatter: { name?: unknown; description?: unknown; tools?: unknown; model?: unknown }; body: string };
	try {
		parsed = parseFrontmatter<{ name?: unknown; description?: unknown; tools?: unknown; model?: unknown }>(text);
	} catch {
		return undefined;
	}
	const { frontmatter, body } = parsed;
	if (typeof frontmatter.name !== "string" || typeof frontmatter.description !== "string") return undefined;
	const tools = toolList(frontmatter.tools);
	const model = typeof frontmatter.model === "string" && frontmatter.model.trim() ? frontmatter.model.trim() : undefined;
	return { name: frontmatter.name.trim(), description: frontmatter.description.trim(), ...(tools ? { tools } : {}), ...(model ? { model } : {}), instructions: body.trim() };
}

const quote = (s: string) => (/^[\w .,()/'-]*$/.test(s) && !s.includes(": ") ? s : JSON.stringify(s));

export function formatSubagent(draft: SubagentDraft): string {
	const head = [`name: ${draft.name}`, `description: ${quote(draft.description.replace(/\s+/g, " ").trim())}`, ...(draft.tools?.length ? [`tools: ${draft.tools.join(", ")}`] : []), ...(draft.model ? [`model: ${quote(draft.model)}`] : [])];
	return `---\n${head.join("\n")}\n---\n\n${draft.instructions.trim()}\n`;
}

function readDir(dir: string | undefined, where: Subagent["where"]): Subagent[] {
	if (!dir || !existsSync(dir)) return [];
	let names: string[];
	try {
		names = readdirSync(dir).filter((n) => n.endsWith(".md")).sort();
	} catch {
		return [];
	}
	return names.flatMap((n) => {
		const path = join(dir, n);
		try {
			const draft = parseSubagent(readFileSync(path, "utf8"));
			return draft && !RESERVED.has(draft.name) ? [{ ...draft, path, where }] : [];
		} catch {
			return [];
		}
	});
}

/** Where yours go (every project), or a project's `.pi/agents`, which must really be in the project. */
export function subagentsRoot(agentDir: string, project?: string): string {
	if (!project) return join(agentDir, "agents");
	const root = projectPath(project, join(".pi", "agents"));
	if (!root) throw new EngineError("INVALID", "This project's .pi/agents is a link to a folder outside it, so Piopio won't write subagents there.");
	return root;
}

/**
 * The subagents a conversation in `project` can hand work to: yours, and the project's while it's trusted (`trusted`
 * overrides pi's decision, for tests and callers that know it). One per name, the project's first.
 */
export function listSubagents(agentDir: string, project?: string, trusted?: boolean): Subagent[] {
	const byName = new Map<string, Subagent>();
	for (const a of readDir(join(agentDir, "agents"), "yours")) byName.set(a.name, a);
	if (project && (trusted ?? piTrust(project, agentDir) === true)) {
		const dir = projectPath(project, join(".pi", "agents"));
		for (const a of readDir(dir ?? undefined, "project")) byName.set(a.name, a);
	}
	return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/** Whether Piopio may write or delete this file: an agent file really inside one of `roots`. */
export function editableSubagent(path: string, roots: readonly string[]): boolean {
	const p = physical(path);
	return p.endsWith(".md") && roots.some((r) => under(p, physical(r)) && p !== physical(r));
}

/** Writes a subagent as `<name>.md` in `root`: a new one, or `previous` (its file), renamed when the name changed. */
export function writeSubagent(root: string, draft: SubagentDraft, previous?: string): string {
	const name = skillName(draft.name);
	if (!name) throw new EngineError("INVALID", "A subagent needs a name.");
	if (RESERVED.has(name)) throw new EngineError("INVALID", `"${name}" is taken by a built-in agent; choose another name.`);
	if (!draft.description.trim()) throw new EngineError("INVALID", "Say what it's for: the conversation reads it to decide when to hand work to it.");
	const path = join(root, `${name}.md`);
	if (resolve(path) !== (previous && resolve(previous)) && existsSync(path)) throw new EngineError("INVALID", `There's already a subagent called ${name}.`);
	const tools = draft.tools?.map((t) => t.trim()).filter(Boolean);
	writeFileAtomic(path, formatSubagent({ name, description: draft.description, ...(tools?.length ? { tools } : {}), ...(draft.model?.trim() ? { model: draft.model.trim() } : {}), instructions: draft.instructions }));
	return path;
}

/**
 * A definition's `model` as one of the models on this Mac: `provider/id` exactly, else the same id (or the same last
 * part, as `claude-haiku-4.5` for `anthropic/claude-haiku-4.5`), the conversation's provider first. Undefined: none
 * matches, and the subagent runs on the conversation's model.
 */
export function matchModel(text: string, models: readonly { provider: string; id: string }[], near?: string): { provider: string; id: string } | undefined {
	const want = text.trim().toLowerCase();
	if (!want) return undefined;
	const exact = models.find((m) => `${m.provider}/${m.id}`.toLowerCase() === want);
	if (exact) return { provider: exact.provider, id: exact.id };
	const last = (id: string) => id.toLowerCase().split("/").at(-1)!;
	const ranked = [...models].sort((a, b) => Number(b.provider === near) - Number(a.provider === near));
	const found = ranked.find((m) => m.id.toLowerCase() === want || last(m.id) === last(want));
	return found && { provider: found.provider, id: found.id };
}
