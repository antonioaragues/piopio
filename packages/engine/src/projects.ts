/** Build projects: folders the user added (docs/spec/05-build BP1). Kept in projects.json. */
import { existsSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, isAbsolute, join, resolve } from "node:path";
import { hasTrustRequiringProjectResources, ProjectTrustStore } from "@earendil-works/pi-coding-agent";
import type { ApprovalMode, ApprovalRule, ProjectInfo } from "@piopio/protocol";
import { EngineError } from "./models.js";
import { newId } from "./sessions.js";

type Lens = "build" | "chat";
type StoredProject = { id: string; path: string; name: string; addedAt: string; approvalMode?: ApprovalMode; rules?: ApprovalRule[]; lenses?: Lens[] };

/** Files that make a folder a code project (04-chat P1); anything else opens in Chat. */
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
		agentDir: string,
	) {
		if (existsSync(file)) this.entries = JSON.parse(readFileSync(file, "utf8")) as StoredProject[];
		this.trust = new ProjectTrustStore(agentDir);
	}

	list(): ProjectInfo[] {
		return this.entries.map((p) => this.describe(p));
	}

	private describe(p: StoredProject): ProjectInfo {
		const exists = existsSync(p.path);
		const decision = exists ? this.trust.get(p.path) : null;
		return { ...describe(p), trust: decision === true ? "trusted" : decision === false ? "untrusted" : "undecided", needsTrust: exists && hasTrustRequiringProjectResources(p.path) };
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

	/** Adds a folder. Adding the same folder again returns the existing project. */
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
		if (existing) {
			// Adding it from the other mode shows it there too.
			const lenses = existing.lenses ?? [detectLens(existing.path)];
			if (lens && !lenses.includes(lens)) {
				existing.lenses = [...lenses, lens];
				this.save();
			}
			return this.describe(existing);
		}
		const detected = detectLens(real);
		const entry: StoredProject = { id: newId("prj"), path: real, name: basename(real), addedAt: new Date().toISOString(), lenses: lens && lens !== detected ? [detected, lens] : [detected] };
		this.entries.push(entry);
		this.save();
		return this.describe(entry);
	}

	remove(id: string): ProjectInfo {
		const project = this.get(id);
		this.entries = this.entries.filter((p) => p.id !== id);
		this.save();
		return project;
	}

	/** Default approval mode, or rule removal (Settings / project menu). */
	configure(id: string, change: { approvalMode?: ApprovalMode; removeRule?: string; trust?: boolean | null; lenses?: Lens[] }): ProjectInfo {
		const entry = this.entries.find((p) => p.id === id);
		if (!entry) throw new EngineError("NOT_FOUND", `No project ${id}`);
		if (change.approvalMode) entry.approvalMode = change.approvalMode;
		if (change.removeRule) entry.rules = (entry.rules ?? []).filter((r) => r.id !== change.removeRule);
		// Saved where the pi CLI reads it too. Sessions opened afterwards load (or skip) the project's resources.
		if (change.trust !== undefined) this.trust.set(entry.path, change.trust);
		if (change.lenses) {
			if (change.lenses.length === 0) throw new EngineError("INVALID", "A project shows in Build, Chat or both.");
			entry.lenses = [...new Set(change.lenses)];
		}
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

	/** Approval mode for new sessions in `cwd` (global default: auto-edit, BQ1). */
	modeFor(cwd: string): ApprovalMode {
		return this.entryFor(cwd)?.approvalMode ?? "auto_edit";
	}

	rulesFor(cwd: string): ApprovalRule[] {
		return this.entryFor(cwd)?.rules ?? [];
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
		return this.entries.find((p) => cwd === p.path || cwd.startsWith(`${p.path}/`));
	}

	onChange(listener: (projects: ProjectInfo[]) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	private save(): void {
		const tmp = `${this.file}.tmp`;
		writeFileSync(tmp, JSON.stringify(this.entries, null, "\t"));
		renameSync(tmp, this.file);
		const projects = this.list();
		for (const l of this.listeners) l(projects);
	}
}

function describe(stored: StoredProject): Omit<ProjectInfo, "trust" | "needsTrust"> {
	const p = { ...stored, approvalMode: stored.approvalMode ?? "auto_edit", rules: stored.rules ?? [], lenses: stored.lenses ?? (existsSync(stored.path) ? [detectLens(stored.path)] : (["build"] as Lens[])) };
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
