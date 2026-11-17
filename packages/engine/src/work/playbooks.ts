/**
 * Playbooks (docs/spec/26 CL6): how a kind of work is planned, split, done and checked. Piopio plans with the project's
 * playbook, and each helper is told the playbook's part for its kind. The built-in ones are the old team templates'
 * text; a project's own is a skill in its folder (`.pi/skills/<id>/SKILL.md`), with a section per part:
 *
 *     ## Planning
 *     ## Doing tasks: Builder
 *     ## Reviewing: QA
 *
 * Choosing among several playbooks, and saving one after a job, come with C3.
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** What a helper does: a task's work, or a review of it. Merging is mechanical (the board, with the checks). */
export type HelperKind = "build" | "review";

export type HelperPart = {
	/** What the helper is called on the board: "Builder", "QA". */
	name: string;
	/** Its responsibility, in the second person. */
	text: string;
	/** What "done" means for its work, when the task doesn't say. */
	done?: string;
};

export type Playbook = {
	id: string;
	name: string;
	description: string;
	/** How Piopio splits work with it. */
	plan: string;
	build: HelperPart;
	/** Without one, review uses the generic reviewer's text. */
	review?: HelperPart;
	source: "builtin" | "project";
	/** A project playbook's SKILL.md. */
	file?: string;
};

/** What Piopio is told about the board in a project with parallel work on (docs/spec/26 CL3, §7.1–§7.2). */
export const PIOPIO_BOARD = `Parallel work is on in this project: you can put tasks on its board, and helpers you make for them do the work while you keep talking with the user.

Do things yourself by default: answer questions and make small or single changes here, in the conversation. Put work on the board only when it splits into parts that really can run at the same time, and each part is big enough to be worth a helper. A role or a kind of expertise isn't a reason to split; independent parts are. Two parts that would change the same files are one task. Changes that run in parallel go on the board with create_task, not to a task subagent: the board gives each its own branch, a review and the checks; task subagents are for read-only pieces (a wide search, a long trace).

For each task, write a brief another person could do without asking: what to do, where, and what done means. Helpers know nothing of this conversation.

A helper's report isn't proof. Before you tell the user a task is done, or that work is ready to merge, look at what changed (the diff, the files, the checks' output) and say what you checked.`;

const GENERIC_REVIEW: HelperPart = {
	name: "Reviewer",
	text: "You check a finished task with fresh eyes against its brief and what done means: read what changed, run what can be run, try what the brief asks for. You don't redo the work; you say exactly what to change.",
};

export const BUILTIN_PLAYBOOKS: Playbook[] = [
	{
		id: "development",
		name: "Development",
		description: "Builders work in parallel on their own branches, a reviewer checks each task, the board merges it and runs the checks.",
		plan: "Builders can work in parallel, each on its own branch; give each one a separate part (a module, a screen, a package). If parts share an interface, settle it first in its own task.",
		build: {
			name: "Builder",
			text: "You build what your task asks, in this branch only. Keep the change focused, follow the project's style, and run the relevant tests before you say you're done.",
			done: "The change does what the brief asks, the relevant tests pass, and nothing outside the task changed.",
		},
		review: {
			name: "QA",
			text: "You check a finished task with fresh eyes: read the diff, run the tests and try what the brief asks for. You don't fix things; you say exactly what's wrong.",
		},
		source: "builtin",
	},
	{
		id: "general",
		name: "General",
		description: "Helpers each do one independent part of the job in the project's folder; a reviewer checks each one.",
		plan: "Give each helper a part that stands on its own (a document, a section, a set of files), and say exactly which files are its own, since helpers share the folder.",
		build: {
			name: "Helper",
			text: "You do the task in your brief, in this folder, and only change the files it names as yours: other helpers work here at the same time.",
			done: "What the brief asks for is done, in the files it names, and nothing else changed.",
		},
		source: "builtin",
	},
	{
		id: "research",
		name: "Research",
		description: "Researchers look into different angles of a question in parallel and write notes; an editor turns them into one report.",
		plan: 'Give each researcher a different angle or set of sources, so they don\'t repeat each other. When their notes are in, add one more task with helper "Editor": merge the notes into report.md, readable on its own, keeping every source, and say where the notes disagree.',
		build: {
			name: "Researcher",
			text: "You research your angle with the web and the files you're given, and write your findings to notes/<your task id>.md with the sources as links.",
			done: "A notes file with the findings and a link for every claim.",
		},
		source: "builtin",
	},
	{
		id: "writing",
		name: "Writing",
		description: "A writer drafts each piece, an editor reviews it and sends it back until it's right.",
		plan: "One piece per task. Say who it's for, the tone and the length in the brief.",
		build: {
			name: "Writer",
			text: "You write the piece your task asks for, as a Markdown file in this folder, for the reader and tone in the brief.",
			done: "The piece is complete, fits the brief's reader, tone and length, and has no placeholders.",
		},
		review: {
			name: "Editor",
			text: "You review a finished piece against its brief: clarity, accuracy, tone, length. You don't rewrite it; you say what to change.",
		},
		source: "builtin",
	},
];

/** A playbook's part for a helper of this kind. */
export function partFor(playbook: Playbook, kind: HelperKind): HelperPart {
	return kind === "build" ? playbook.build : (playbook.review ?? GENERIC_REVIEW);
}

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

/** A playbook as a SKILL.md: front matter for pi's skill discovery, a section per part. */
export function playbookFile(p: { id: string; name: string; description: string; plan: string; build: HelperPart; review?: HelperPart; notes?: string }): string {
	const part = (title: string, h: HelperPart) => `## ${title}: ${h.name}\n\n${h.text.trim()}${h.done ? `\n\nDone means: ${h.done.trim()}` : ""}`;
	const description = p.description.replace(/\s+/g, " ").trim();
	return [
		`---\nname: ${p.id}\ndescription: ${JSON.stringify(description)}\n---`,
		`# ${p.name}`,
		"A Piopio playbook: how work is planned and split here when it runs in parallel. Piopio plans with the first section; each helper is told its own.",
		`## Planning\n\n${p.plan.trim()}`,
		part("Doing tasks", p.build),
		...(p.review ? [part("Reviewing", p.review)] : []),
		...(p.notes?.trim() ? [`## Notes\n\n${p.notes.trim()}`] : []),
	].join("\n\n") + "\n";
}

/** A SKILL.md written by `playbookFile`, or one you wrote the same way; undefined when it has no Planning section. */
export function readPlaybook(file: string): Playbook | undefined {
	let text: string;
	try {
		text = readFileSync(file, "utf8");
	} catch {
		return undefined;
	}
	const { meta, body } = parseCard(text);
	const sections = new Map<string, { name: string; text: string }>();
	for (const chunk of body.split(/^## /m).slice(1)) {
		const [head = "", ...rest] = chunk.split("\n");
		const [title = "", name = ""] = head.split(":").map((x) => x.trim());
		sections.set(title.toLowerCase(), { name, text: rest.join("\n").trim() });
	}
	const plan = sections.get("planning");
	const build = sections.get("doing tasks");
	if (!plan || !build) return undefined;
	const part = (s: { name: string; text: string }, fallback: string): HelperPart => {
		const done = /\n?Done means: (.*)$/s.exec(s.text);
		return { name: s.name || fallback, text: done ? s.text.slice(0, done.index).trim() : s.text, ...(done ? { done: done[1]!.trim() } : {}) };
	};
	const review = sections.get("reviewing");
	const id = meta.name || file.split("/").at(-2) || "playbook";
	return {
		id,
		name: /^# (.+)$/m.exec(body)?.[1]?.trim() || id,
		description: meta.description || "",
		plan: plan.text,
		build: part(build, "Helper"),
		...(review ? { review: part(review, "Reviewer") } : {}),
		source: "project",
		file,
	};
}

/** A project's own playbooks: its skills that are playbooks. */
export function projectPlaybooks(cwd: string): Playbook[] {
	const dir = join(cwd, ".pi", "skills");
	if (!existsSync(dir)) return [];
	return readdirSync(dir)
		.sort()
		.map((name) => readPlaybook(join(dir, name, "SKILL.md")))
		.filter((p): p is Playbook => !!p);
}

/** The playbook a project plans with: its choice, else Development. */
export function playbookOf(cwd: string, id: string): Playbook {
	return projectPlaybooks(cwd).find((p) => p.id === id) ?? BUILTIN_PLAYBOOKS.find((p) => p.id === id) ?? BUILTIN_PLAYBOOKS[0]!;
}

/** A new project's playbook, from its folder (docs/spec/26 §4): a code project gets Development, others General. */
export function defaultPlaybook(git: boolean, code: boolean): string {
	return git || code ? "development" : "general";
}
