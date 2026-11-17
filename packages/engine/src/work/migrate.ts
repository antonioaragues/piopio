/**
 * Teams become projects' ways of working (docs/spec/26 §8), once, the first time the engine starts after 26. It reads
 * what docs/spec/19–21 left (teams.json, team-definitions.json, the team folders in ~/Piopio/Teams, your templates)
 * and writes:
 *
 * - each project's work record, with its board, branch and tasks as they were, and parallel work on;
 * - TEAM.md and the team's NOTES.md into the project's NOTES.md, under "From <team>";
 * - a team whose members you changed: a playbook in the project (`.pi/skills/how-<team>-works/SKILL.md`);
 * - saved teams no project uses, and your templates: playbooks in your skills library;
 * - a report, shown once in the app.
 *
 * Nothing is deleted: the old files are renamed with `.before-26`, and the team folders stay where they are.
 */
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ApprovalMode, WorkTask } from "@piopio/protocol";
import { BUILTIN_PLAYBOOKS, parseCard, playbookFile, type HelperPart } from "./playbooks.js";
import type { ProjectRoutine } from "./routines.js";
import { DEFAULT_WAY, type ProjectWork } from "./runner.js";

type OldRole = { id: string; name: string; kind: "lead" | "write" | "review" | "integrate"; responsibility: string; done?: string; model?: string; agent?: string };
type OldTask = Omit<WorkTask, "helper" | "by"> & { role: string; by: "lead" | "you" };
type OldTeam = {
	id: string;
	definitionId?: string;
	name: string;
	slug: string;
	template: string;
	roles: OldRole[];
	style: string;
	cwd: string;
	folder: string;
	git?: { base: string; branch: string; integration: string };
	model?: string;
	memberMode: ApprovalMode;
	maxParallel: number;
	testCommand?: string;
	tasks: OldTask[];
	nextTask: number;
	reviewLimit?: number;
	budgetPerJob?: number;
	routines?: ProjectRoutine[];
	fired?: string[];
	createdAt: string;
};
type OldDefinition = { id: string; name: string; template: string; roles: OldRole[]; style: string; folder: string; model?: string; saved?: boolean };

export type MigrationHost = {
	home: string;
	/** ~/Piopio/Teams: the team folders, and Templates/. */
	teamsDir: string;
	/** Your skills library (pi's agent folder's skills/). */
	skillsDir: string;
	/** The project a folder is, made one if it isn't yet. */
	project(cwd: string): { id: string; path: string } | undefined;
	/** One of your agents, for a member that was one: its name and model. */
	agent(id: string): { name: string; model?: string } | undefined;
	log(line: string): void;
};

export type Migration = {
	work: ProjectWork[];
	routines: { project: string; path: string; routines: ProjectRoutine[]; fired?: string[] }[];
	/** Old team id → the project it worked in, for the sessions' catalog. */
	projectOf: Map<string, string>;
	report: string;
};

export const REPORT_FILE = "work-migration.md";

const read = <T>(file: string): T | undefined => {
	try {
		return existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as T) : undefined;
	} catch {
		return undefined;
	}
};
const slugOf = (name: string) => name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "team";
/** A markdown file's text without its title and comments. */
const textOf = (file: string): string => {
	try {
		return readFileSync(file, "utf8").replace(/<!--[\s\S]*?-->/g, "").replace(/^# .*\n?/, "").trim();
	} catch {
		return "";
	}
};

/** Whether there's anything from before 26 to migrate. */
export function needsMigration(home: string): boolean {
	return existsSync(join(home, "teams.json")) || existsSync(join(home, "team-definitions.json"));
}

export function migrateTeams(host: MigrationHost): Migration {
	const teamsFile = join(host.home, "teams.json");
	const defsFile = join(host.home, "team-definitions.json");
	const teams = read<OldTeam[]>(teamsFile) ?? [];
	const defs = read<OldDefinition[]>(defsFile) ?? [];
	const out: Migration = { work: [], routines: [], projectOf: new Map(), report: "" };
	const lines: string[] = [];
	const notes: string[] = [];

	for (const team of teams) {
		const project = host.project(team.cwd);
		if (!project) {
			notes.push(`- **${team.name}**: its folder (${team.cwd}) couldn't become a project, so its board wasn't kept. Its folder is untouched.`);
			continue;
		}
		out.projectOf.set(team.id, project.id);
		const def = defs.find((d) => d.id === team.definitionId);
		const roles = team.roles?.length ? team.roles : (def?.roles ?? []);
		const writers = roles.filter((r) => r.kind === "write");
		const reviewer = roles.find((r) => r.kind === "review");
		const modelOf = (r?: OldRole) => r?.model ?? (r?.agent ? host.agent(r.agent)?.model : undefined) ?? team.model;
		const buildModel = modelOf(writers[0]);
		const reviewModel = reviewer ? modelOf(reviewer) : undefined;
		// The team's own text, when it differs from the built-in playbook it started from.
		const builtin = BUILTIN_PLAYBOOKS.find((p) => p.id === team.template);
		// The built-in research team had a second writer, the Editor, that its playbook now names in its plan.
		const extra = builtin?.id === "research" ? writers.slice(1).every((r) => r.name === "Editor") && writers.length === 2 : writers.length === 1;
		const same = !!builtin && extra && writers[0]!.responsibility === builtin.build.text && (!reviewer || reviewer.responsibility === builtin.review?.text) && (builtin.id === "research" || team.style === builtin.plan);
		let playbook = same ? builtin.id : "";
		if (!playbook) playbook = writePlaybook(join(project.path, ".pi", "skills"), team.name, team.style, writers, reviewer, host);
		const work: ProjectWork = {
			id: team.id,
			project: project.id,
			cwd: project.path,
			slug: team.slug || slugOf(team.name),
			way: {
				...DEFAULT_WAY,
				parallel: true,
				review: !!reviewer,
				reviewLimit: team.reviewLimit ?? 3,
				...(team.testCommand ? { testCommand: team.testCommand } : {}),
				maxParallel: team.maxParallel || 3,
				...(buildModel ? { buildModel } : {}),
				...(reviewModel && reviewModel !== buildModel ? { reviewModel } : {}),
				helperMode: team.memberMode ?? "auto_edit",
				...(team.budgetPerJob ? { budgetPerJob: team.budgetPerJob } : {}),
				playbook,
			},
			...(team.git ? { git: team.git } : {}),
			tasks: (team.tasks ?? []).map(({ role, by, ...t }) => ({ ...t, helper: roles.find((r) => r.id === role)?.name ?? "Helper", by: by === "you" ? "you" : "piopio" })),
			nextTask: team.nextTask || (team.tasks?.length ?? 0) + 1,
			createdAt: team.createdAt,
		};
		out.work.push(work);
		if (team.routines?.length) out.routines.push({ project: project.id, path: project.path, routines: team.routines.map((r) => ({ ...r, by: (r.by as string) === "you" ? "you" : "piopio" })), ...(team.fired ? { fired: team.fired } : {}) });

		// What the team knew goes into the project's notes.
		const brief = textOf(join(team.folder, "TEAM.md"));
		const learned = textOf(join(team.folder, "NOTES.md")).replace(/^#.*\n?/, "").trim();
		if (brief || learned) {
			const file = join(project.path, "NOTES.md");
			const section = [`\n\n## From ${team.name}\n`, brief ? `What every member was told (TEAM.md):\n\n${brief}\n` : "", learned ? `\nWhat the team noted:\n\n${learned}\n` : ""].join("");
			try {
				if (existsSync(file)) appendFileSync(file, section);
				else writeFileSync(file, `# Notes${section}`);
			} catch (error) {
				host.log(`Migration: couldn't write ${file}: ${(error as Error).message}`);
			}
		}

		const name = project.path.split("/").pop();
		const parts = [
			`- **${team.name}** in **${name}** is now how work is done there: parallel work on, ${reviewer ? `review on (sent back at most ${work.way.reviewLimit} times)` : "no review"}, ${work.way.maxParallel} tasks at once${team.testCommand ? `, checks \`${team.testCommand}\`` : ""}${buildModel ? `, helpers on ${buildModel}` : ""}. Its board, branch and ${work.tasks.length === 1 ? "task" : `${work.tasks.length} tasks`} are as they were.`,
		];
		if (!same) parts.push(`  Its members' instructions are the project's playbook “${playbook}” (${join(project.path, ".pi", "skills", playbook, "SKILL.md")}).`);
		if (brief || learned) parts.push(`  TEAM.md and the team's notes were added to the project's NOTES.md, under “From ${team.name}”.`);
		const agents = roles.filter((r) => r.agent && r.kind !== "lead").map((r) => host.agent(r.agent!)?.name ?? r.name);
		if (agents.length) parts.push(`  ${agents.join(", ")} ${agents.length === 1 ? "stays one of your agents" : "stay your agents"}; ${agents.length === 1 ? "its" : "their"} model carried over to the helpers, but not ${agents.length === 1 ? "its" : "their"} instructions.`);
		lines.push(parts.join("\n"));
	}

	// Teams no project uses, and your templates: playbooks in your skills library.
	const library: string[] = [];
	for (const def of defs) {
		if (!def.saved || teams.some((t) => t.definitionId === def.id)) continue;
		const writers = def.roles.filter((r) => r.kind === "write");
		if (!writers.length) continue;
		library.push(writePlaybook(host.skillsDir, def.name, def.style, writers, def.roles.find((r) => r.kind === "review"), host));
	}
	for (const t of readTemplateFolders(join(host.teamsDir, "Templates"))) {
		const writers = t.roles.filter((r) => r.kind === "write");
		if (!writers.length) continue;
		library.push(writePlaybook(host.skillsDir, t.name, t.style, writers, t.roles.find((r) => r.kind === "review"), host));
	}
	if (library.length) lines.push(`- Teams no project used, and your team templates, became playbooks in your skills library (${host.skillsDir}): ${library.map((x) => `“${x}”`).join(", ")}.`);

	// Nothing is deleted: the old files stay, renamed, and the team folders where they are.
	for (const file of [teamsFile, defsFile]) {
		if (!existsSync(file)) continue;
		try {
			renameSync(file, `${file.replace(/\.json$/, "")}.before-26.json`);
		} catch (error) {
			host.log(`Migration: couldn't rename ${file}: ${(error as Error).message}`);
		}
	}
	if (lines.length || notes.length) {
		out.report = [
			"# What changed in your teams",
			"Teams aren't something you make any more. Every conversation in a project is with Piopio, which splits work onto the board itself and makes a helper for each task. What a team decided is now the project's way of working, in its settings.",
			...lines,
			...notes,
			`Your conversations with a team's lead are conversations with Piopio, with their history and tasks. The team folders in ${host.teamsDir} are untouched, and the old team files are kept as teams.before-26.json and team-definitions.before-26.json.`,
		].join("\n\n");
		writeFileSync(join(host.home, REPORT_FILE), `${out.report}\n`);
	}
	return out;
}

/** A playbook from a team's members, as a SKILL.md in `dir`; its id. */
function writePlaybook(dir: string, team: string, style: string, writers: OldRole[], reviewer: OldRole | undefined, host: MigrationHost): string {
	const base = `how-${slugOf(team).replace(/-team$/, "")}-works`;
	let id = base;
	for (let n = 2; existsSync(join(dir, id)); n++) id = `${base}-${n}`;
	const part = (r: OldRole): HelperPart => ({ name: r.name, text: r.responsibility.trim() || `You're the ${r.name}.`, ...(r.done ? { done: r.done } : {}) });
	const [first, ...others] = writers;
	const also = others.length ? `\n\nTasks can also go to ${others.map((r) => `a helper called “${r.name}” (create_task with helper "${r.name}"), whose brief should say: ${r.responsibility.trim()}${r.done ? ` Done means: ${r.done.trim()}` : ""}`).join("; and to ")}.` : "";
	try {
		mkdirSync(join(dir, id), { recursive: true });
		writeFileSync(join(dir, id, "SKILL.md"), playbookFile({ id, name: `How ${team} works`, description: `How ${team} planned, split, did and checked its work: use it to plan parallel work here.`, plan: `${style.trim() || "Give each helper a separate part."}${also}`, build: part(first!), ...(reviewer ? { review: part(reviewer) } : {}) }));
	} catch (error) {
		host.log(`Migration: couldn't write the playbook ${join(dir, id)}: ${(error as Error).message}`);
	}
	return id;
}

/** Your team templates (folders with TEAM.md and roles/), read as they were. */
function readTemplateFolders(dir: string): { name: string; style: string; roles: OldRole[] }[] {
	if (!existsSync(dir)) return [];
	const out: { name: string; style: string; roles: OldRole[] }[] = [];
	for (const name of readdirSync(dir).sort()) {
		const teamFile = join(dir, name, "TEAM.md");
		const rolesDir = join(dir, name, "roles");
		if (!existsSync(teamFile) || !existsSync(rolesDir)) continue;
		const team = parseCard(readFileSync(teamFile, "utf8"));
		const roles: OldRole[] = [];
		for (const file of readdirSync(rolesDir).filter((f) => f.endsWith(".md")).sort()) {
			const { meta, body } = parseCard(readFileSync(join(rolesDir, file), "utf8"));
			if (!meta.name || !["lead", "write", "review", "integrate"].includes(meta.kind ?? "")) continue;
			roles.push({ id: file.replace(/\.md$/, ""), name: meta.name, kind: meta.kind as OldRole["kind"], responsibility: body, ...(meta.done ? { done: meta.done } : {}) });
		}
		out.push({ name: team.meta.name || name, style: team.meta.style || "", roles });
	}
	return out;
}
