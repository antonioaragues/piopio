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
import { EngineError } from "../models.js";
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
	sessionId?: string;
	reviewSessionId?: string;
	branch?: string;
	cwd?: string;
	report?: string;
	review?: string;
	/** Rounds sent back by review or integration. */
	attempts: number;
	blocked?: string;
	createdAt: string;
	updatedAt: string;
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
	leadSessionId?: string;
	model?: string;
	memberMode: ApprovalMode;
	maxParallel: number;
	testCommand?: string;
	goal?: string;
	tasks: TeamTask[];
	nextTask: number;
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
const iso = () => new Date().toISOString();
const quote = (text: string) => text.split("\n").map((l) => `> ${l}`).join("\n");

export class TeamRunner {
	private teams: Team[] = [];
	private readonly watching = new Map<string, () => void>();
	/** Review verdicts given in a turn that hasn't settled yet, by review session. */
	private readonly verdicts = new Map<string, { pass: boolean; notes: string }>();

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

	async create(params: { name: string; template: string; cwd?: string; folder: string; model?: string; goal?: string; testCommand?: string; memberMode?: ApprovalMode; maxParallel?: number }): Promise<Team> {
		const t: TeamTemplate | undefined = template(params.template);
		if (!t) throw new EngineError("INVALID", `No team template “${params.template}”.`);
		const name = params.name.trim() || t.name;
		const slug = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "team";
		if (t.workplace === "project" && !params.cwd) throw new EngineError("INVALID", `A ${t.name.toLowerCase()} works in a project: choose its folder.`);
		mkdirSync(params.folder, { recursive: true });
		const notes = join(params.folder, "NOTES.md");
		if (!existsSync(notes)) writeFileSync(notes, `# ${name}: notes\n\n<!-- What the team keeps for each other: decisions, conventions, how to run things. -->\n`);
		const cwd = t.workplace === "project" ? params.cwd! : params.folder;
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
		// In a git project the team works on its own branch, in its own worktree; tasks branch from it (T2).
		if (t.workplace === "project" && (await this.host.isRepo(cwd))) {
			const base = (await this.host.branchOf(cwd)) ?? "HEAD";
			const branch = `team/${slug}-${id.slice(-4)}`;
			const integration = join(this.host.worktreesDir, id, "_team");
			await this.host.addWorktree(cwd, integration, branch, base);
			team.git = { base, branch, integration };
		}
		this.teams.push(team);
		this.save(team);
		const lead = team.roles.find((r) => r.kind === "lead")!;
		team.leadSessionId = await this.host.createSession({ cwd, title: `${name} · ${lead.name}`, ...(team.model ? { model: team.model } : {}), approvalMode: "read_only", team: { id, role: lead.id, kind: "lead" } });
		this.save(team);
		if (team.goal) await this.host.submit(team.leadSessionId, team.goal);
		return team;
	}

	/** What the lead is told about its team, each turn (system prompt). */
	leadBrief(team: Team): string {
		const lead = team.roles.find((r) => r.kind === "lead")!;
		const members = team.roles.filter((r) => r.kind !== "lead").map((r) => `- ${r.name} (role id "${r.id}", ${r.kind === "write" ? "does tasks; several can work at once" : r.kind === "review" ? "reviews every finished task; a failed review sends it back" : "merges approved work into the team branch and runs the checks"}): ${r.responsibility}`);
		const where = team.git ? `Each task gets its own branch from ${team.git.branch}; approved work is merged into ${team.git.branch}, which starts from ${team.git.base}.` : `Everyone works in the team folder, ${team.folder}.`;
		return `${lead.responsibility}\n\n${team.style}\n\nYour team (${team.name}):\n${members.join("\n")}\n\n${where} At most ${team.maxParallel} tasks run at once; the rest wait their turn. Team notes: ${join(team.folder, "NOTES.md")}.\n\nMessages that start with [Board] are updates from the board, not from the user.`;
	}

	// ── The board ──

	async createTask(teamId: string, task: { title: string; brief: string; done?: string; role?: string }, by: "lead" | "you" = "lead"): Promise<TeamTask> {
		const team = this.get(teamId);
		const writers = team.roles.filter((r) => r.kind === "write");
		const role = task.role ? team.roles.find((r) => r.id === task.role || r.name.toLowerCase() === task.role!.toLowerCase()) : writers[0];
		if (!role || role.kind !== "write") throw new EngineError("INVALID", `Tasks go to ${writers.map((r) => `“${r.id}”`).join(" or ")}.`);
		const t: TeamTask = { id: `T${team.nextTask++}`, title: task.title.trim(), brief: task.brief.trim(), ...(task.done?.trim() ? { done: task.done.trim() } : {}), role: role.id, state: "todo", by, attempts: 0, createdAt: iso(), updatedAt: iso() };
		team.tasks.push(t);
		this.save(team);
		if (by === "you" && team.leadSessionId) await this.host.submit(team.leadSessionId, `[Board] You were given a task on the board: ${t.id} “${t.title}”.`);
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
		if (team.leadSessionId) await this.host.submit(team.leadSessionId, `[Board] You changed ${t.id} “${t.title}”: now ${t.state}${change.role ? `, for ${change.role}` : ""}.`);
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

	board(teamId: string): string {
		const team = this.get(teamId);
		if (!team.tasks.length) return "The board is empty.";
		return team.tasks.map((t) => `${t.id} [${t.state}] ${t.title} (${t.role})${t.blocked ? ` — blocked: ${t.blocked}` : ""}${t.report && t.state === "done" ? `\n  Report: ${t.report.replace(/\s+/g, " ").slice(0, 300)}` : ""}`).join("\n");
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
		const where = team.git ? `You work on your own branch, ${t.branch}, in this folder; other members work on theirs at the same time. Don't switch branches.` : `You work in the team folder, ${team.folder}, alongside other members: only change the files your task is about.`;
		return [
			`You're the ${role.name} on ${team.name}. ${role.responsibility}`,
			`Your task, ${t.id}: ${t.title}\n\n${t.brief}`,
			t.done ?? role.done ? `Done means: ${t.done ?? role.done}` : "",
			`${where} Team notes: ${join(team.folder, "NOTES.md")}. Read them first, and add a line for what your teammates will need.`,
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
		const diff = team.git ? `The task's changes are on ${t.branch}: see them with \`git diff ${team.git.branch}...HEAD\`.` : `The task's files are in ${team.folder}.`;
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
		await this.tellLead(team, `${t.id} “${t.title}” went back to its ${team.roles.find((r) => r.id === t.role)?.name ?? "writer"} (${by}, round ${t.attempts}).`);
		await this.host.submit(t.sessionId!, message);
	}

	/** Approved (or nothing to review): integrated when the team has CI and git, otherwise done. */
	private async approved(team: Team, t: TeamTask): Promise<void> {
		const ci = team.roles.find((r) => r.kind === "integrate");
		if (ci && team.git && t.branch) return this.integrate(team, t);
		return this.complete(team, t, "");
	}

	/** CI: merge the task's branch into the team's, then the checks. A conflict or a failing check goes back. */
	private async integrate(team: Team, t: TeamTask): Promise<void> {
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
		await this.tellLead(team, `${t.id} “${t.title}” is done.${extra}\n\nReport:\n${quote(t.report || "(none)")}`);
		await this.pump(team);
	}

	private async block(team: Team, t: TeamTask, why: string): Promise<void> {
		t.state = "blocked";
		t.blocked = why;
		t.updatedAt = iso();
		this.save(team);
		await this.tellLead(team, `${t.id} “${t.title}” is blocked: ${why}`);
		await this.pump(team);
	}

	private async tellLead(team: Team, text: string): Promise<void> {
		if (team.leadSessionId) await this.host.submit(team.leadSessionId, `[Board] ${text}`).catch((error: unknown) => this.host.log(`Team ${team.name}: ${(error as Error).message}`));
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
	}

	stop(): void {
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
