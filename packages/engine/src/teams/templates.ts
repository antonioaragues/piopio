/**
 * Team templates and role cards (docs/spec/19 §2, §4; the user's team idea, §10). A role is what it carries, not a
 * title: a responsibility, what "done" means, what it may do (its kind), and optionally its own model. A team is a set
 * of roles, a lead's way of working and a workplace. Development is one template; research and writing work in the
 * team's own folder, without git.
 */

/**
 * What a role may do, which decides how the board runs it:
 * - `lead`: plans, writes briefs, assigns, reads reports. Read only, with the board's tools. One per team.
 * - `write`: does a task's work (a builder, a researcher, a writer). Several can run at once, each on its own task.
 * - `review`: checks each finished task against its "done" (a QA, an editor) and gives a verdict; a rejection sends
 *   the task back to whoever wrote it.
 * - `integrate`: merges approved work into the team's branch and runs its checks (CI). Mechanical; git workplaces only.
 */
export type RoleKind = "lead" | "write" | "review" | "integrate";

export type Role = {
	id: string;
	name: string;
	kind: RoleKind;
	/** What this role is responsible for, in the second person. */
	responsibility: string;
	/** What "done" means for its work. */
	done?: string;
	/** Its own model ("provider:id" or an OpenRouter id); unset: the agent's, else the team's. */
	model?: string;
	/** An agent this member is (docs/spec/20 §3): it brings its instructions, and its model when the role has none. */
	agent?: string;
};

export type TeamTemplate = {
	id: string;
	name: string;
	description: string;
	/** "project": works in a project folder (git: each task on its own branch). "folder": the team's own folder. */
	workplace: "project" | "folder";
	roles: Role[];
	/** The lead's way of working, added to its responsibility. */
	style: string;
	/** What every member is told (a new team's TEAM.md). */
	instructions?: string;
	/** Built in, or one of yours (a folder in ~/Piopio/Teams/Templates, docs/spec/20 P4). */
	source?: "builtin" | "yours";
	folder?: string;
};

export const LEAD_BASE =
	"You lead this team. Answer questions and make small changes yourself, like any conversation in the project. Put bigger work, or work that can run in parallel, on the board: split it into tasks with clear briefs (what to do, where, what done means), put them on the board with create_task, and read the reports that come back. Keep tasks independent: two tasks that would change the same files are one task. When the goal is met, tell the user in a few lines what was done and what's left.";

export const TEAM_TEMPLATES: TeamTemplate[] = [
	{
		id: "development",
		name: "Development team",
		description: "A tech lead plans, builders work in parallel on their own branches, QA reviews each task, CI merges and runs the tests.",
		workplace: "project",
		style: "Builders can work in parallel, each on its own branch; give each one a separate part (a module, a screen, a package). If parts share an interface, settle it first in its own task.",
		roles: [
			{ id: "lead", name: "Tech lead", kind: "lead", responsibility: LEAD_BASE },
			{
				id: "builder",
				name: "Builder",
				kind: "write",
				responsibility: "You build what your task asks, in this branch only. Keep the change focused, follow the project's style, and run the relevant tests before you say you're done.",
				done: "The change does what the brief asks, the relevant tests pass, and nothing outside the task changed.",
			},
			{
				id: "qa",
				name: "QA",
				kind: "review",
				responsibility: "You check a finished task with fresh eyes: read the diff, run the tests and try what the brief asks for. You don't fix things; you say exactly what's wrong.",
			},
			{ id: "ci", name: "CI", kind: "integrate", responsibility: "Merges approved work into the team's branch and runs the checks." },
		],
	},
	{
		id: "research",
		name: "Research team",
		description: "A lead splits a question, researchers look into it in parallel and write notes, an editor turns them into one report.",
		workplace: "folder",
		style: "Give each researcher a different angle or set of sources, so they don't repeat each other. When their notes are in, give the editor a task to merge them into one report.",
		roles: [
			{ id: "lead", name: "Research lead", kind: "lead", responsibility: LEAD_BASE },
			{
				id: "researcher",
				name: "Researcher",
				kind: "write",
				responsibility: "You research your angle with the web and the files you're given, and write your findings to notes/<your task id>.md with the sources as links.",
				done: "A notes file with the findings and a link for every claim.",
			},
			{
				id: "editor",
				name: "Editor",
				kind: "write",
				responsibility: "You merge the researchers' notes into one clear report, keeping the sources, and point out where they disagree.",
				done: "report.md, readable on its own, every claim with its source.",
			},
		],
	},
	{
		id: "writing",
		name: "Writing team",
		description: "A lead plans the pieces, a writer drafts each one, an editor reviews it and sends it back until it's right.",
		workplace: "folder",
		style: "One piece per task. Say who it's for, the tone and the length in the brief.",
		roles: [
			{ id: "lead", name: "Editor in chief", kind: "lead", responsibility: LEAD_BASE },
			{
				id: "writer",
				name: "Writer",
				kind: "write",
				responsibility: "You write the piece your task asks for, as a Markdown file in this folder, for the reader and tone in the brief.",
				done: "The piece is complete, fits the brief's reader, tone and length, and has no placeholders.",
			},
			{
				id: "editor",
				name: "Editor",
				kind: "review",
				responsibility: "You review a finished piece against its brief: clarity, accuracy, tone, length. You don't rewrite it; you say what to change.",
			},
		],
	},
];

export function template(id: string): TeamTemplate | undefined {
	return TEAM_TEMPLATES.find((t) => t.id === id);
}
