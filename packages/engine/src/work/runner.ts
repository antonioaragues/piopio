/**
 * A project's work (docs/spec/26): its way of working, its board and its branch. Every conversation in a project is
 * with Piopio. With parallel work on, Piopio puts tasks on the board, and each task gets a helper: a Build session
 * made for it, told the playbook's part for its kind and the task's brief. In a git project each task works in its own
 * worktree and branch, so several run at once; a finished task goes to a reviewer when review is on, back to its
 * helper when the review fails, and then is merged into the project's work branch with the checks. Every step is
 * reported to the conversation that made the task. The board is persisted; a restart picks up where it was.
 *
 * The project's routines live here too (docs/spec/21 AD5): each fire opens a conversation with Piopio there.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ApprovalMode, WayOfWorking, WorkLanding, WorkTask } from "@piopio/protocol";
import type { Watch } from "@piopio/runtime";
import { EngineError } from "../models.js";
import { detectLanguage, fitCheck } from "./fit.js";
import { BUILTIN_PLAYBOOKS, defaultPlaybook, partFor, PIOPIO_BOARD, playbookOf, projectPlaybooks, type HelperKind, type Playbook } from "./playbooks.js";
import { nextOf, parseWhen, routineLabel, systemZone, type ProjectRoutine } from "./routines.js";

export type TaskState = WorkTask["state"];
export type { WayOfWorking, WorkLanding, WorkTask };

/** A project's work: what the app shows as its Board, and how work is done there. */
export type ProjectWork = {
	/** Names its worktrees' folder; a migrated team keeps its id. */
	id: string;
	project: string;
	cwd: string;
	/** In branch names. */
	slug: string;
	way: WayOfWorking;
	git?: { base: string; branch: string; integration: string };
	tasks: WorkTask[];
	nextTask: number;
	createdAt: string;
};

export type WorkHost = {
	/** A Build session: a helper's, or (without `helper`) a conversation with Piopio (a routine's run). */
	createSession(params: { cwd: string; title: string; model?: string; approvalMode?: ApprovalMode; helper?: { project: string; kind: HelperKind; taskId: string } }): Promise<string>;
	/** A project by id or path: its id and folder. */
	project(idOrPath: string): { id: string; path: string } | undefined;
	/** What a session has cost so far, in USD. */
	cost?(sessionId: string): Promise<number>;
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
	/** Where the project routines are kept. */
	routinesFile: string;
	changed(project: string): void;
	log(line: string): void;
};

/** A project's routines, keyed by the project's id. */
type ProjectRoutines = { project: string; path: string; routines: ProjectRoutine[]; fired?: string[] };

export const DEFAULT_WAY: Omit<WayOfWorking, "playbook"> = { parallel: false, review: true, reviewLimit: 3, maxParallel: 3, helperMode: "auto_edit" };

/** A conversation's title from a request: its first line, at most 60 characters. */
const titleOf = (text: string) => {
	const line = text.trim().split("\n")[0]!.replace(/\s+/g, " ");
	return line.length > 60 ? `${line.slice(0, 59).trimEnd()}…` : line || "Routine";
};
/** States still on the board's way to done. */
const OPEN = new Set<TaskState>(["todo", "doing", "review", "integrating"]);
const iso = () => new Date().toISOString();
/** A branch name in a URL path: its slashes stay. */
const ref = (name: string) => name.split("/").map(encodeURIComponent).join("/");
const quote = (text: string) => text.split("\n").map((l) => `> ${l}`).join("\n");
const slugOf = (name: string) => name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "work";
const PIOPIO = ["-c", "user.name=Piopio", "-c", "user.email=piopio@localhost"];

export class WorkRunner {
	private work: ProjectWork[] = [];
	private readonly watching = new Map<string, () => void>();
	/** Review verdicts given in a turn that hasn't settled yet, by review session. */
	private readonly verdicts = new Map<string, { pass: boolean; notes: string }>();
	private timer?: NodeJS.Timeout;
	/** Each project's merges, in turn. */
	private readonly merging = new Map<string, Promise<void>>();
	private stopped = false;
	/** A webhook routine's URL (the hooks endpoint), set by the engine. */
	hookUrl?: (projectId: string, routineId: string) => string | undefined;
	/** Folder and email routines changed: the watchers start or stop theirs. */
	onRoutines?: () => void;
	/** Parallel work was switched on or off in a project: its open conversations pick up the board's tools. */
	onParallel?: (cwd: string) => Promise<void>;
	/** Tests: the clock. */
	now: () => number = () => Date.now();

	private places: ProjectRoutines[] = [];

	constructor(private readonly host: WorkHost) {
		this.work = readJson<ProjectWork[]>(host.stateFile) ?? [];
		this.places = readJson<ProjectRoutines[]>(host.routinesFile) ?? [];
		// Routines Piopio set used to be the lead's.
		let renamed = false;
		for (const r of this.places.flatMap((p) => p.routines)) {
			if ((r.by as string) === "lead") {
				r.by = "piopio";
				renamed = true;
			}
		}
		if (renamed) this.saveRoutines();
	}

	/** The migration's records, written before anything runs. */
	adopt(work: ProjectWork[], routines: ProjectRoutines[]): void {
		for (const w of work) if (!this.work.some((x) => x.project === w.project)) this.work.push(w);
		for (const place of routines) {
			const mine = this.places.find((p) => p.project === place.project);
			if (mine) {
				mine.routines.push(...place.routines.filter((r) => !mine.routines.some((x) => x.id === r.id)));
				mine.fired = [...(mine.fired ?? []), ...(place.fired ?? [])].slice(-200);
			} else this.places.push(place);
		}
		this.save();
		this.saveRoutines();
	}

	list(): ProjectWork[] {
		return this.work;
	}

	/** A project's work, if parallel work was ever switched on there. */
	find(project: string): ProjectWork | undefined {
		return this.work.find((w) => w.project === project);
	}

	get(project: string): ProjectWork {
		const work = this.find(project);
		if (!work) throw new EngineError("NOT_FOUND", "This project has no board yet: switch parallel work on first.");
		return work;
	}

	/** The work of the project a folder belongs to. */
	atPath(cwd: string): ProjectWork | undefined {
		const project = this.host.project(cwd);
		return project ? this.find(project.id) : undefined;
	}

	/** Whether Piopio has the board's tools in conversations in this folder's project. */
	parallelAt(cwd: string): boolean {
		return this.atPath(cwd)?.way.parallel ?? false;
	}

	/** The helper (and task) a session is. */
	of(sessionId: string): { work: ProjectWork; task: WorkTask; kind: HelperKind } | undefined {
		for (const work of this.work) {
			const task = work.tasks.find((t) => t.sessionId === sessionId || t.reviewSessionId === sessionId);
			if (task) return { work, task, kind: task.reviewSessionId === sessionId ? "review" : "build" };
		}
		return undefined;
	}

	private save(work?: ProjectWork): void {
		mkdirSync(dirname(this.host.stateFile), { recursive: true });
		writeFileSync(this.host.stateFile, JSON.stringify(this.work, null, "\t"));
		if (work) this.host.changed(work.project);
	}

	// ── The way of working (docs/spec/26 §4) ──

	/**
	 * You change how work is done in a project. The first time parallel work goes on, the project gets its record: the
	 * fit check's checks, the playbook for its folder, and in a git project a work branch in its own worktree.
	 */
	async configure(projectId: string, change: Partial<Omit<WayOfWorking, "buildModel" | "reviewModel" | "budgetPerJob">> & { buildModel?: string | null; reviewModel?: string | null; budgetPerJob?: number | null }): Promise<ProjectWork> {
		const project = this.host.project(projectId);
		if (!project) throw new EngineError("NOT_FOUND", `No project “${projectId}”.`);
		let work = this.find(project.id);
		const was = work?.way.parallel ?? false;
		if (!work) work = await this.open(project, change.parallel === true);
		const way = work.way;
		if (change.parallel !== undefined) way.parallel = change.parallel;
		if (change.review !== undefined) way.review = change.review;
		if (change.reviewLimit !== undefined) way.reviewLimit = Math.min(10, Math.max(1, Math.round(change.reviewLimit)));
		if (change.testCommand !== undefined) {
			if (change.testCommand.trim()) way.testCommand = change.testCommand.trim();
			else delete way.testCommand;
		}
		if (change.maxParallel !== undefined) way.maxParallel = Math.min(8, Math.max(1, Math.round(change.maxParallel)));
		for (const key of ["buildModel", "reviewModel"] as const) {
			const v = change[key];
			if (v === undefined) continue;
			if (v?.trim()) way[key] = v.trim();
			else delete way[key];
		}
		if (change.helperMode) way.helperMode = change.helperMode;
		if (change.budgetPerJob !== undefined) {
			if (change.budgetPerJob && change.budgetPerJob > 0) way.budgetPerJob = change.budgetPerJob;
			else delete way.budgetPerJob;
		}
		if (change.playbook !== undefined) {
			if (!this.playbooks(work.cwd).some((p) => p.id === change.playbook)) throw new EngineError("INVALID", `No playbook “${change.playbook}” here.`);
			way.playbook = change.playbook;
		}
		// Parallel work needs a branch to merge into, in a git project (it may have become one since).
		if (way.parallel && !work.git) await this.branch(work);
		this.save(work);
		if (was !== way.parallel) await this.onParallel?.(work.cwd).catch(() => undefined);
		await this.pump(work);
		return work;
	}

	/** A project's first record: off until you switch it on, with what the folder suggests. */
	private async open(project: { id: string; path: string }, parallel: boolean): Promise<ProjectWork> {
		const fit = fitCheck(project.path);
		const id = `work_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
		const work: ProjectWork = {
			id,
			project: project.id,
			cwd: project.path,
			slug: slugOf(project.path.split("/").pop() ?? "work"),
			way: { ...DEFAULT_WAY, parallel, ...(fit.checks ? { testCommand: fit.checks } : {}), playbook: defaultPlaybook(fit.git, !!detectLanguage(project.path)) },
			tasks: [],
			nextTask: 1,
			createdAt: iso(),
		};
		this.work.push(work);
		return work;
	}

	/** In a git project the work happens on its own branch, in its own worktree; tasks branch from it. */
	private async branch(work: ProjectWork): Promise<void> {
		if (!(await this.host.isRepo(work.cwd))) return;
		const base = (await this.host.branchOf(work.cwd)) ?? "HEAD";
		const branch = `work/${work.slug}-${work.id.slice(-4)}`;
		const integration = join(this.host.worktreesDir, work.id, "_work");
		await this.host.addWorktree(work.cwd, integration, branch, base);
		work.git = { base, branch, integration };
	}

	/** The playbooks a project can plan with. */
	playbooks(cwd: string): Playbook[] {
		return [...projectPlaybooks(cwd), ...BUILTIN_PLAYBOOKS];
	}

	private playbook(work: ProjectWork): Playbook {
		return playbookOf(work.cwd, work.way.playbook);
	}

	/** What Piopio is told about the board, each turn, in a project with parallel work on. */
	brief(project: string): string {
		const work = this.get(project);
		const way = work.way;
		const pb = this.playbook(work);
		const build = partFor(pb, "build");
		const review = partFor(pb, "review");
		const helpers = [
			`- ${build.name} (does a task; several can work at once): ${build.text}`,
			...(way.review ? [`- ${review.name} (reviews every finished task; a failed review sends it back, at most ${way.reviewLimit} times before the user is asked): ${review.text}`] : []),
		];
		const where = work.git
			? `Each task gets its own branch from ${work.git.branch}; approved work is merged into ${work.git.branch}${way.testCommand ? ` and the checks run (\`${way.testCommand}\`)` : ""}. ${work.git.branch} starts from ${work.git.base}, and you don't merge into ${work.git.base}: when the board is clear, tell the user the work is ready; they merge it, or push it for a pull request, from the project's Board.`
			: `Helpers work in the project's folder, ${work.cwd}, at the same time: say in each brief which files are the task's own.`;
		return [
			PIOPIO_BOARD,
			`How work is split here (the ${pb.name} playbook):\n${pb.plan}`,
			`The helpers:\n${helpers.join("\n")}`,
			`${where} At most ${way.maxParallel} tasks run at once; the rest wait their turn.${way.budgetPerJob ? ` This conversation's tasks may spend $${way.budgetPerJob.toFixed(2)} in all; new tasks wait once that's reached.` : ""} ${join(work.cwd, "NOTES.md")} is the project's notes, which helpers read too.`,
			"This is one of several conversations in the project; each has its own tasks, and the board shows them all. Updates on the tasks you made come here, as messages that start with [Board]: they're from the board, not from the user. Messages that start with [Routine] are one of the project's routines firing: plan them as you would the user's request.",
			"When the user wants work to start on its own (every Monday, when a file arrives, when an email comes), set a routine: schedule for times, watch for events. list_routines shows them; cancel_routine removes one.",
		].join("\n\n");
	}

	// ── Jobs (docs/spec/21 D1): a conversation's tasks, and what they cost ──

	/** What a conversation's tasks have cost so far: their helpers' sessions. */
	async jobCost(project: string, conversationId: string): Promise<{ cost: number; tasks: number; budget?: number }> {
		const work = this.get(project);
		const tasks = work.tasks.filter((t) => t.conversationId === conversationId);
		let cost = 0;
		for (const t of tasks) for (const id of [t.sessionId, t.reviewSessionId]) if (id && this.host.cost) cost += await this.host.cost(id).catch(() => 0);
		return { cost, tasks: tasks.length, ...(work.way.budgetPerJob ? { budget: work.way.budgetPerJob } : {}) };
	}

	// ── Routines (docs/spec/21 AD5): a project's, fired with Piopio ──

	/** A project's routines, by its id. Its path comes from the engine's projects. */
	private placeOf(projectId: string, create = false): ProjectRoutines | undefined {
		let place = this.places.find((p) => p.project === projectId);
		if (!place && create) {
			const project = this.host.project(projectId);
			if (!project) throw new EngineError("NOT_FOUND", `No project “${projectId}”.`);
			place = { project: project.id, path: project.path, routines: [] };
			this.places.push(place);
		}
		return place;
	}

	hasProject(id: string): boolean {
		return this.places.some((p) => p.project === id);
	}

	routines(projectId: string): ProjectRoutine[] {
		return this.placeOf(projectId)?.routines ?? [];
	}

	/** A routine for a project: Piopio's (`schedule`, `watch`) or yours (the project's settings). */
	async addRoutine(projectId: string, input: { on: ProjectRoutine["on"]; prompt: string; when?: string; folder?: string; from?: string; subject?: string }, by: "piopio" | "you"): Promise<ProjectRoutine> {
		const prompt = input.prompt.trim();
		if (!prompt) throw new EngineError("INVALID", "Say what should happen then.");
		const now = this.now();
		const tz = systemZone();
		const routine: ProjectRoutine = { id: `r${now.toString(36)}${Math.random().toString(36).slice(2, 5)}`, on: input.on, prompt, by, createdAt: new Date(now).toISOString(), runs: 0 };
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
		const place = this.placeOf(projectId, true)!;
		place.routines.push(routine);
		this.saveRoutines();
		this.routinesChanged();
		return routine;
	}

	async removeRoutine(projectId: string, routineId: string): Promise<ProjectRoutine> {
		const place = this.placeOf(projectId);
		const routine = place?.routines.find((r) => r.id === routineId);
		if (!place || !routine) throw new EngineError("NOT_FOUND", `No routine ${routineId}.`);
		place.routines = place.routines.filter((r) => r.id !== routineId);
		this.saveRoutines();
		this.routinesChanged();
		return routine;
	}

	/** For Piopio's `list_routines`. */
	routineList(projectId: string): string {
		const list = this.routines(projectId);
		if (!list.length) return "No routines.";
		return list
			.map((r) => {
				const url = r.on === "webhook" ? this.hookUrl?.(projectId, r.id) : undefined;
				const next = r.next ? `, next ${new Date(r.next).toISOString().slice(0, 16).replace("T", " ")} UTC` : "";
				return `- ${r.id}: ${routineLabel(r)}${next}${url ? ` (POST ${url})` : ""}: ${r.prompt}`;
			})
			.join("\n");
	}

	/** Folder and email routines, in the shape the watchers take (keyed by project id). */
	routineWatches(): { agentId: string; watches: Watch[] }[] {
		return this.places
			.map((place) => ({
				agentId: place.project,
				watches: place.routines
					.filter((r) => r.on === "folder" || r.on === "email")
					.map((r) => ({ id: r.id, on: r.on as "folder" | "email", prompt: r.prompt, ...(r.folder ? { folder: r.folder } : {}), ...(r.from ? { from: r.from } : {}), ...(r.subject ? { subject: r.subject } : {}), createdAt: r.createdAt, by: r.by })),
			}))
			.filter((x) => x.watches.length);
	}

	/**
	 * A routine fires: a new conversation with Piopio in its project, titled after it, gets it as a `[Routine]`
	 * message. `key` keeps an event from firing twice. The run's id is that conversation's.
	 */
	async fireRoutine(projectId: string, routineId: string, happened?: string, key?: string): Promise<{ runId: string }> {
		const place = this.placeOf(projectId);
		const routine = place?.routines.find((r) => r.id === routineId);
		if (!place || !routine) throw new EngineError("NOT_FOUND", `No routine ${routineId}.`);
		const dedupe = key ? `${routine.id}:${key}` : undefined;
		if (dedupe && place.fired?.includes(dedupe)) return { runId: routine.lastConversation ?? routine.id };
		if (dedupe) place.fired = [...(place.fired ?? []), dedupe].slice(-200);
		routine.runs++;
		routine.lastRun = new Date(this.now()).toISOString();
		this.saveRoutines();
		const what = happened?.trim() ? `\n\nWhat happened:\n${quote(happened.trim().slice(0, 4000))}` : "";
		const conversation = await this.host.createSession({ cwd: place.path, title: titleOf(routine.prompt) });
		routine.lastConversation = conversation;
		this.saveRoutines();
		await this.host.submit(conversation, `[Routine] ${routineLabel(routine)}: ${routine.prompt}${what}`);
		return { runId: conversation };
	}

	private saveRoutines(): void {
		mkdirSync(dirname(this.host.routinesFile), { recursive: true });
		writeFileSync(this.host.routinesFile, JSON.stringify(this.places, null, "\t"));
	}

	private routinesChanged(): void {
		this.arm();
		this.onRoutines?.();
	}

	/** Sleeps until the next time routine (at most an hour, so a changed clock is picked up). */
	private arm(): void {
		clearTimeout(this.timer);
		if (this.stopped) return;
		const next = Math.min(...this.places.flatMap((p) => p.routines.map((r) => r.next ?? Infinity)));
		if (!Number.isFinite(next)) return;
		this.timer = setTimeout(() => void this.tick().catch((error: unknown) => this.host.log(`Routines: ${(error as Error).message}`)), Math.min(Math.max(next - this.now(), 0), 3_600_000));
		this.timer.unref?.();
	}

	/** Fires what's due (a fire missed while the engine was off runs once), then sets each one's next. */
	private async tick(): Promise<void> {
		const now = this.now();
		for (const place of this.places) {
			const due = place.routines.filter((r) => r.next !== undefined && r.next <= now);
			for (const r of due) {
				r.next = nextOf(r, now);
				await this.fireRoutine(place.project, r.id, undefined, `time:${Math.floor(now / 60_000)}`).catch((error: unknown) => this.host.log(`Routine ${r.id}: ${(error as Error).message}`));
			}
			// A once that has fired is done.
			if (due.length) {
				place.routines = place.routines.filter((r) => r.on !== "time" || r.next !== undefined);
				this.saveRoutines();
			}
		}
		this.arm();
	}

	// ── The board ──

	/** A task on the board: Piopio's (`create_task`, from a conversation) or yours (the Board). */
	async createTask(project: string, task: { title: string; brief: string; done?: string; helper?: string }, by: "piopio" | "you" = "piopio", conversationId?: string): Promise<WorkTask> {
		const work = this.get(project);
		if (by === "piopio" && !work.way.parallel) throw new EngineError("INVALID", "Parallel work is off in this project: do the work in the conversation.");
		if (!task.title.trim() || !task.brief.trim()) throw new EngineError("INVALID", "A task needs a title and a brief.");
		const helper = task.helper?.trim() || partFor(this.playbook(work), "build").name;
		const t: WorkTask = { id: `T${work.nextTask++}`, title: task.title.trim(), brief: task.brief.trim(), ...(task.done?.trim() ? { done: task.done.trim() } : {}), helper, state: "todo", by, ...(conversationId ? { conversationId } : {}), attempts: 0, createdAt: iso(), updatedAt: iso() };
		work.tasks.push(t);
		this.save(work);
		await this.pump(work);
		return t;
	}

	/** You moved or edited a card: back to To do, to Blocked, done by hand. */
	async updateTask(project: string, taskId: string, change: { state?: "todo" | "blocked" | "done"; title?: string; brief?: string }): Promise<void> {
		const work = this.get(project);
		const t = work.tasks.find((x) => x.id === taskId);
		if (!t) throw new EngineError("NOT_FOUND", `No task ${taskId}.`);
		if (change.title?.trim()) t.title = change.title.trim();
		if (change.brief?.trim()) t.brief = change.brief.trim();
		if (change.state) {
			t.state = change.state;
			if (change.state !== "blocked") delete t.blocked;
			if (change.state === "blocked") t.blocked = "Stopped by you";
		}
		t.updatedAt = iso();
		this.save(work);
		await this.tell(work, `The user changed ${t.id} “${t.title}”: now ${t.state}.`, t);
		await this.pump(work);
	}

	/** Piopio (or you) writes to a task's helper. A done or blocked task starts again. */
	async message(project: string, taskId: string, text: string): Promise<void> {
		const work = this.get(project);
		const t = work.tasks.find((x) => x.id === taskId);
		if (!t?.sessionId) throw new EngineError("INVALID", `${taskId} hasn't started.`);
		if (t.state === "done" || t.state === "blocked") {
			t.state = "doing";
			delete t.blocked;
			this.save(work);
			await this.watch(work, t);
		}
		await this.host.submit(t.sessionId, text);
	}

	board(project: string, conversationId?: string): string {
		const work = this.get(project);
		if (!work.tasks.length) return "The board is empty.";
		return work.tasks.map((t) => `${t.id} [${t.state}] ${t.title} (${t.helper}${conversationId && t.conversationId === conversationId ? ", yours" : ""})${t.blocked ? ` — blocked: ${t.blocked}` : ""}${t.report && t.state === "done" ? `\n  Report: ${t.report.replace(/\s+/g, " ").slice(0, 300)}` : ""}`).join("\n");
	}

	/** A reviewer's verdict (the `verdict` tool); acted on when its turn ends. */
	verdict(sessionId: string, pass: boolean, notes: string): string {
		const where = this.of(sessionId);
		if (!where || where.kind !== "review") return "Only a task's reviewer gives a verdict.";
		this.verdicts.set(sessionId, { pass, notes });
		return pass ? "Recorded: approved." : "Recorded: sent back with your notes.";
	}

	// ── Running ──

	/** Starts To do tasks while there's room. */
	private async pump(work: ProjectWork): Promise<void> {
		const busy = () => work.tasks.filter((t) => t.state === "doing" || t.state === "review" || t.state === "integrating").length;
		for (const t of work.tasks.filter((x) => x.state === "todo")) {
			if (busy() >= work.way.maxParallel) break;
			// A job that reached its budget starts nothing new (docs/spec/21 D1); you raise it, or move the task back.
			if (work.way.budgetPerJob && t.conversationId) {
				const job = await this.jobCost(work.project, t.conversationId);
				if (job.cost >= work.way.budgetPerJob) {
					await this.block(work, t, `This job reached its budget ($${job.cost.toFixed(2)} of $${work.way.budgetPerJob.toFixed(2)}). Raise it in the project's settings, then move the task back to To do.`);
					continue;
				}
			}
			await this.start(work, t).catch((error: unknown) => this.block(work, t, (error as Error).message));
		}
	}

	private async start(work: ProjectWork, t: WorkTask): Promise<void> {
		t.state = "doing";
		t.updatedAt = iso();
		if (!t.sessionId) {
			let cwd = work.cwd;
			if (work.git) {
				await this.catchUp(work);
				t.branch = `${work.git.branch}-${t.id.toLowerCase()}`;
				cwd = join(this.host.worktreesDir, work.id, t.id);
				await this.host.addWorktree(work.cwd, cwd, t.branch, work.git.branch);
			}
			t.cwd = cwd;
			const model = this.modelOf(work, "build");
			t.sessionId = await this.host.createSession({ cwd, title: `${t.id} · ${t.title}`, ...(model ? { model } : {}), approvalMode: work.way.helperMode, helper: { project: work.project, kind: "build", taskId: t.id } });
			this.save(work);
			await this.watch(work, t);
			await this.host.submit(t.sessionId, this.workPrompt(work, t));
		} else {
			this.save(work);
			await this.watch(work, t);
		}
	}

	/** A helper's model: the way of working's for its kind; a reviewer falls back to the build model. */
	private modelOf(work: ProjectWork, kind: HelperKind): string | undefined {
		return kind === "review" ? (work.way.reviewModel ?? work.way.buildModel) : work.way.buildModel;
	}

	/** Who a helper is: its kind's part of the playbook. */
	private whoIs(work: ProjectWork, kind: HelperKind, name?: string): string {
		const part = partFor(this.playbook(work), kind);
		return `You're ${/^[aeiou]/i.test(name ?? part.name) ? "an" : "a"} ${name ?? part.name}: a helper Piopio made for one task in this project. ${part.text}`;
	}

	/**
	 * The work branch takes what the project's branch gained since (your commits, Piopio's changes you committed), so a
	 * new task starts from the project as it is. A fast-forward when the branch has nothing unmerged; otherwise a merge,
	 * left alone if it conflicts.
	 */
	private async catchUp(work: ProjectWork): Promise<void> {
		const git = work.git!;
		const behind = Number((await this.host.git(work.cwd, ["rev-list", "--count", `${git.branch}..${git.base}`]).catch(() => "0")).trim()) || 0;
		if (!behind) return;
		const ff = await this.host.git(git.integration, ["merge", "--ff-only", "-q", git.base]).then(() => true).catch(() => false);
		if (ff) return;
		await this.host.git(git.integration, [...PIOPIO, "merge", "--no-edit", "-q", git.base]).catch(async () => {
			await this.host.git(git.integration, ["merge", "--abort"]).catch(() => undefined);
			this.host.log(`Work in ${work.cwd}: ${git.base} conflicts with ${git.branch}; tasks start from the work branch.`);
		});
	}

	private workPrompt(work: ProjectWork, t: WorkTask): string {
		const part = partFor(this.playbook(work), "build");
		const where = work.git ? `You work on your own branch, ${t.branch}, in this folder; other helpers work on theirs at the same time. Don't switch branches, and don't commit: when you finish, the board commits your work on your branch, then review and merging follow.` : `You work in the project's folder, ${work.cwd}, alongside other helpers: only change the files your task is about.`;
		const done = t.done ?? part.done;
		return [
			this.whoIs(work, "build", t.helper),
			`Your task, ${t.id}: ${t.title}\n\n${t.brief}`,
			done ? `Done means: ${done}` : "",
			`${where} Read the project's notes first (${join(work.cwd, "NOTES.md")}), and add a line there for what others will need.`,
			"When you finish, end with a short report: what you did, which files, how you checked it, and anything left open.",
		]
			.filter(Boolean)
			.join("\n\n");
	}

	private async watch(work: ProjectWork, t: WorkTask): Promise<void> {
		for (const id of [t.sessionId, t.reviewSessionId]) {
			if (!id || this.watching.has(id)) continue;
			this.watching.set(id, () => {});
			this.watching.set(id, await this.host.onSettled(id, (answer) => void this.settled(work.project, id, answer).catch((error: unknown) => this.host.log(`Work in ${work.cwd}: ${(error as Error).message}`))));
		}
	}

	private async settled(project: string, sessionId: string, answer: string): Promise<void> {
		const work = this.get(project);
		const t = work.tasks.find((x) => x.sessionId === sessionId || x.reviewSessionId === sessionId);
		if (!t) return;
		if (sessionId === t.sessionId && t.state === "doing") return this.finishedWork(work, t, answer);
		if (sessionId === t.reviewSessionId && t.state === "review") return this.finishedReview(work, t, sessionId, answer);
	}

	/** The helper ended its turn: its report, then review, merging or done. */
	private async finishedWork(work: ProjectWork, t: WorkTask, answer: string): Promise<void> {
		t.report = answer.trim();
		t.updatedAt = iso();
		if (work.git && t.cwd) {
			// Commit what the task changed on its branch, so review and merging see one diff.
			const dirty = (await this.host.git(t.cwd, ["status", "--porcelain"])).trim();
			if (dirty) {
				await this.host.git(t.cwd, ["add", "-A"]);
				await this.host.git(t.cwd, [...PIOPIO, "commit", "-q", "-m", `${t.id}: ${t.title}`]);
			}
		}
		if (work.way.review) return this.startReview(work, t);
		return this.approved(work, t);
	}

	private async startReview(work: ProjectWork, t: WorkTask): Promise<void> {
		t.state = "review";
		this.save(work);
		const diff = work.git ? `The task's changes are on ${t.branch}: see them with \`git diff ${work.git.branch}...HEAD\`.` : `The task's files are in ${work.cwd}.`;
		const done = t.done ?? partFor(this.playbook(work), "build").done;
		const prompt = [
			this.whoIs(work, "review"),
			`Review ${t.id}: ${t.title}\n\n${t.brief}`,
			done ? `Done means: ${done}` : "",
			`${diff}\n\nIts report:\n${quote(t.report || "(no report)")}`,
			"Then call verdict: pass true if it's done as asked, or false with exactly what to change.",
		]
			.filter(Boolean)
			.join("\n\n");
		if (!t.reviewSessionId) {
			const model = this.modelOf(work, "review");
			t.reviewSessionId = await this.host.createSession({ cwd: t.cwd ?? work.cwd, title: `${t.id} · review`, ...(model ? { model } : {}), approvalMode: work.way.helperMode, helper: { project: work.project, kind: "review", taskId: t.id } });
			this.save(work);
			await this.watch(work, t);
		}
		await this.host.submit(t.reviewSessionId, prompt);
	}

	private async finishedReview(work: ProjectWork, t: WorkTask, sessionId: string, answer: string): Promise<void> {
		const verdict = this.verdicts.get(sessionId);
		this.verdicts.delete(sessionId);
		if (!verdict) {
			// No verdict: ask once more, then it's blocked.
			if ((t.review ?? "") !== "(asked)") {
				t.review = "(asked)";
				this.save(work);
				await this.host.submit(sessionId, "Give your verdict with the verdict tool: pass true or false, with notes.");
				return;
			}
			return this.block(work, t, "The review ended without a verdict.");
		}
		t.review = verdict.notes || answer.trim();
		if (verdict.pass) return this.approved(work, t);
		return this.sendBack(work, t, `The review found problems:\n${quote(verdict.notes || answer.trim())}\n\nFix them, then report again.`, "review");
	}

	/** Back to its helper; past the way of working's limit, it's blocked and the user is asked (docs/spec/26 §7.2). */
	private async sendBack(work: ProjectWork, t: WorkTask, message: string, by: "review" | "the checks"): Promise<void> {
		t.attempts++;
		if (t.attempts >= work.way.reviewLimit) return this.block(work, t, `Sent back ${t.attempts} times by ${by}; it needs the user's decision.`);
		t.state = "doing";
		t.updatedAt = iso();
		this.save(work);
		await this.tell(work, `${t.id} “${t.title}” went back to its ${t.helper} (${by}, round ${t.attempts}).`, t);
		await this.host.submit(t.sessionId!, message);
	}

	/** Approved (or nothing to review): merged into the work branch in a git project, otherwise done. */
	private async approved(work: ProjectWork, t: WorkTask): Promise<void> {
		if (work.git && t.branch) return this.integrate(work, t);
		return this.complete(work, t, "");
	}

	/** One merge at a time per project: they share the work branch's worktree, and two at once trip git's lock. */
	private integrate(work: ProjectWork, t: WorkTask): Promise<void> {
		t.state = "integrating";
		this.save(work);
		const turn = (this.merging.get(work.id) ?? Promise.resolve()).then(() => this.integrateNow(work, t));
		this.merging.set(work.id, turn.catch(() => undefined));
		return turn;
	}

	/** Merge the task's branch into the work branch, then the checks. A conflict or a failing check goes back. */
	private async integrateNow(work: ProjectWork, t: WorkTask): Promise<void> {
		const git = work.git!;
		t.state = "integrating";
		this.save(work);
		try {
			await this.host.git(git.integration, [...PIOPIO, "merge", "--no-ff", "-q", "-m", `Merge ${t.id}: ${t.title}`, t.branch!]);
		} catch (error) {
			await this.host.git(git.integration, ["merge", "--abort"]).catch(() => undefined);
			return this.sendBack(work, t, `Your branch conflicts with the work branch (${git.branch}). Merge it into yours (\`git merge ${git.branch}\`), resolve the conflicts, check it still works, then report again.\n\n${quote((error as Error).message.slice(0, 2000))}`, "the checks");
		}
		if (work.way.testCommand) {
			const result = await this.host.run(git.integration, work.way.testCommand);
			if (!result.ok) {
				await this.host.git(git.integration, ["reset", "-q", "--hard", "HEAD~1"]);
				return this.sendBack(work, t, `After merging into ${git.branch}, the checks failed (\`${work.way.testCommand}\`):\n\n${quote(result.output.slice(-3000))}\n\nFix it on your branch, then report again.`, "the checks");
			}
		}
		await this.host.removeWorktree(work.cwd, t.cwd!, t.branch!, true).catch(() => undefined);
		return this.complete(work, t, ` Merged into ${git.branch}${work.way.testCommand ? ", checks passed" : ""}.`);
	}

	private async complete(work: ProjectWork, t: WorkTask, extra: string): Promise<void> {
		t.state = "done";
		t.updatedAt = iso();
		this.save(work);
		// The reviewer's verdict comes with it (a trial with real models: the lead kept waiting for QA's word).
		const review = work.way.review && t.review && t.review !== "(asked)" ? `\n\n${partFor(this.playbook(work), "review").name} approved it:\n${quote(t.review)}` : "";
		const look = work.git && t.branch ? `\n\nBefore you say it's done, look at what changed: \`git diff ${work.git.base}...${work.git.branch}\` in the project's folder.` : "";
		await this.tell(work, `${t.id} “${t.title}” is done.${extra}\n\nReport:\n${quote(t.report || "(none)")}${review}${look}${await this.readyNote(work)}`, t);
		await this.pump(work);
	}

	/** When the board is clear and the work branch has work: it's ready for the user to merge. */
	private async readyNote(work: ProjectWork): Promise<string> {
		if (!work.git || work.tasks.some((t) => OPEN.has(t.state))) return "";
		const landing = await this.landing(work.project).catch(() => undefined);
		if (!landing?.ahead) return "";
		return `\n\nThe board is clear: ${landing.branch} has ${landing.tasks.length === 1 ? "1 task" : `${landing.tasks.length} tasks`} ready for ${landing.base} (${landing.files.length === 1 ? "1 file" : `${landing.files.length} files`}${work.way.testCommand ? ", checks passed" : ""}). Tell the user it's ready: they merge it into ${landing.base}, or push it for a pull request, from the project's Board.`;
	}

	/** One task per conversation among these, so each conversation hears once. */
	private firstOfEach(work: ProjectWork, ids: string[]): WorkTask[] {
		const seen = new Set<string>();
		return work.tasks.filter((t) => ids.includes(t.id) && !seen.has(t.conversationId ?? "") && seen.add(t.conversationId ?? ""));
	}

	// ── Landing: the work branch into the project's ──

	async landing(project: string): Promise<WorkLanding> {
		const work = this.get(project);
		if (!work.git) throw new EngineError("INVALID", "This project's work doesn't happen on a branch.");
		const { base, branch } = work.git;
		const git = (args: string[]) => this.host.git(work.cwd, args);
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
		const checkedOut = await this.host.branchOf(work.cwd).catch(() => undefined);
		return {
			base,
			branch,
			ahead,
			behind,
			files,
			tasks: work.tasks.filter((t) => t.state === "done" && t.branch && !t.landed).map((t) => ({ id: t.id, title: t.title })),
			open: work.tasks.filter((t) => OPEN.has(t.state)).length,
			...(checkedOut ? { checkedOut } : {}),
			...(remote ? { remote } : {}),
			...(github ? { compareUrl: `https://github.com/${github[1]}/${github[2]}/compare/${ref(base)}...${ref(branch)}?expand=1` } : {}),
		};
	}

	/**
	 * You land the work (the merge card): `merge` it into the project's branch, in the project's folder when that branch
	 * is checked out there, otherwise in a temporary worktree; or `push` the work branch for a pull request. A merge with
	 * conflicts changes nothing.
	 */
	async land(project: string, action: "merge" | "push"): Promise<{ commit?: string; compareUrl?: string; output?: string }> {
		const work = this.get(project);
		const landing = await this.landing(project);
		const { base, branch, integration } = work.git!;
		if (!landing.ahead) throw new EngineError("INVALID", `Nothing to merge: ${branch} has no work that ${base} doesn't have.`);
		if (action === "push") {
			if (!landing.remote) throw new EngineError("INVALID", "This project has no remote to push to.");
			const output = await this.host.git(integration, ["push", "-u", landing.remote, branch]);
			for (const t of this.firstOfEach(work, landing.tasks.map((x) => x.id))) await this.tell(work, `The user pushed ${branch} to ${landing.remote} for a pull request into ${base}.`, t);
			return { output, ...(landing.compareUrl ? { compareUrl: landing.compareUrl } : {}) };
		}
		const ids = landing.tasks.map((t) => t.id);
		const message = `Merge ${ids.length ? ids.map((id) => `${id} ${work.tasks.find((t) => t.id === id)?.title ?? ""}`.trim()).join(", ") : branch}`;
		const here = landing.checkedOut === base;
		const dir = here ? work.cwd : join(this.host.worktreesDir, work.id, "_land");
		if (!here) await this.host.git(work.cwd, ["worktree", "add", "-q", dir, base]);
		try {
			const named = (await this.host.git(dir, ["config", "user.email"]).catch(() => "")).trim();
			const who = named ? [] : PIOPIO;
			await this.host.git(dir, [...who, "merge", "--no-ff", "-q", "-m", message, branch]).catch(async (error: unknown) => {
				await this.host.git(dir, ["merge", "--abort"]).catch(() => undefined);
				const first = String((error as Error).message).split("\n").find((l) => /CONFLICT|overwritten|error:/i.test(l)) ?? "";
				throw new EngineError("CONFLICT", `${base} changed in the same places as this work, so nothing was merged. Ask Piopio to bring ${base} into ${branch} first. ${first}`.trim());
			});
		} finally {
			if (!here) await this.host.git(work.cwd, ["worktree", "remove", "--force", dir]).catch(() => undefined);
		}
		const commit = (await this.host.git(work.cwd, ["rev-parse", "--short", base])).trim();
		// The work branch moves up to the merge, so its next tasks start from what's in the project now.
		await this.host.git(integration, ["merge", "--ff-only", "-q", base]).catch(() => undefined);
		const now = iso();
		for (const t of work.tasks) {
			if (!ids.includes(t.id)) continue;
			t.landed = now;
			if (t.branch) await this.host.git(work.cwd, ["branch", "-D", t.branch]).catch(() => undefined);
		}
		this.save(work);
		for (const t of this.firstOfEach(work, ids)) await this.tell(work, `The user merged ${branch} into ${base} (${commit}): ${ids.length ? ids.join(", ") : "the work"}. New tasks start from there.`, t);
		return { commit };
	}

	private async block(work: ProjectWork, t: WorkTask, why: string): Promise<void> {
		t.state = "blocked";
		t.blocked = why;
		t.updatedAt = iso();
		this.save(work);
		await this.tell(work, `${t.id} “${t.title}” is blocked: ${why}`, t);
		await this.pump(work);
	}

	/** A board update, to the conversation that made the task (docs/spec/20 PT6). Your own cards have none. */
	private async tell(work: ProjectWork, text: string, t: WorkTask): Promise<void> {
		if (t.conversationId) await this.host.submit(t.conversationId, `[Board] ${text}`).catch((error: unknown) => this.host.log(`Work in ${work.cwd}: ${(error as Error).message}`));
	}

	/** After a restart: watch running tasks again, and settle those whose turn ended meanwhile. */
	async resume(): Promise<void> {
		for (const work of this.work) {
			for (const t of work.tasks) {
				if (t.state !== "doing" && t.state !== "review") continue;
				await this.watch(work, t).catch(() => undefined);
				const id = t.state === "doing" ? t.sessionId : t.reviewSessionId;
				const now = id ? await this.host.peek(id).catch(() => undefined) : undefined;
				if (id && now?.idle) await this.settled(work.project, id, now.answer).catch(() => undefined);
			}
			await this.pump(work).catch(() => undefined);
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

function readJson<T>(file: string): T | undefined {
	try {
		return existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as T) : undefined;
	} catch {
		return undefined;
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
