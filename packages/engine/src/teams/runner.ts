/**
 * Teams (docs/spec/19 T1–T2): a lead and its members working a goal through a board. Each task is a member's Build
 * session; in a git workplace it has its own worktree and branch, so several builders work at once. A finished task
 * goes to review when the team has a reviewer (QA, an editor), back to its writer when the review fails, and to
 * integration (CI: merged into the team's branch, then the checks) when the team has one. Every step is reported to
 * the lead as a message, so it reacts without waiting on anyone. The board is persisted; a restart picks up where it
 * was.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ApprovalMode } from "@piopio/protocol";
import type { Watch } from "@piopio/runtime";
import { EngineError } from "../models.js";
import { nextOf, parseWhen, routineLabel, systemZone, type TeamRoutine } from "./routines.js";
import { template, type Role, type TeamTemplate } from "./templates.js";

export type TaskState = "todo" | "doing" | "review" | "integrating" | "done" | "blocked";

export type TeamTask = {
	id: string;
	title: string;
	brief: string;
	done?: string;
	/** The role that does it (a `write` role). */
	role: string;
	state: TaskState;
	/** Who added it: the lead or you (the board is yours to edit too). */
	by: "lead" | "you";
	/** The lead conversation that made it (docs/spec/20 PT6): its updates go there. */
	conversationId?: string;
	sessionId?: string;
	reviewSessionId?: string;
	branch?: string;
	cwd?: string;
	report?: string;
	review?: string;
	/** Rounds sent back by review or integration. */
	attempts: number;
	blocked?: string;
	/** When its work reached the project's branch (merged from the team page). */
	landed?: string;
	createdAt: string;
	updatedAt: string;
};

/** What the team's branch would bring to the project's (the merge card). */
export type TeamLanding = {
	base: string;
	branch: string;
	/** Commits on the team's branch that the base doesn't have. */
	ahead: number;
	/** Commits on the base since the team branched (someone else's work). */
	behind: number;
	files: { path: string; added: number; removed: number }[];
	/** Done tasks not merged into the base yet. */
	tasks: { id: string; title: string }[];
	/** Tasks still on the board (to do, doing, in review). */
	open: number;
	/** The branch the project's folder is on. */
	checkedOut?: string;
	remote?: string;
	/** GitHub's page to open a pull request, once the branch is pushed. */
	compareUrl?: string;
};

export type Team = {
	id: string;
	name: string;
	slug: string;
	template: string;
	roles: Role[];
	style: string;
	/** Where the work happens: a project folder, or the team's own folder. */
	cwd: string;
	/** The team's folder: NOTES.md (what members keep for each other, TD7). */
	folder: string;
	git?: { base: string; branch: string; integration: string };
	/** The first lead conversation (from the goal), kept for tasks you add on the Board. Each conversation in the
	 * project is a lead of its own (docs/spec/20 PT6). */
	leadSessionId?: string;
	model?: string;
	memberMode: ApprovalMode;
	maxParallel: number;
	testCommand?: string;
	goal?: string;
	tasks: TeamTask[];
	nextTask: number;
	/** What starts work without you asking (docs/spec/19 T1): times, folders, emails, webhooks. */
	routines?: TeamRoutine[];
	/** Recent event keys, so the same file version, email or delivery never fires twice. */
	fired?: string[];
	createdAt: string;
};

export type TeamHost = {
	/** A Build session for a member or the lead. */
	createSession(params: { cwd: string; title: string; model?: string; approvalMode: ApprovalMode; team: { id: string; role: string; taskId?: string; kind: Role["kind"] } }): Promise<string>;
	/** Sends a message; it waits behind a turn that's running. */
	submit(sessionId: string, text: string): Promise<void>;
	/** Calls back each time the session finishes a turn, with its last answer; resolves once it's listening. */
	onSettled(sessionId: string, settled: (answer: string) => void): Promise<() => void>;
	/** Whether the session is idle now, and its last answer. */
	peek(sessionId: string): Promise<{ idle: boolean; answer: string }>;
	git(cwd: string, args: string[]): Promise<string>;
	isRepo(cwd: string): Promise<boolean>;
	branchOf(cwd: string): Promise<string | undefined>;
	addWorktree(repo: string, path: string, branch: string, base: string): Promise<void>;
	removeWorktree(repo: string, path: string, branch: string, force: boolean): Promise<void>;
	/** The checks (a test command), in a folder. */
	run(cwd: string, command: string): Promise<{ ok: boolean; output: string }>;
	worktreesDir: string;
	stateFile: string;
	changed(teamId: string): void;
	log(line: string): void;
};

const MAX_ATTEMPTS = 3;
/** A conversation's title from a request: its first line, at most 60 characters. */
const titleOf = (text: string) => {
	const line = text.trim().split("\n")[0]!.replace(/\s+/g, " ");
	return line.length > 60 ? `${line.slice(0, 59).trimEnd()}…` : line || "Team";
};
/** States still on the board's way to done. */
const OPEN = new Set<TaskState>(["todo", "doing", "review", "integrating"]);
const iso = () => new Date().toISOString();
/** A branch name in a URL path: its slashes stay. */
const ref = (name: string) => name.split("/").map(encodeURIComponent).join("/");
const quote = (text: string) => text.split("\n").map((l) => `> ${l}`).join("\n");

export class TeamRunner {
	private teams: Team[] = [];
	private readonly watching = new Map<string, () => void>();
	/** Review verdicts given in a turn that hasn't settled yet, by review session. */
	private readonly verdicts = new Map<string, { pass: boolean; notes: string }>();
	private timer?: NodeJS.Timeout;
	/** Each team's merges, in turn. */
	private readonly merging = new Map<string, Promise<void>>();
	private stopped = false;
	/** A webhook routine's URL (the hooks endpoint), set by the engine. */
	hookUrl?: (teamId: string, routineId: string) => string | undefined;
	/** Folder and email routines changed: the watchers start or stop theirs. */
	onRoutines?: () => void;
	/** Tests: the clock. */
	now: () => number = () => Date.now();

	constructor(private readonly host: TeamHost) {
		try {
			if (existsSync(host.stateFile)) this.teams = JSON.parse(readFileSync(host.stateFile, "utf8")) as Team[];
		} catch {
			this.teams = [];
		}
	}

	list(): Team[] {
		return this.teams;
	}

	has(id: string): boolean {
		return this.teams.some((t) => t.id === id);
	}

	get(id: string): Team {
		const team = this.teams.find((t) => t.id === id);
		if (!team) throw new EngineError("NOT_FOUND", `No team “${id}”.`);
		return team;
	}

	/** The team (and task) a session belongs to. */
	of(sessionId: string): { team: Team; task?: TeamTask; kind: Role["kind"] } | undefined {
		for (const team of this.teams) {
			if (team.leadSessionId === sessionId) return { team, kind: "lead" };
			const task = team.tasks.find((t) => t.sessionId === sessionId || t.reviewSessionId === sessionId);
			if (task) return { team, task, kind: task.reviewSessionId === sessionId ? "review" : "write" };
		}
		return undefined;
	}

	private save(team?: Team): void {
		mkdirSync(join(this.host.stateFile, ".."), { recursive: true });
		writeFileSync(this.host.stateFile, JSON.stringify(this.teams, null, "\t"));
		if (team) this.host.changed(team.id);
	}

	// ── Making a team ──

	async create(params: { name: string; template: string; cwd?: string; folder: string; model?: string; goal?: string; testCommand?: string; memberMode?: ApprovalMode; maxParallel?: number; initGit?: boolean }): Promise<Team> {
		const t: TeamTemplate | undefined = template(params.template);
		if (!t) throw new EngineError("INVALID", `No team template “${params.template}”.`);
		const name = params.name.trim() || t.name;
		const slug = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "team";
		if (t.workplace === "project" && !params.cwd) throw new EngineError("INVALID", `A ${t.name.toLowerCase()} works in a project: choose its folder.`);
		mkdirSync(params.folder, { recursive: true });
		const notes = join(params.folder, "NOTES.md");
		if (!existsSync(notes)) writeFileSync(notes, `# ${name}: notes\n\n<!-- What the team keeps for each other: decisions, conventions, how to run things. -->\n`);
		// Every team works in a project (docs/spec/20 PT2); the engine makes one when none is given.
		const cwd = params.cwd ?? params.folder;
		const taken = this.teams.find((x) => x.cwd === cwd);
		if (taken) throw new EngineError("INVALID", `This project already has a team, ${taken.name}. A project has one team (docs/spec/20 PT3).`);
		const id = `team_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
		const team: Team = {
			id,
			name,
			slug,
			template: t.id,
			roles: t.roles.map((r) => ({ ...r })),
			style: t.style,
			cwd,
			folder: params.folder,
			...(params.model ? { model: params.model } : {}),
			memberMode: params.memberMode ?? "auto_edit",
			maxParallel: params.maxParallel ?? 3,
			...(params.testCommand?.trim() ? { testCommand: params.testCommand.trim() } : {}),
			...(params.goal?.trim() ? { goal: params.goal.trim() } : {}),
			tasks: [],
			nextTask: 1,
			createdAt: iso(),
		};
		// Branches per task only when someone merges them (a CI role); others share the folder.
		const merges = t.roles.some((r) => r.kind === "integrate");
		// A new project's folder (New project with a team) becomes a git repo, so tasks can have branches.
		if (merges && params.initGit && !(await this.host.isRepo(cwd))) {
			await this.host.git(cwd, ["init", "-q", "-b", "main"]);
			await this.host.git(cwd, ["add", "-A"]);
			await this.host.git(cwd, ["-c", "user.name=Piopio", "-c", "user.email=piopio@localhost", "commit", "-q", "--allow-empty", "-m", "Start"]);
		}
		// In a git project the team works on its own branch, in its own worktree; tasks branch from it (T2).
		if (merges && (await this.host.isRepo(cwd))) {
			const base = (await this.host.branchOf(cwd)) ?? "HEAD";
			const branch = `team/${slug}-${id.slice(-4)}`;
			const integration = join(this.host.worktreesDir, id, "_team");
			await this.host.addWorktree(cwd, integration, branch, base);
			team.git = { base, branch, integration };
		}
		this.teams.push(team);
		this.save(team);
		// With a goal, its first conversation with the lead starts on it.
		if (team.goal) {
			team.leadSessionId = await this.newLead(team, titleOf(team.goal));
			this.save(team);
			await this.host.submit(team.leadSessionId, team.goal);
		}
		return team;
	}

	/** The lead role, for a conversation in the team's project. */
	leadRole(teamId: string): Role {
		return this.get(teamId).roles.find((r) => r.kind === "lead")!;
	}

	/** A new conversation with the lead in the team's project (a routine's run, or the goal). It edits like any
	 * conversation there (PT5). */
	async newLead(team: Team, title: string): Promise<string> {
		const lead = team.roles.find((r) => r.kind === "lead")!;
		return this.host.createSession({ cwd: team.cwd, title, ...(team.model ? { model: team.model } : {}), approvalMode: team.memberMode, team: { id: team.id, role: lead.id, kind: "lead" } });
	}

	/** What the lead is told about its team, each turn (system prompt). */
	leadBrief(team: Team): string {
		const lead = team.roles.find((r) => r.kind === "lead")!;
		const members = team.roles.filter((r) => r.kind !== "lead").map((r) => `- ${r.name} (role id "${r.id}", ${r.kind === "write" ? "does tasks; several can work at once" : r.kind === "review" ? "reviews every finished task; a failed review sends it back" : "merges approved work into the team branch and runs the checks"}): ${r.responsibility}`);
		const where = team.git ? `Each task gets its own branch from ${team.git.branch}; approved work is merged into ${team.git.branch}, which starts from ${team.git.base}. You don't merge into ${team.git.base}: when the board is clear, tell the user the work is ready; they merge it, or push it for a pull request, from the project's Board.` : `Everyone works in the project's folder, ${team.cwd}.`;
		return `${lead.responsibility}\n\n${team.style}\n\nYour team (${team.name}):\n${members.join("\n")}\n\n${where} At most ${team.maxParallel} tasks run at once; the rest wait their turn. Notes: ${join(team.cwd, "NOTES.md")} is about this project; ${join(team.folder, "NOTES.md")} is how the team works, across projects.\n\nThis is one of several conversations in the project; each has its own tasks, and the board shows them all. Updates on the tasks you made come here.\n\nMessages that start with [Board] are updates from the board, not from the user. Messages that start with [Routine] are one of the team's routines firing: plan them as you would the user's request.\n\nWhen the user wants work to start on its own (every Monday, when a file arrives, when an email comes), set a routine: schedule for times, watch for events. list_routines shows them; cancel_routine removes one.`;
	}

	// ── Routines ──

	/** The lead (`schedule`, `watch`) or you (the team page) add a routine. */
	async addRoutine(teamId: string, input: { on: TeamRoutine["on"]; prompt: string; when?: string; folder?: string; from?: string; subject?: string }, by: "lead" | "you"): Promise<TeamRoutine> {
		const team = this.get(teamId);
		const prompt = input.prompt.trim();
		if (!prompt) throw new EngineError("INVALID", "Say what the team should do then.");
		const now = this.now();
		const tz = systemZone();
		const routine: TeamRoutine = { id: `r${now.toString(36)}${Math.random().toString(36).slice(2, 5)}`, on: input.on, prompt, by, createdAt: new Date(now).toISOString(), runs: 0 };
		if (input.on === "time") {
			const when = parseWhen(input.when ?? "", tz, now);
			if ("error" in when) throw new EngineError("INVALID", when.error);
			Object.assign(routine, when, { tz });
			routine.next = nextOf(routine, now);
		} else if (input.on === "folder") {
			const folder = input.folder?.trim() ?? "";
			if (!/^(\/|~\/)/.test(folder)) throw new EngineError("INVALID", "Give the folder as an absolute path (/Users/…) or one starting with ~/.");
			routine.folder = folder;
		} else if (input.on === "email") {
			if (!input.from?.trim() && !input.subject?.trim()) throw new EngineError("INVALID", "Say whose emails (from) or which subject to watch for.");
			if (input.from?.trim()) routine.from = input.from.trim();
			if (input.subject?.trim()) routine.subject = input.subject.trim();
		}
		team.routines = [...(team.routines ?? []), routine];
		this.save(team);
		this.routinesChanged();
		return routine;
	}

	async removeRoutine(teamId: string, routineId: string, by: "lead" | "you"): Promise<TeamRoutine> {
		const team = this.get(teamId);
		const routine = team.routines?.find((r) => r.id === routineId);
		if (!routine) throw new EngineError("NOT_FOUND", `No routine ${routineId}.`);
		team.routines = team.routines!.filter((r) => r.id !== routineId);
		this.save(team);
		this.routinesChanged();
		return routine;
	}

	/** For the lead's `list_routines`. */
	routineList(teamId: string): string {
		const team = this.get(teamId);
		if (!team.routines?.length) return "No routines.";
		return team.routines
			.map((r) => {
				const url = r.on === "webhook" ? this.hookUrl?.(team.id, r.id) : undefined;
				const next = r.next ? `, next ${new Date(r.next).toISOString().slice(0, 16).replace("T", " ")} UTC` : "";
				return `- ${r.id}: ${routineLabel(r)}${next}${url ? ` (POST ${url})` : ""}: ${r.prompt}`;
			})
			.join("\n");
	}

	/** Folder and email routines, in the shape the watchers take (keyed by team id). */
	routineWatches(): { agentId: string; watches: Watch[] }[] {
		return this.teams
			.map((team) => ({
				agentId: team.id,
				watches: (team.routines ?? [])
					.filter((r) => r.on === "folder" || r.on === "email")
					.map((r) => ({ id: r.id, on: r.on as "folder" | "email", prompt: r.prompt, ...(r.folder ? { folder: r.folder } : {}), ...(r.from ? { from: r.from } : {}), ...(r.subject ? { subject: r.subject } : {}), createdAt: r.createdAt, by: r.by })),
			}))
			.filter((x) => x.watches.length);
	}

	/** A routine fires: a new conversation with the lead in the project, titled after it, gets it as a `[Routine]`
	 * message (docs/spec/20 §4). `key` keeps an event from firing twice. The run's id is that conversation's. */
	async fireRoutine(teamId: string, routineId: string, happened?: string, key?: string): Promise<{ runId: string }> {
		const team = this.get(teamId);
		const routine = team.routines?.find((r) => r.id === routineId);
		if (!routine) throw new EngineError("NOT_FOUND", `No routine ${routineId}.`);
		const dedupe = key ? `${routine.id}:${key}` : undefined;
		if (dedupe && team.fired?.includes(dedupe)) return { runId: routine.lastConversation ?? routine.id };
		if (dedupe) team.fired = [...(team.fired ?? []), dedupe].slice(-200);
		routine.runs++;
		routine.lastRun = new Date(this.now()).toISOString();
		this.save(team);
		const what = happened?.trim() ? `\n\nWhat happened:\n${quote(happened.trim().slice(0, 4000))}` : "";
		const conversation = await this.newLead(team, titleOf(routine.prompt));
		routine.lastConversation = conversation;
		this.save(team);
		await this.host.submit(conversation, `[Routine] ${routineLabel(routine)}: ${routine.prompt}${what}`);
		return { runId: conversation };
	}

	private routinesChanged(): void {
		this.arm();
		this.onRoutines?.();
	}

	/** Sleeps until the next time routine (at most an hour, so a changed clock is picked up). */
	private arm(): void {
		clearTimeout(this.timer);
		if (this.stopped) return;
		const next = Math.min(...this.teams.flatMap((t) => (t.routines ?? []).map((r) => r.next ?? Infinity)));
		if (!Number.isFinite(next)) return;
		this.timer = setTimeout(() => void this.tick().catch((error: unknown) => this.host.log(`Team routines: ${(error as Error).message}`)), Math.min(Math.max(next - this.now(), 0), 3_600_000));
		this.timer.unref?.();
	}

	/** Fires what's due (a fire missed while the engine was off runs once), then sets each one's next. */
	private async tick(): Promise<void> {
		const now = this.now();
		for (const team of this.teams) {
			const due = (team.routines ?? []).filter((r) => r.next !== undefined && r.next <= now);
			for (const r of due) {
				r.next = nextOf(r, now);
				await this.fireRoutine(team.id, r.id, undefined, `time:${Math.floor(now / 60_000)}`).catch((error: unknown) => this.host.log(`Routine ${r.id}: ${(error as Error).message}`));
			}
			// A once that has fired is done.
			if (due.length) {
				team.routines = (team.routines ?? []).filter((r) => r.on !== "time" || r.next !== undefined);
				this.save(team);
			}
		}
		this.arm();
	}

	// ── The board ──

	async createTask(teamId: string, task: { title: string; brief: string; done?: string; role?: string }, by: "lead" | "you" = "lead", conversationId?: string): Promise<TeamTask> {
		const team = this.get(teamId);
		const writers = team.roles.filter((r) => r.kind === "write");
		const role = task.role ? team.roles.find((r) => r.id === task.role || r.name.toLowerCase() === task.role!.toLowerCase()) : writers[0];
		if (!role || role.kind !== "write") throw new EngineError("INVALID", `Tasks go to ${writers.map((r) => `“${r.id}”`).join(" or ")}.`);
		const t: TeamTask = { id: `T${team.nextTask++}`, title: task.title.trim(), brief: task.brief.trim(), ...(task.done?.trim() ? { done: task.done.trim() } : {}), role: role.id, state: "todo", by, ...(conversationId ? { conversationId } : {}), attempts: 0, createdAt: iso(), updatedAt: iso() };
		team.tasks.push(t);
		this.save(team);
		if (by === "you") await this.tellLead(team, `You were given a task on the board: ${t.id} “${t.title}”.`, t);
		await this.pump(team);
		return t;
	}

	/** You moved or edited a card (TD5): back to To do, to Blocked, reassigned. */
	async updateTask(teamId: string, taskId: string, change: { state?: "todo" | "blocked" | "done"; role?: string; title?: string; brief?: string }): Promise<void> {
		const team = this.get(teamId);
		const t = team.tasks.find((x) => x.id === taskId);
		if (!t) throw new EngineError("NOT_FOUND", `No task ${taskId}.`);
		if (change.role) {
			const role = team.roles.find((r) => r.id === change.role && r.kind === "write");
			if (!role) throw new EngineError("INVALID", "That role doesn't do tasks.");
			t.role = role.id;
		}
		if (change.title?.trim()) t.title = change.title.trim();
		if (change.brief?.trim()) t.brief = change.brief.trim();
		if (change.state) {
			t.state = change.state;
			if (change.state !== "blocked") delete t.blocked;
			if (change.state === "blocked") t.blocked = "Stopped by you";
		}
		t.updatedAt = iso();
		this.save(team);
		await this.tellLead(team, `The user changed ${t.id} “${t.title}”: now ${t.state}${change.role ? `, for ${change.role}` : ""}.`, t);
		await this.pump(team);
	}

	/** The lead (or you) writes to a task's member. */
	async message(teamId: string, taskId: string, text: string): Promise<void> {
		const team = this.get(teamId);
		const t = team.tasks.find((x) => x.id === taskId);
		if (!t?.sessionId) throw new EngineError("INVALID", `${taskId} hasn't started.`);
		if (t.state === "done" || t.state === "blocked") {
			t.state = "doing";
			delete t.blocked;
			this.save(team);
			await this.watch(team, t);
		}
		await this.host.submit(t.sessionId, text);
	}

	board(teamId: string, conversationId?: string): string {
		const team = this.get(teamId);
		if (!team.tasks.length) return "The board is empty.";
		return team.tasks.map((t) => `${t.id} [${t.state}] ${t.title} (${t.role}${conversationId && t.conversationId === conversationId ? ", yours" : ""})${t.blocked ? ` — blocked: ${t.blocked}` : ""}${t.report && t.state === "done" ? `\n  Report: ${t.report.replace(/\s+/g, " ").slice(0, 300)}` : ""}`).join("\n");
	}

	/** A reviewer's verdict (the `verdict` tool); acted on when its turn ends. */
	verdict(sessionId: string, pass: boolean, notes: string): string {
		const where = this.of(sessionId);
		if (!where?.task || where.kind !== "review") return "Only a task's reviewer gives a verdict.";
		this.verdicts.set(sessionId, { pass, notes });
		return pass ? "Recorded: approved." : "Recorded: sent back with your notes.";
	}

	// ── Running ──

	/** Starts To do tasks while there's room. */
	private async pump(team: Team): Promise<void> {
		const busy = () => team.tasks.filter((t) => t.state === "doing" || t.state === "review" || t.state === "integrating").length;
		for (const t of team.tasks.filter((x) => x.state === "todo")) {
			if (busy() >= team.maxParallel) break;
			await this.start(team, t).catch((error: unknown) => this.block(team, t, (error as Error).message));
		}
	}

	private async start(team: Team, t: TeamTask): Promise<void> {
		const role = team.roles.find((r) => r.id === t.role)!;
		t.state = "doing";
		t.updatedAt = iso();
		if (!t.sessionId) {
			let cwd = team.cwd;
			if (team.git) {
				t.branch = `${team.git.branch}-${t.id.toLowerCase()}`;
				cwd = join(this.host.worktreesDir, team.id, t.id);
				await this.host.addWorktree(team.cwd, cwd, t.branch, team.git.branch);
			}
			t.cwd = cwd;
			t.sessionId = await this.host.createSession({ cwd, title: `${t.id} · ${t.title}`, ...((role.model ?? team.model) ? { model: role.model ?? team.model } : {}), approvalMode: team.memberMode, team: { id: team.id, role: role.id, taskId: t.id, kind: "write" } });
			this.save(team);
			await this.watch(team, t);
			await this.host.submit(t.sessionId, this.workPrompt(team, t, role));
		} else {
			this.save(team);
			await this.watch(team, t);
		}
	}

	private workPrompt(team: Team, t: TeamTask, role: Role): string {
		const where = team.git ? `You work on your own branch, ${t.branch}, in this folder; other members work on theirs at the same time. Don't switch branches.` : `You work in the project's folder, ${team.cwd}, alongside other members: only change the files your task is about.`;
		return [
			`You're the ${role.name} on ${team.name}. ${role.responsibility}`,
			`Your task, ${t.id}: ${t.title}\n\n${t.brief}`,
			t.done ?? role.done ? `Done means: ${t.done ?? role.done}` : "",
			`${where} Read the notes first: ${join(team.cwd, "NOTES.md")} (this project) and ${join(team.folder, "NOTES.md")} (how the team works). Add a line where it belongs for what your teammates will need.`,
			"When you finish, end with a short report: what you did, which files, how you checked it, and anything left open.",
		]
			.filter(Boolean)
			.join("\n\n");
	}

	private async watch(team: Team, t: TeamTask): Promise<void> {
		for (const id of [t.sessionId, t.reviewSessionId]) {
			if (!id || this.watching.has(id)) continue;
			this.watching.set(id, () => {});
			this.watching.set(id, await this.host.onSettled(id, (answer) => void this.settled(team.id, id, answer).catch((error: unknown) => this.host.log(`Team ${team.name}: ${(error as Error).message}`))));
		}
	}

	private async settled(teamId: string, sessionId: string, answer: string): Promise<void> {
		const team = this.get(teamId);
		const t = team.tasks.find((x) => x.sessionId === sessionId || x.reviewSessionId === sessionId);
		if (!t) return;
		if (sessionId === t.sessionId && t.state === "doing") return this.finishedWork(team, t, answer);
		if (sessionId === t.reviewSessionId && t.state === "review") return this.finishedReview(team, t, sessionId, answer);
	}

	/** The writer ended its turn: its report, then review, integration or done. */
	private async finishedWork(team: Team, t: TeamTask, answer: string): Promise<void> {
		t.report = answer.trim();
		t.updatedAt = iso();
		if (team.git && t.cwd) {
			// Commit what the task changed on its branch, so review and integration see one diff.
			const dirty = (await this.host.git(t.cwd, ["status", "--porcelain"])).trim();
			if (dirty) {
				await this.host.git(t.cwd, ["add", "-A"]);
				await this.host.git(t.cwd, ["-c", "user.name=Piopio", "-c", "user.email=piopio@localhost", "commit", "-q", "-m", `${t.id}: ${t.title}`]);
			}
		}
		const reviewer = team.roles.find((r) => r.kind === "review");
		if (reviewer) return this.startReview(team, t, reviewer);
		return this.approved(team, t);
	}

	private async startReview(team: Team, t: TeamTask, reviewer: Role): Promise<void> {
		t.state = "review";
		this.save(team);
		const diff = team.git ? `The task's changes are on ${t.branch}: see them with \`git diff ${team.git.branch}...HEAD\`.` : `The task's files are in ${team.cwd}.`;
		const prompt = [
			`You're the ${reviewer.name} on ${team.name}. ${reviewer.responsibility}`,
			`Review ${t.id}: ${t.title}\n\n${t.brief}`,
			t.done ? `Done means: ${t.done}` : "",
			`${diff}\n\nIts report:\n${quote(t.report || "(no report)")}`,
			"Then call verdict: pass true if it's done as asked, or false with exactly what to change.",
		]
			.filter(Boolean)
			.join("\n\n");
		if (!t.reviewSessionId) {
			t.reviewSessionId = await this.host.createSession({ cwd: t.cwd ?? team.cwd, title: `${t.id} · review`, ...((reviewer.model ?? team.model) ? { model: reviewer.model ?? team.model } : {}), approvalMode: team.memberMode, team: { id: team.id, role: reviewer.id, taskId: t.id, kind: "review" } });
			this.save(team);
			await this.watch(team, t);
		}
		await this.host.submit(t.reviewSessionId, prompt);
	}

	private async finishedReview(team: Team, t: TeamTask, sessionId: string, answer: string): Promise<void> {
		const verdict = this.verdicts.get(sessionId);
		this.verdicts.delete(sessionId);
		if (!verdict) {
			// No verdict: ask once more, then it's blocked.
			if ((t.review ?? "") !== "(asked)") {
				t.review = "(asked)";
				this.save(team);
				await this.host.submit(sessionId, "Give your verdict with the verdict tool: pass true or false, with notes.");
				return;
			}
			return this.block(team, t, "The review ended without a verdict.");
		}
		t.review = verdict.notes || answer.trim();
		if (verdict.pass) return this.approved(team, t);
		return this.sendBack(team, t, `The review found problems:\n${quote(verdict.notes || answer.trim())}\n\nFix them, then report again.`, "review");
	}

	private async sendBack(team: Team, t: TeamTask, message: string, by: "review" | "integration"): Promise<void> {
		t.attempts++;
		if (t.attempts >= MAX_ATTEMPTS) return this.block(team, t, `Sent back ${t.attempts} times by ${by}; it needs a decision.`);
		t.state = "doing";
		t.updatedAt = iso();
		this.save(team);
		await this.tellLead(team, `${t.id} “${t.title}” went back to its ${team.roles.find((r) => r.id === t.role)?.name ?? "writer"} (${by}, round ${t.attempts}).`, t);
		await this.host.submit(t.sessionId!, message);
	}

	/** Approved (or nothing to review): integrated when the team has CI and git, otherwise done. */
	private async approved(team: Team, t: TeamTask): Promise<void> {
		const ci = team.roles.find((r) => r.kind === "integrate");
		if (ci && team.git && t.branch) return this.integrate(team, t);
		return this.complete(team, t, "");
	}

	/** CI, one task at a time per team: they share the team's worktree, and two merges at once trip git's lock. */
	private integrate(team: Team, t: TeamTask): Promise<void> {
		t.state = "integrating";
		this.save(team);
		const turn = (this.merging.get(team.id) ?? Promise.resolve()).then(() => this.integrateNow(team, t));
		this.merging.set(team.id, turn.catch(() => undefined));
		return turn;
	}

	/** Merge the task's branch into the team's, then the checks. A conflict or a failing check goes back. */
	private async integrateNow(team: Team, t: TeamTask): Promise<void> {
		const git = team.git!;
		t.state = "integrating";
		this.save(team);
		try {
			await this.host.git(git.integration, ["-c", "user.name=Piopio", "-c", "user.email=piopio@localhost", "merge", "--no-ff", "-q", "-m", `Merge ${t.id}: ${t.title}`, t.branch!]);
		} catch (error) {
			await this.host.git(git.integration, ["merge", "--abort"]).catch(() => undefined);
			return this.sendBack(team, t, `Your branch conflicts with the team's branch (${git.branch}). Merge it into yours (\`git merge ${git.branch}\`), resolve the conflicts, check it still works, then report again.\n\n${quote((error as Error).message.slice(0, 2000))}`, "integration");
		}
		if (team.testCommand) {
			const result = await this.host.run(git.integration, team.testCommand);
			if (!result.ok) {
				await this.host.git(git.integration, ["reset", "-q", "--hard", "HEAD~1"]);
				return this.sendBack(team, t, `After merging into ${git.branch}, the checks failed (\`${team.testCommand}\`):\n\n${quote(result.output.slice(-3000))}\n\nFix it on your branch, then report again.`, "integration");
			}
		}
		await this.host.removeWorktree(team.cwd, t.cwd!, t.branch!, true).catch(() => undefined);
		return this.complete(team, t, ` Merged into ${git.branch}${team.testCommand ? ", checks passed" : ""}.`);
	}

	private async complete(team: Team, t: TeamTask, extra: string): Promise<void> {
		t.state = "done";
		t.updatedAt = iso();
		this.save(team);
		await this.tellLead(team, `${t.id} “${t.title}” is done.${extra}\n\nReport:\n${quote(t.report || "(none)")}${await this.readyNote(team)}`, t);
		await this.pump(team);
	}

	/** When the board is clear and the team's branch has work: it's ready for the user to merge. */
	private async readyNote(team: Team): Promise<string> {
		if (!team.git || team.tasks.some((t) => OPEN.has(t.state))) return "";
		const landing = await this.landing(team.id).catch(() => undefined);
		if (!landing?.ahead) return "";
		return `\n\nThe board is clear: ${landing.branch} has ${landing.tasks.length === 1 ? "1 task" : `${landing.tasks.length} tasks`} ready for ${landing.base} (${landing.files.length === 1 ? "1 file" : `${landing.files.length} files`}${team.testCommand ? ", checks passed" : ""}). Tell the user it's ready: they merge it into ${landing.base}, or push it for a pull request, from the team's Board.`;
	}

	/** One task per conversation among these, so each conversation hears once. */
	private firstOfEach(team: Team, ids: string[]): TeamTask[] {
		const seen = new Set<string>();
		return team.tasks.filter((t) => ids.includes(t.id) && !seen.has(t.conversationId ?? "") && seen.add(t.conversationId ?? ""));
	}

	// ── Landing: the team's branch into the project's ──

	async landing(teamId: string): Promise<TeamLanding> {
		const team = this.get(teamId);
		if (!team.git) throw new EngineError("INVALID", "This team doesn't work on a branch.");
		const { base, branch } = team.git;
		const git = (args: string[]) => this.host.git(team.cwd, args);
		const [behind = 0, ahead = 0] = (await git(["rev-list", "--left-right", "--count", `${base}...${branch}`])).trim().split(/\s+/).map(Number);
		const files = ahead
			? (await git(["diff", "--numstat", `${base}...${branch}`]))
					.split("\n")
					.filter(Boolean)
					.map((line) => {
						const [a, r, ...path] = line.split("\t");
						return { path: path.join("\t"), added: Number(a) || 0, removed: Number(r) || 0 };
					})
			: [];
		const remotes = (await git(["remote"]).catch(() => "")).split("\n").filter(Boolean);
		const remote = remotes.includes("origin") ? "origin" : remotes[0];
		const url = remote ? (await git(["remote", "get-url", remote]).catch(() => "")).trim() : "";
		const github = /github\.com[:/]([^/]+)\/([^/]+?)(?:\.git)?$/.exec(url);
		const checkedOut = await this.host.branchOf(team.cwd).catch(() => undefined);
		return {
			base,
			branch,
			ahead,
			behind,
			files,
			tasks: team.tasks.filter((t) => t.state === "done" && t.branch && !t.landed).map((t) => ({ id: t.id, title: t.title })),
			open: team.tasks.filter((t) => OPEN.has(t.state)).length,
			...(checkedOut ? { checkedOut } : {}),
			...(remote ? { remote } : {}),
			...(github ? { compareUrl: `https://github.com/${github[1]}/${github[2]}/compare/${ref(base)}...${ref(branch)}?expand=1` } : {}),
		};
	}

	/**
	 * You land the team's work (the merge card): `merge` it into the project's branch, in the project's folder when
	 * that branch is checked out there, otherwise in a temporary worktree; or `push` the team's branch for a pull
	 * request. A merge with conflicts changes nothing.
	 */
	async land(teamId: string, action: "merge" | "push"): Promise<{ commit?: string; compareUrl?: string; output?: string }> {
		const team = this.get(teamId);
		const landing = await this.landing(teamId);
		const { base, branch, integration } = team.git!;
		if (!landing.ahead) throw new EngineError("INVALID", `Nothing to merge: ${branch} has no work that ${base} doesn't have.`);
		if (action === "push") {
			if (!landing.remote) throw new EngineError("INVALID", "This project has no remote to push to.");
			const output = await this.host.git(integration, ["push", "-u", landing.remote, branch]);
			for (const t of this.firstOfEach(team, landing.tasks.map((x) => x.id))) await this.tellLead(team, `The user pushed ${branch} to ${landing.remote} for a pull request into ${base}.`, t);
			return { output, ...(landing.compareUrl ? { compareUrl: landing.compareUrl } : {}) };
		}
		const ids = landing.tasks.map((t) => t.id);
		const message = `Merge ${team.name}: ${ids.length ? ids.map((id) => `${id} ${team.tasks.find((t) => t.id === id)?.title ?? ""}`.trim()).join(", ") : branch}`;
		const here = landing.checkedOut === base;
		const dir = here ? team.cwd : join(this.host.worktreesDir, team.id, "_land");
		if (!here) await this.host.git(team.cwd, ["worktree", "add", "-q", dir, base]);
		try {
			const named = (await this.host.git(dir, ["config", "user.email"]).catch(() => "")).trim();
			const who = named ? [] : ["-c", "user.name=Piopio", "-c", "user.email=piopio@localhost"];
			await this.host.git(dir, [...who, "merge", "--no-ff", "-q", "-m", message, branch]).catch(async (error: unknown) => {
				await this.host.git(dir, ["merge", "--abort"]).catch(() => undefined);
				const first = String((error as Error).message).split("\n").find((l) => /CONFLICT|overwritten|error:/i.test(l)) ?? "";
				throw new EngineError("CONFLICT", `${base} changed in the same places as the team's work, so nothing was merged. Ask the lead to bring ${base} into ${branch} first. ${first}`.trim());
			});
		} finally {
			if (!here) await this.host.git(team.cwd, ["worktree", "remove", "--force", dir]).catch(() => undefined);
		}
		const commit = (await this.host.git(team.cwd, ["rev-parse", "--short", base])).trim();
		// The team's branch moves up to the merge, so its next tasks start from what's in the project now.
		await this.host.git(integration, ["merge", "--ff-only", "-q", base]).catch(() => undefined);
		const now = iso();
		for (const t of team.tasks) {
			if (!ids.includes(t.id)) continue;
			t.landed = now;
			if (t.branch) await this.host.git(team.cwd, ["branch", "-D", t.branch]).catch(() => undefined);
		}
		this.save(team);
		for (const t of this.firstOfEach(team, ids)) await this.tellLead(team, `The user merged ${branch} into ${base} (${commit}): ${ids.length ? ids.join(", ") : "the team's work"}. New tasks start from there.`, t);
		return { commit };
	}

	private async block(team: Team, t: TeamTask, why: string): Promise<void> {
		t.state = "blocked";
		t.blocked = why;
		t.updatedAt = iso();
		this.save(team);
		await this.tellLead(team, `${t.id} “${t.title}” is blocked: ${why}`, t);
		await this.pump(team);
	}

	/** A board update, to the conversation that made the task (PT6); without one, to the first lead conversation. */
	private async tellLead(team: Team, text: string, t?: TeamTask): Promise<void> {
		const to = t?.conversationId ?? team.leadSessionId;
		if (to) await this.host.submit(to, `[Board] ${text}`).catch((error: unknown) => this.host.log(`Team ${team.name}: ${(error as Error).message}`));
	}

	/** After a restart: watch running tasks again, and settle those whose turn ended meanwhile. */
	async resume(): Promise<void> {
		for (const team of this.teams) {
			for (const t of team.tasks) {
				if (t.state !== "doing" && t.state !== "review") continue;
				await this.watch(team, t).catch(() => undefined);
				const id = t.state === "doing" ? t.sessionId : t.reviewSessionId;
				const now = id ? await this.host.peek(id).catch(() => undefined) : undefined;
				if (id && now?.idle) await this.settled(team.id, id, now.answer).catch(() => undefined);
			}
			await this.pump(team).catch(() => undefined);
		}
		this.arm();
	}

	stop(): void {
		this.stopped = true;
		clearTimeout(this.timer);
		for (const off of this.watching.values()) off();
		this.watching.clear();
	}
}

/** The checks, through the login shell (so the project's tools are on PATH), with a time limit. */
export function runCommand(cwd: string, command: string, timeoutMs = 600_000): Promise<{ ok: boolean; output: string }> {
	return new Promise((resolve) => {
		const child = spawn(process.env.SHELL || "/bin/zsh", ["-lc", command], { cwd, env: process.env });
		let output = "";
		const add = (d: Buffer) => {
			output += d.toString();
			if (output.length > 200_000) output = output.slice(-100_000);
		};
		child.stdout.on("data", add);
		child.stderr.on("data", add);
		const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
		child.on("error", (error) => (clearTimeout(timer), resolve({ ok: false, output: error.message })));
		child.on("close", (code) => (clearTimeout(timer), resolve({ ok: code === 0, output })));
	});
}
