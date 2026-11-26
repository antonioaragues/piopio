/**
 * Projects (docs/spec/18 §3, CF4): folders on the Mac. Ones the user opened (05-build BP1), and ones New project made
 * in ~/Piopio, with an AGENTS.md (what every conversation there is told) and a NOTES.md (what they keep for each
 * other). Kept in projects.json.
 */
import { detectCheck } from "@piopio/pi-extensions";
import { existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { hasTrustRequiringProjectResources, ProjectTrustStore } from "@earendil-works/pi-coding-agent";
import { claudeCodeTrusted, hasClaudeCodeSetup, piTrust } from "./project-trust.js";
import type { ApprovalMode, ApprovalRule, ProjectInfo } from "@piopio/protocol";
import { EngineError } from "./models.js";
import { NOTES_FILE } from "./runtimes/build.js";
import { newId } from "./sessions.js";
import { readJsonFile, writeFileAtomic } from "./atomic.js";

type Lens = "build" | "chat";
/**
 * `network`: "filtered", its commands reach only the hosts allowed, until it's trusted; "off", only this Mac, until you
 * turn it on (docs/spec/39); absent, open.
 */
type StoredProject = { id: string; path: string; name: string; addedAt: string; approvalMode?: ApprovalMode; rules?: ApprovalRule[]; folders?: LinkedFolder[]; prEvents?: PrEvents; check?: string; network?: "filtered" | "off" };
/** A project's commands' network (docs/spec/39). */
export type NetworkMode = "open" | "filtered" | "off";
/** What a conversation hears about its pull request (docs/spec/17 §5): nothing, a notification, or a follow-up it works on. */
export type PrEvents = "off" | "tell" | "act";

/** A folder linked to a project (docs/spec/18 §18): read only, or edited under the project's permissions. */
export type LinkedFolder = { path: string; edit: boolean };


const AGENTS_TEMPLATE = (name: string, instructions?: string) =>
	`# ${name}\n\n${instructions?.trim() || "<!-- What every conversation in this project should know: what it's about, what matters, how to answer. -->"}\n`;
const NOTES_TEMPLATE = "# Notes\n\n<!-- Decisions, numbers and dates this project's conversations keep for each other. -->\n";

/** Files that make a folder a code project (04-chat P1); anything else starts in Read only (18 §4). */
const CODE_MARKERS = [".git", "package.json", "Package.swift", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "Gemfile", "pom.xml", "build.gradle", "Makefile", "CMakeLists.txt", "composer.json", "deno.json", "mix.exs"];

export function detectLens(path: string): Lens {
	return CODE_MARKERS.some((m) => existsSync(join(path, m))) ? "build" : "chat";
}

export class Projects {
	private entries: StoredProject[] = [];
	private listeners = new Set<(projects: ProjectInfo[]) => void>();

	/** pi's project trust decisions (~/.pi/agent/trust.json), shared with the pi CLI. */
	private readonly trust: ProjectTrustStore;

	constructor(
		private readonly file: string,
		private readonly agentDir: string,
		/** Where New project makes its folders (~/Piopio). */
		private readonly root?: string,
	) {
		this.entries = readJsonFile<StoredProject[]>(file, () => this.entries);
		this.trust = new ProjectTrustStore(agentDir);
	}

	/** A new folder in ~/Piopio named after the project ("Kitchen renovation", then "Kitchen renovation 2"). */
	private newFolder(name: string): string {
		if (!this.root) throw new EngineError("INVALID", "New projects need a folder to go in.");
		mkdirSync(this.root, { recursive: true });
		const base = name.replace(/[/:\\]/g, "-").replace(/^[.\s]+/, "").trim().slice(0, 80) || "Project";
		let target = join(this.root, base);
		for (let n = 2; existsSync(target); n++) target = join(this.root, `${base} ${n}`);
		return target;
	}

	/** AGENTS.md and NOTES.md, unless the folder has them. */
	private seed(folder: string, name: string, instructions?: string): void {
		if (!existsSync(join(folder, "AGENTS.md"))) writeFileSync(join(folder, "AGENTS.md"), AGENTS_TEMPLATE(name, instructions));
		if (!existsSync(join(folder, NOTES_FILE))) writeFileSync(join(folder, NOTES_FILE), NOTES_TEMPLATE);
	}

	list(): ProjectInfo[] {
		return this.entries.map((p) => this.describe(p));
	}

	private describe(p: StoredProject): ProjectInfo {
		const exists = existsSync(p.path);
		const decision = exists ? this.trust.get(p.path) : null;
		// Its own pi setup, or Claude Code hooks and MCP servers that Claude Code itself wasn't told to trust.
		const needsTrust = exists && (hasTrustRequiringProjectResources(p.path) || (hasClaudeCodeSetup(p.path) && !claudeCodeTrusted(p.path)));
		return { ...describe(p), trust: decision === true ? "trusted" : decision === false ? "untrusted" : "undecided", needsTrust, network: p.network ?? "open" };
	}

	/**
	 * The network of the commands of the project at `path` (or containing it), docs/spec/39. Read for each command, so
	 * trusting the project or changing it in Settings takes effect at once.
	 */
	networkFor(path: string): NetworkMode {
		const entry = this.entries.find((p) => path === p.path || path.startsWith(`${p.path}/`));
		return entry?.network ?? "open";
	}

	/** The sites a project's commands may reach, besides the built-in ones: its "host" rules. */
	hostRules(path: string): string[] {
		const entry = this.entries.find((p) => path === p.path || path.startsWith(`${p.path}/`));
		return (entry?.rules ?? []).filter((r) => r.kind === "host").map((r) => r.pattern);
	}

	/** Trusted already, in pi (the folder or one above it) or in Claude Code. */
	private trustedElsewhere(path: string): boolean {
		return piTrust(path, this.agentDir) === true || claudeCodeTrusted(path);
	}

	get(id: string): ProjectInfo {
		const entry = this.entries.find((p) => p.id === id);
		if (!entry) throw new EngineError("NOT_FOUND", `No project ${id}`);
		return this.describe(entry);
	}

	/** The project folder that contains `cwd`, if any. */
	containing(cwd: string): ProjectInfo | undefined {
		const entry = this.entries.find((p) => cwd === p.path || cwd.startsWith(`${p.path}/`));
		return entry && this.describe(entry);
	}

	/**
	 * Adds a folder. Adding the same folder again returns the existing project. A folder without code starts in Read
	 * only, as does one added to chat about (`lens: "chat"`, the old Chat lens).
	 */
	add(path: string, lens?: Lens): ProjectInfo {
		if (!isAbsolute(path)) throw new EngineError("INVALID", "Project paths must be absolute.");
		let real: string;
		try {
			real = realpathSync(resolve(path));
			if (!statSync(real).isDirectory()) throw new Error("not a folder");
		} catch {
			throw new EngineError("INVALID", `Not a folder: ${path}`);
		}
		const existing = this.entries.find((p) => p.path === real);
		if (existing) return this.describe(existing);
		const readOnly = lens === "chat" || detectLens(real) === "chat";
		// A folder from elsewhere (one you open, a clone) has a filtered network until you trust it (docs/spec/39).
		const filtered = !this.trustedElsewhere(real);
		const entry: StoredProject = { id: newId("prj"), path: real, name: basename(real), addedAt: new Date().toISOString(), ...(readOnly ? { approvalMode: "read_only" as const } : {}), ...(filtered ? { network: "filtered" as const } : {}) };
		this.entries.push(entry);
		this.save();
		return this.describe(entry);
	}

	/**
	 * New project (CF4): a folder in ~/Piopio, with AGENTS.md (the instructions) and NOTES.md. It starts in Auto-edit,
	 * so its conversations can keep the notes; a folder of documents you open starts in Read only (`add`).
	 */
	create(name: string, instructions?: string): ProjectInfo {
		const trimmed = name.trim();
		if (!trimmed) throw new EngineError("INVALID", "The project needs a name.");
		const folder = this.newFolder(trimmed);
		mkdirSync(folder, { recursive: true });
		this.seed(folder, trimmed, instructions);
		const entry: StoredProject = { id: newId("prj"), path: realpathSync(folder), name: basename(folder), addedAt: new Date().toISOString(), approvalMode: "auto_edit" };
		this.entries.push(entry);
		this.save();
		return this.describe(entry);
	}

	/** Removes a project from Piopio. Its folder stays on disk. */
	remove(id: string): ProjectInfo {
		const project = this.get(id);
		this.entries = this.entries.filter((p) => p.id !== id);
		this.save();
		return project;
	}

	/** Default approval mode, or rule removal (Settings / project menu). */
	configure(id: string, change: { approvalMode?: ApprovalMode; removeRule?: string; trust?: boolean | null; linkFolder?: LinkedFolder; unlinkFolder?: string; prEvents?: PrEvents; check?: string | null; network?: NetworkMode }): ProjectInfo {
		const entry = this.entries.find((p) => p.id === id);
		if (!entry) throw new EngineError("NOT_FOUND", `No project ${id}`);
		if (change.linkFolder) this.link(entry, change.linkFolder);
		if (change.unlinkFolder) {
			entry.folders = (entry.folders ?? []).filter((f) => f.path !== change.unlinkFolder);
			if (!entry.folders.length) delete entry.folders;
		}
		// Full access has no sandbox and asks nothing, so it would go around a filtered or turned-off network (docs/spec/39 §2).
		const networkAfter: NetworkMode = change.network ?? (change.trust === true && entry.network === "filtered" ? "open" : (entry.network ?? "open"));
		if (change.approvalMode === "full_auto" && networkAfter === "filtered") throw new EngineError("INVALID", "Full access needs a trusted project. Trust it first: its commands run in the sandbox until then.");
		if (change.approvalMode === "full_auto" && networkAfter === "off") throw new EngineError("INVALID", "Full access has no sandbox, so it can't keep the network off. Turn this project's network on first.");
		if (change.approvalMode) entry.approvalMode = change.approvalMode;
		// Filtering a project, or turning its network off, when it started in Full access: Auto-edit, so its commands are sandboxed.
		if (networkAfter !== "open" && entry.approvalMode === "full_auto") entry.approvalMode = "auto_edit";
		if (change.prEvents) entry.prEvents = change.prEvents;
		if (change.check === null) delete entry.check;
		else if (change.check !== undefined) entry.check = change.check.trim();
		if (change.removeRule) entry.rules = (entry.rules ?? []).filter((r) => r.id !== change.removeRule);
		// Saved where the pi CLI reads it too. Sessions opened afterwards load (or skip) the project's resources.
		if (change.trust !== undefined) this.trust.set(entry.path, change.trust);
		// Trusting a project opens a filtered network; a network you turned off stays off. The picker in Settings sets
		// it either way (docs/spec/39).
		if (networkAfter === "open") delete entry.network;
		else entry.network = networkAfter;
		this.save();
		return this.describe(entry);
	}

	/** Tells clients again (the branch changed). */
	touch(): void {
		const projects = this.list();
		for (const l of this.listeners) l(projects);
	}

	/** The project that contains `cwd`. */
	projectFor(cwd: string): { id: string; path: string } | undefined {
		const entry = this.entryFor(cwd);
		return entry && { id: entry.id, path: entry.path };
	}

	/** Approval mode for new sessions in `cwd` (global default: auto-edit, BQ1); Full access only in a project whose network is open (docs/spec/39 §2). */
	modeFor(cwd: string): ApprovalMode {
		const entry = this.entryFor(cwd);
		const mode = entry?.approvalMode ?? "auto_edit";
		return mode === "full_auto" && entry?.network !== undefined ? "auto_edit" : mode;
	}

	/** What conversations in `cwd`'s project hear about their pull requests (default: tell). */
	prEventsFor(cwd: string): PrEvents {
		return this.entryFor(cwd)?.prEvents ?? "tell";
	}

	/**
	 * The check to run after the agent's edits in `cwd`'s project (05-build "Diagnostics"): the one set in Project
	 * settings, else one detected from its files, else none. A detected check runs the repository's own scripts
	 * (`npm run typecheck` is whatever its package.json says) without asking, so it's only detected once the project
	 * is trusted: not in one whose network is still filtered (docs/spec/39: from elsewhere, not trusted yet), nor in a
	 * folder that isn't a project unless pi or Claude Code trust it (re-audit 2026-11-25 V2).
	 */
	checkFor(cwd: string): string | undefined {
		const entry = this.entryFor(cwd);
		if (!entry) return this.trustedElsewhere(cwd) ? detectCheck(cwd) : undefined;
		if (entry.check !== undefined) return entry.check || undefined;
		if (entry.network === "filtered") return undefined;
		return detectCheck(entry.path);
	}

	rulesFor(cwd: string): ApprovalRule[] {
		return this.entryFor(cwd)?.rules ?? [];
	}

	/** The folders linked to the project that contains `cwd` (18 §18), the ones still on disk. */
	foldersFor(cwd: string): LinkedFolder[] {
		return (this.entryFor(cwd)?.folders ?? []).filter((f) => existsSync(f.path));
	}

	/** Adds a folder, or changes its access. Not the project's own folder, one inside it, or one that holds it. */
	private link(entry: StoredProject, folder: LinkedFolder): void {
		if (!isAbsolute(folder.path)) throw new EngineError("INVALID", "Folder paths must be absolute.");
		let real: string;
		try {
			real = realpathSync(resolve(folder.path));
			if (!statSync(real).isDirectory()) throw new Error("not a folder");
		} catch {
			throw new EngineError("INVALID", `Not a folder: ${folder.path}`);
		}
		const within = (a: string, b: string) => a === b || a.startsWith(`${b}/`);
		if (within(real, entry.path)) throw new EngineError("INVALID", "That folder is already part of the project.");
		if (within(entry.path, real)) throw new EngineError("INVALID", "That folder contains the project. Open it as a project instead.");
		entry.folders ??= [];
		const existing = entry.folders.find((f) => f.path === real);
		if (existing) existing.edit = folder.edit;
		else entry.folders.push({ path: real, edit: folder.edit });
	}

	/** "Always allow": adds a rule to the project that contains `cwd` (no duplicates). */
	addRule(cwd: string, rule: { kind: ApprovalRule["kind"]; pattern: string }): void {
		const entry = this.entryFor(cwd);
		if (!entry) return;
		entry.rules ??= [];
		if (entry.rules.some((r) => r.kind === rule.kind && r.pattern === rule.pattern)) return;
		entry.rules.push({ id: newId("rule"), ...rule, createdAt: new Date().toISOString() });
		this.save();
	}

	private entryFor(cwd: string): StoredProject | undefined {
		const match = (path: string) => this.entries.find((p) => path === p.path || path.startsWith(`${p.path}/`));
		// Projects are stored by their real path; a folder reached through a symlink (/var → /private/var, a linked
		// ~/Projects) is still in its project.
		return match(cwd) ?? match(Projects.real(cwd));
	}

	private static readonly reals = new Map<string, string>();
	private static real(path: string): string {
		let real = Projects.reals.get(path);
		if (real === undefined) {
			// The deepest folder that exists, resolved, and the rest as it is (a subfolder not made yet).
			let head = path;
			let rest = "";
			for (;;) {
				try {
					real = realpathSync(head) + rest;
					break;
				} catch {
					const up = dirname(head);
					if (up === head) return path;
					rest = `/${basename(head)}${rest}`;
					head = up;
				}
			}
			if (!rest) Projects.reals.set(path, real);
		}
		return real;
	}

	onChange(listener: (projects: ProjectInfo[]) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	private save(): void {
		writeFileAtomic(this.file, JSON.stringify(this.entries, null, "\t"));
		const projects = this.list();
		for (const l of this.listeners) l(projects);
	}
}

function describe(stored: StoredProject): Omit<ProjectInfo, "trust" | "needsTrust"> {
	// `lenses` stays in the protocol for older apps: every project now does both (the permissions decide).
	const { folders, ...rest } = stored;
	const p = {
		...rest,
		approvalMode: stored.approvalMode ?? "auto_edit",
		prEvents: stored.prEvents ?? "tell",
		rules: stored.rules ?? [],
		check: stored.check === "" ? { source: "off" as const } : stored.check ? { command: stored.check, source: "set" as const } : (() => {
			const detected = existsSync(stored.path) ? detectCheck(stored.path) : undefined;
			return { ...(detected ? { command: detected } : {}), source: "auto" as const };
		})(),
		lenses: ["build", "chat"] as Lens[],
		...(folders?.length ? { folders: folders.map((f) => (existsSync(f.path) ? f : { ...f, missing: true })) } : {}),
	};
	if (!existsSync(p.path)) return { ...p, piConfig: false, missing: true };
	const branch = gitBranch(p.path);
	const contextFile = ["AGENTS.md", "CLAUDE.md"].find((name) => existsSync(join(p.path, name)));
	return {
		...p,
		...(branch ? { branch } : {}),
		...(contextFile ? { contextFile } : {}),
		piConfig: existsSync(join(p.path, ".pi")),
	};
}

/** The checked-out branch, read from .git/HEAD (worktrees have a `.git` file pointing at their git dir). */
export function gitBranch(path: string): string | undefined {
	try {
		const dotGit = join(path, ".git");
		let gitDir = dotGit;
		if (statSync(dotGit).isFile()) {
			const pointer = /^gitdir:\s*(.+)$/m.exec(readFileSync(dotGit, "utf8"))?.[1]?.trim();
			if (!pointer) return undefined;
			gitDir = resolve(path, pointer);
		}
		const head = readFileSync(join(gitDir, "HEAD"), "utf8").trim();
		const ref = /^ref:\s*refs\/heads\/(.+)$/.exec(head)?.[1];
		return ref ?? head.slice(0, 7);
	} catch {
		return undefined;
	}
}
