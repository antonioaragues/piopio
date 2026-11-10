/**
 * Your team templates (docs/spec/20 P4): readable folders in ~/Piopio/Teams/Templates, so you can edit, share or bring
 * them from elsewhere. Each has a TEAM.md (front matter: name, description, workplace, style; its text is what every
 * member is told) and a role card per member in roles/ (front matter: name, kind, model, agent, done; its text is the
 * member's responsibility). Files are numbered so the order holds: roles/01-lead.md, roles/02-builder.md…
 *
 * And a team drafted from a description ("a marketing team with a lead, a copywriter, a designer and an editor who
 * reviews"): the background model writes it when there is one; without it, the description's own words do.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { LEAD_BASE, type Role, type TeamTemplate } from "./templates.js";

/** Front matter (`key: value` lines between `---`) and the text after it. */
export function parseCard(text: string): { meta: Record<string, string>; body: string } {
	const m = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(text.replace(/\r\n/g, "\n"));
	if (!m) return { meta: {}, body: text.trim() };
	const meta: Record<string, string> = {};
	for (const line of m[1]!.split("\n")) {
		const kv = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line);
		if (kv) meta[kv[1]!] = kv[2]!.trim().replace(/^"(.*)"$/, "$1");
	}
	return { meta, body: m[2]!.trim() };
}

function card(meta: Record<string, string | undefined>, body: string): string {
	const lines = Object.entries(meta)
		.filter(([, v]) => v !== undefined && v !== "")
		.map(([k, v]) => `${k}: ${/[:#\n]/.test(v!) ? JSON.stringify(v) : v}`);
	return `---\n${lines.join("\n")}\n---\n\n${body.trim()}\n`;
}

const slugOf = (name: string) => name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "team";

/** Your templates, each from its folder; ones that don't read are skipped. */
export function readTemplates(dir: string): TeamTemplate[] {
	if (!existsSync(dir)) return [];
	const out: TeamTemplate[] = [];
	for (const name of readdirSync(dir).sort()) {
		const folder = join(dir, name);
		const teamFile = join(folder, "TEAM.md");
		const rolesDir = join(folder, "roles");
		if (!existsSync(teamFile) || !existsSync(rolesDir)) continue;
		const team = parseCard(readFileSync(teamFile, "utf8"));
		const roles: Role[] = [];
		for (const file of readdirSync(rolesDir).filter((f) => f.endsWith(".md")).sort()) {
			const { meta, body } = parseCard(readFileSync(join(rolesDir, file), "utf8"));
			const kind = meta.kind as Role["kind"];
			if (!meta.name || !["lead", "write", "review", "integrate"].includes(kind)) continue;
			const id = file.replace(/\.md$/, "").replace(/^\d+-/, "");
			roles.push({ id, name: meta.name, kind, responsibility: body || `You're the ${meta.name}.`, ...(meta.done ? { done: meta.done } : {}), ...(meta.model ? { model: meta.model } : {}), ...(meta.agent ? { agent: meta.agent } : {}) });
		}
		if (roles.filter((r) => r.kind === "lead").length !== 1 || !roles.some((r) => r.kind === "write")) continue;
		out.push({
			id: `my-${name}`,
			name: team.meta.name || name,
			description: team.meta.description || roles.map((r) => r.name).join(", "),
			workplace: team.meta.workplace === "folder" ? "folder" : "project",
			roles,
			style: team.meta.style || "",
			instructions: team.body.replace(/^#.*\n?/, "").trim(),
			source: "yours",
			folder,
		});
	}
	return out;
}

/** Writes a template folder (a new one when the name is taken) and returns its id. */
export function writeTemplate(dir: string, t: { name: string; description: string; style: string; instructions: string; roles: Role[] }): { id: string; folder: string } {
	mkdirSync(dir, { recursive: true });
	const base = slugOf(t.name);
	let slug = base;
	for (let n = 2; existsSync(join(dir, slug)); n++) slug = `${base}-${n}`;
	const folder = join(dir, slug);
	mkdirSync(join(folder, "roles"), { recursive: true });
	const workplace = t.roles.some((r) => r.kind === "integrate") ? "project" : "folder";
	writeFileSync(join(folder, "TEAM.md"), card({ name: t.name, description: t.description, workplace, style: t.style }, `# ${t.name}\n\n${t.instructions}`));
	t.roles.forEach((r, i) => {
		writeFileSync(join(folder, "roles", `${String(i + 1).padStart(2, "0")}-${r.id || slugOf(r.name)}.md`), card({ name: r.name, kind: r.kind, done: r.done, model: r.model, agent: r.agent }, r.responsibility));
	});
	return { id: `my-${slug}`, folder };
}

// ── Drafting a team from a description ──

export type TeamDraft = { name: string; description: string; style: string; instructions: string; roles: Role[] };

const SYSTEM = `You design a small team of AI agents from the user's description. Answer with JSON only:
{"name": "...", "description": "...", "style": "...", "instructions": "...", "roles": [{"name": "...", "kind": "lead|write|review|integrate", "responsibility": "...", "done": "..."}]}
- name: 1 to 3 words ("Marketing team"). In the user's language.
- description: one sentence on what the team does.
- style: how the lead should split work among these members, in one or two sentences.
- instructions: standing rules every member follows (tone, tools, format), from the description; empty when it gives none.
- roles: exactly one "lead" (plans and assigns); at least one "write" (does tasks; several can run at once); at most one "review" (checks every finished task and sends it back); "integrate" only for software teams with a test command. responsibility in the second person ("You write…"), 1 to 3 sentences; done: what done means for its work.`;

/** The draft: the background model's, else one from the description's words. */
export async function draftTeam(description: string, complete?: (system: string, prompt: string) => Promise<string | undefined>): Promise<TeamDraft> {
	const fallback = plainTeam(description);
	const reply = complete ? await complete(SYSTEM, description).catch(() => undefined) : undefined;
	const json = reply ? /\{[\s\S]*\}/.exec(reply)?.[0] : undefined;
	let parsed: Partial<TeamDraft> | undefined;
	try {
		parsed = json ? (JSON.parse(json) as Partial<TeamDraft>) : undefined;
	} catch {
		parsed = undefined;
	}
	const roles = Array.isArray(parsed?.roles)
		? parsed.roles.filter((r): r is Role => typeof r?.name === "string" && ["lead", "write", "review", "integrate"].includes(r?.kind as string)).map((r) => ({ id: slugOf(r.name), name: r.name.trim(), kind: r.kind, responsibility: r.kind === "lead" ? `${LEAD_BASE}${r.responsibility ? `\n\n${String(r.responsibility).trim()}` : ""}` : String(r.responsibility ?? "").trim() || `You're the ${r.name}.`, ...(typeof r.done === "string" && r.done.trim() ? { done: r.done.trim() } : {}) }))
		: [];
	const ok = roles.filter((r) => r.kind === "lead").length === 1 && roles.some((r) => r.kind === "write") && roles.filter((r) => r.kind === "review").length <= 1 && roles.filter((r) => r.kind === "integrate").length <= 1;
	if (!ok) return fallback;
	const text = (v: unknown, or: string) => (typeof v === "string" && v.trim() ? v.trim() : or);
	return { name: text(parsed?.name, fallback.name).slice(0, 60), description: text(parsed?.description, fallback.description), style: text(parsed?.style, fallback.style), instructions: text(parsed?.instructions, fallback.instructions), roles };
}

const LEAD = /\b(leads?|leader|l[ií]der|lidera|jefe|jefa|manager|director|directora|coordinator|coordinador|coordinadora|editor in chief|chief)\b/i;
const REVIEW = /\b(reviews?|reviewer|revisa|revisor|revisora|qa|quality|checks|comprueba)\b/i;
const MERGE = /\b(ci|merges?|integra|integrates)\b/i;

/** Without a model: the team's name from before "with", its members from the list after it. */
export function plainTeam(description: string): TeamDraft {
	const text = description.trim().replace(/\s+/g, " ");
	const m = /^(.*?)\b(?:with|con)\b(.*)$/i.exec(text);
	const head = (m ? m[1]! : text).replace(/^(please\s+)?(make|create|build|i want|quiero|crea|haz|hazme|un|una|a|an)\s+/gi, "").replace(/^(a|an|un|una)\s+/i, "").trim();
	// "research team for our podcast" is "Research team"; "equipo de contenido" stays; "marketing" is "Marketing team".
	const clean = head.replace(/[.,;:]+$/, "");
	const english = /^(.*?\bteam)\b/i.exec(clean);
	let name = english ? english[1]! : clean.split(" ").slice(0, 4).join(" ") || "New team";
	if (!/\b(team|equipo)\b/i.test(name)) name = `${name} team`;
	name = name[0]!.toUpperCase() + name.slice(1);
	const parts = (m ? m[2]! : "").split(/,|;|\band\b|\by\b|\be\b/i).map((p) => p.trim().replace(/[.]+$/, "")).filter(Boolean);
	const roles: Role[] = [];
	const has = (k: Role["kind"]) => roles.some((r) => r.kind === k);
	for (const part of parts) {
		const words = part.replace(/^(a|an|one|two|three|some|un|una|uno|dos|tres|el|la|los|las)\s+/i, "");
		const title = words.split(/\b(?:who|that|que|to|para)\b/i)[0]!.trim() || words;
		const label = title[0]!.toUpperCase() + title.slice(1);
		const kind: Role["kind"] = LEAD.test(part) && !has("lead") ? "lead" : REVIEW.test(part) && !has("review") ? "review" : MERGE.test(part) && !has("integrate") ? "integrate" : "write";
		let id = slugOf(label);
		for (let n = 2; roles.some((r) => r.id === id); n++) id = `${slugOf(label)}-${n}`;
		roles.push({ id, name: label, kind, responsibility: responsibility(kind, label) });
	}
	if (!has("lead")) roles.unshift({ id: "lead", name: "Lead", kind: "lead", responsibility: LEAD_BASE });
	if (!has("write")) roles.push({ id: "member", name: "Member", kind: "write", responsibility: responsibility("write", "Member") });
	return {
		name,
		description: `Made from your description: “${text}”`,
		style: "Give each member the tasks that fit their role. Keep tasks small and independent, so several can run at once.",
		instructions: `What this team is for: ${text}`,
		roles,
	};
}

function responsibility(kind: Role["kind"], name: string): string {
	switch (kind) {
		case "lead":
			return LEAD_BASE;
		case "review":
			return `You're the team's ${name}: you check every finished task against its brief and what done means, and say exactly what to change. You don't redo the work yourself.`;
		case "integrate":
			return "Merges approved work into the team's branch and runs the checks.";
		default:
			return `You're the team's ${name}: you do the tasks that need a ${name.toLowerCase()}, follow the team's instructions, and end with a short report of what you did.`;
	}
}
