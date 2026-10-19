/**
 * Session catalog + open runtimes. Phase 0 keeps the catalog in a JSON index;
 * it moves to catalog.db (SQLite + FTS) with the Phase 1 sidebar.
 */
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ContainerRef, ModelRef, SessionSummary } from "@piopio/protocol";
import { EngineError, type ModelHub } from "./models.js";
import type { EnginePaths } from "./paths.js";
import { BuildRuntime } from "./runtimes/build.js";
import type { Runtime } from "./runtimes/runtime.js";
import { DatabaseSync } from "node:sqlite";
import { ThreadRuntime, type BranchState } from "./runtimes/thread.js";
import type { WebOptions } from "./tools/web.js";
import { exportTranscript, type ExportFormat } from "./export.js";
import { SearchIndex } from "./search.js";
import type { SessionEvent } from "@piopio/protocol";

type CatalogEntry = SessionSummary & { thinking?: string; file?: string; sessionFile?: string; branches?: BranchState; web?: boolean };

export const newId = (prefix: string) => `${prefix}_${randomUUID().replaceAll("-", "").slice(0, 20)}`;

export type CatalogListener = (change: { upserted: SessionSummary[]; removed: ContainerRef[] }) => void;

export class Sessions {
	private entries = new Map<string, CatalogEntry>();
	private open = new Map<string, Promise<Runtime>>();
	private listeners = new Set<CatalogListener>();
	readonly search: SearchIndex;

	constructor(
		private readonly paths: EnginePaths,
		private readonly hub: ModelHub,
		private readonly piOverrides: { piSessionDir?: string; piAgentDir?: string } = {},
		private readonly webOptions: WebOptions = {},
	) {
		this.search = new SearchIndex(join(paths.home, "search.db"));
		if (existsSync(paths.catalogIndex)) {
			for (const e of JSON.parse(readFileSync(paths.catalogIndex, "utf8")) as CatalogEntry[]) this.entries.set(e.ref.id, e);
		}
	}

	get openCount(): number {
		return this.open.size;
	}

	list(kind?: string): SessionSummary[] {
		return [...this.entries.values()]
			.filter((e) => !kind || e.ref.kind === kind)
			.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
			.map(summary);
	}

	onChange(listener: CatalogListener): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	private changed(entry: CatalogEntry): void {
		for (const l of this.listeners) l({ upserted: [summary(entry)], removed: [] });
	}

	async configure(ref: ContainerRef, change: { model?: ModelRef; thinking?: string; web?: boolean }): Promise<void> {
		const entry = this.entry(ref);
		if (this.open.has(ref.id)) await (await this.runtime(ref)).configure(change);
		if (change.web !== undefined) entry.web = change.web;
		if (change.model) entry.model = change.model;
		if (change.thinking === "default") delete entry.thinking;
		else if (change.thinking) entry.thinking = change.thinking;
		this.save();
		this.changed(entry);
	}

	rename(ref: ContainerRef, title: string): void {
		const entry = this.entry(ref);
		entry.title = title.trim().slice(0, 120) || entry.title;
		this.search.setTitle(ref.id, entry.title, entry.updatedAt);
		this.save();
		this.changed(entry);
	}

	/** Full-text search across sessions, with the catalog's titles and refs. */
	find(query: string, limit = 30) {
		return this.search.search(query, limit).flatMap((hit) => {
			const entry = this.entries.get(hit.sessionId);
			return entry ? [{ ref: entry.ref, title: entry.title, ...(hit.itemId ? { itemId: hit.itemId } : {}), kind: hit.kind, snippet: hit.snippet, at: hit.at }] : [];
		});
	}

	/** Indexes threads that were never indexed (or with an older index version), one at a time. */
	async backfillSearch(): Promise<number> {
		let count = 0;
		for (const entry of [...this.entries.values()]) {
			if (entry.ref.kind !== "thread" || this.search.isIndexed(entry.ref.id) || !this.entries.has(entry.ref.id)) continue;
			const wasOpen = this.open.has(entry.ref.id);
			try {
				const runtime = await this.runtime(entry.ref); // indexes on open
				if (!wasOpen && this.open.get(entry.ref.id)) {
					this.open.delete(entry.ref.id);
					await runtime.close();
				}
				count++;
			} catch {
				// unreadable session: skip; it is retried on the next start
			}
		}
		return count;
	}

	/** Keeps the search index in step with what the session shows. */
	private index(entry: CatalogEntry, events: readonly SessionEvent[]): void {
		const id = entry.ref.id;
		for (const event of events) {
			switch (event.type) {
				case "item.added":
				case "item.updated":
					this.search.upsertItem(id, event.item);
					break;
				case "item.replaced":
					this.search.upsertItem(id, event.item, event.oldId);
					break;
				case "item.removed":
					this.search.removeItem(id, event.itemId);
					break;
				case "resnapshot":
					this.search.replaceSession(id, entry.title, entry.updatedAt, event.snapshot.items);
					break;
			}
		}
	}

	/**
	 * Copies a thread into a new one that continues from `itemId` (inclusive) of the active branch.
	 * The SQLite file is copied with VACUUM INTO, so the source can stay open.
	 */
	async fork(ref: ContainerRef, itemId: string): Promise<ContainerRef> {
		const source = this.entry(ref);
		if (ref.kind !== "thread" || !source.file) throw new EngineError("INVALID", "Only threads can be branched into a new session for now.");
		const runtime = await this.runtime(ref);
		if (runtime.snapshot().state.status === "running") throw new EngineError("BUSY", "Wait for the answer to finish before branching into a new thread.");
		const copy: CatalogEntry = {
			...structuredClone(source),
			ref: { kind: "thread", id: newId("thr") },
			title: `${source.title} (branch)`,
			createdAt: new Date().toISOString(),
			updatedAt: new Date().toISOString(),
			branches: { ...(source.branches?.active ? { active: source.branches.active } : {}), activity: {} },
		};
		copy.file = join(this.paths.threadsDir, `${copy.ref.id}.sqlite`);
		const db = new DatabaseSync(source.file, { readOnly: true });
		try {
			db.exec(`VACUUM INTO '${copy.file.replaceAll("'", "''")}'`);
		} finally {
			db.close();
		}
		this.entries.set(copy.ref.id, copy);
		this.save();
		try {
			const forked = (await this.runtime(copy.ref)) as ThreadRuntime;
			await forked.startAt(itemId);
		} catch (error) {
			await this.delete(copy.ref).catch(() => undefined);
			throw error;
		}
		this.changed(copy);
		return copy.ref;
	}

	async export(ref: ContainerRef, format: ExportFormat) {
		const entry = this.entry(ref);
		return exportTranscript(entry.title, (await this.runtime(ref)).snapshot().items, format);
	}

	/** Threads lose their history file; build sessions only leave the catalog (pi owns the JSONL). */
	async delete(ref: ContainerRef): Promise<void> {
		const entry = this.entry(ref);
		const runtime = this.open.get(ref.id);
		this.open.delete(ref.id);
		if (runtime) await (await runtime.catch(() => undefined))?.close();
		if (entry.file) for (const suffix of ["", "-wal", "-shm"]) rmSync(entry.file + suffix, { force: true });
		this.search.deleteSession(ref.id);
		this.entries.delete(ref.id);
		this.save();
		for (const l of this.listeners) l({ upserted: [], removed: [entry.ref] });
	}

	private entry(ref: ContainerRef): CatalogEntry {
		const entry = this.entries.get(ref.id);
		if (!entry || entry.ref.kind !== ref.kind) throw new EngineError("NOT_FOUND", `No ${ref.kind} ${ref.id}`);
		return entry;
	}

	async create(params: { kind: "thread" | "build"; cwd?: string; model?: ModelRef; thinking?: string; title?: string }): Promise<ContainerRef> {
		if (params.kind === "build" && !params.cwd) throw new EngineError("INVALID", "Build sessions need a cwd.");
		if (params.kind === "build" && !existsSync(params.cwd!)) throw new EngineError("INVALID", `No such folder: ${params.cwd}`);
		const ref: ContainerRef = { kind: params.kind, id: newId(params.kind === "thread" ? "thr" : "ses") };
		const now = new Date().toISOString();
		const entry: CatalogEntry = {
			ref,
			title: params.title ?? (params.kind === "thread" ? "New thread" : "New session"),
			createdAt: now,
			updatedAt: now,
			model: params.model ?? this.hub.defaultModel,
			...(params.cwd ? { cwd: params.cwd } : {}),
			...(params.thinking ? { thinking: params.thinking } : {}),
			...(params.kind === "thread" ? { file: join(this.paths.threadsDir, `${ref.id}.sqlite`) } : {}),
		};
		this.entries.set(ref.id, entry);
		this.save();
		this.changed(entry);
		return ref;
	}

	async runtime(ref: ContainerRef): Promise<Runtime> {
		const entry = this.entry(ref);
		let pending = this.open.get(ref.id);
		if (!pending) {
			pending = this.openRuntime(entry);
			this.open.set(ref.id, pending);
			pending.catch(() => this.open.delete(ref.id));
		}
		return pending;
	}

	/** Called after a submit: bumps recency and auto-titles from the first input. */
	touch(ref: ContainerRef, firstInput?: string): void {
		const entry = this.entries.get(ref.id);
		if (!entry) return;
		entry.updatedAt = new Date().toISOString();
		if (firstInput && (entry.title === "New thread" || entry.title === "New session")) {
			entry.title = titleFrom(firstInput) || entry.title;
			this.search.setTitle(ref.id, entry.title, entry.updatedAt);
		}
		this.save();
		this.changed(entry);
	}

	async closeAll(): Promise<void> {
		const runtimes = await Promise.allSettled(this.open.values());
		this.open.clear();
		await Promise.allSettled(runtimes.map((r) => (r.status === "fulfilled" ? r.value.close() : undefined)));
		this.search.close();
	}

	private async openRuntime(entry: CatalogEntry): Promise<Runtime> {
		const runtime = await this.createRuntime(entry);
		if (!this.search.isIndexed(entry.ref.id)) this.search.replaceSession(entry.ref.id, entry.title, entry.updatedAt, runtime.snapshot().items);
		runtime.onEvents((events) => this.index(entry, events));
		return runtime;
	}

	private async createRuntime(entry: CatalogEntry): Promise<Runtime> {
		const model = entry.model ?? this.hub.defaultModel;
		if (entry.ref.kind === "thread") {
			return ThreadRuntime.open({
				ref: entry.ref,
				file: entry.file!,
				hub: this.hub,
				model,
				...(entry.thinking ? { thinking: entry.thinking } : {}),
				...(entry.branches ? { branches: entry.branches } : {}),
				onBranchState: (state) => {
					entry.branches = state;
					this.save();
				},
				web: entry.web ?? true,
				webOptions: this.webOptions,
			});
		}
		const runtime = await BuildRuntime.open({
			ref: entry.ref,
			hub: this.hub,
			cwd: entry.cwd!,
			model,
			...(entry.thinking ? { thinking: entry.thinking } : {}),
			...(entry.sessionFile ? { sessionFile: entry.sessionFile } : {}),
			...this.piOverrides,
		});
		if (runtime.sessionFile && runtime.sessionFile !== entry.sessionFile) {
			entry.sessionFile = runtime.sessionFile;
			this.save();
		}
		return runtime;
	}

	private save(): void {
		const tmp = `${this.paths.catalogIndex}.tmp`;
		writeFileSync(tmp, JSON.stringify([...this.entries.values()], null, "\t"));
		renameSync(tmp, this.paths.catalogIndex);
	}
}

function summary({ file: _f, sessionFile: _s, thinking: _t, ...rest }: CatalogEntry): SessionSummary {
	return rest;
}

/** A short plain-text title from a first message: markdown markup removed, first line, ≤ 60 chars. */
export function titleFrom(text: string): string {
	const plain = text
		.replace(/```[\s\S]*?(```|$)/g, " ")
		.replace(/^\s*\|.*$/gm, " ")
		.replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
		.replace(/[*_`~#>|]/g, "")
		.replace(/\s+/g, " ")
		.trim();
	if (plain.length <= 60) return plain;
	const cut = plain.slice(0, 60);
	const space = cut.lastIndexOf(" ");
	return `${(space > 30 ? cut.slice(0, space) : cut).trim()}…`;
}
