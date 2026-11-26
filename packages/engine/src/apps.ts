/**
 * Apps (docs/spec/35 §3, §14): a visual that reads its data instead of carrying it. An app is one `.html` file whose
 * manifest (`<script type="application/json" id="piopio-app">`) lists its sources; the engine reads them and the app
 * hands the result to the page through `piopio.onData`, so the page never reaches out.
 *
 * Sources are files (CSV, TSV, JSON, Markdown, text; L2), your calendar (L4, §16) and Piopio's own numbers (L4: spending,
 * activity, budgets, automation runs, agents; read from the engine with no model, §3.2). A file source can list the columns
 * it needs; a file that's gone, empty, too big, unparseable or missing a column fails, and the app keeps that source's
 * last good data, dated. A calendar source names its accounts: each is read on its own, checked against Settings ›
 * Connectors every time, and keeps its last good events when it fails; an account that's gone takes its events with it.
 * What's allowed is the manifest's list of sources (§3.4): a page edit asks nothing, a new or changed source waits.
 *
 * The manifest and its sources' rules are in app-manifest.ts; reading a file source is app-sources.ts.
 */
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { readJsonFile, writeFileAtomic } from "./atomic.js";
import { calendarSpan, checkManifest, isCalendarSource, isFileSource, isPiopioSource, MANIFEST_ID, MAX_APP_BYTES, MAX_SOURCE_BYTES, parseManifest, PIOPIO_SHAPES, piopioWords, RANGE_WORDS, sourcesHash, withManifest, type AppManifest, type AppSource, type CalendarSource, type PiopioAccess, type PiopioSource } from "./app-manifest.js";
import { readSource, sourcePath } from "./app-sources.js";

/** One event as a page gets it. */
export type AppEvent = { title: string; start: string; end: string; allDay: boolean; location?: string; calendar: string; account: string };
/** How Apps reach your calendars: the engine's connectors, or a fake in tests. */
export type CalendarAccess = {
	accounts(): { id: string; label: string; app: string }[];
	/** Settings › Connectors for reading this account's calendar: only "runs" is read by an app. */
	permission(accountId: string): "runs" | "ask" | "off";
	events(accountId: string, range: { from: string; to: string }): Promise<{ title: string; start: string; end: string; allDay: boolean; location?: string; calendar: string }[]>;
};

export type AccountStatus = { id: string; label: string; state: "ok" | "failed" | "gone"; error?: string; readAt?: string; failedAt?: string };

export type SourceStatus = {
	name: string;
	kind: "file" | "calendar" | "piopio";
	/** As the manifest says it (relative to the app's file, or absolute); a calendar source in words. */
	file: string;
	/** Where it is (a file source). */
	path: string;
	columns?: string[];
	/** A calendar source: each account and how its last read went. */
	accounts?: AccountStatus[];
	/** ok: read now; failed: this read failed (the data is the last good one, if any); waiting: not allowed yet. */
	state: "ok" | "failed" | "waiting";
	error?: string;
	/** When the data the page has was read. */
	readAt?: string;
	failedAt?: string;
};

export type AppView = {
	path: string;
	title: string;
	/** The page as written, manifest included (the app wraps it as it does a visual). */
	html: string;
	sources: SourceStatus[];
	/** What `piopio.onData` gets: each source's latest good data. */
	data: Record<string, unknown>;
	/** Sources whose data is older than their latest read (it failed), or missing. */
	stale: string[];
	/** False when the manifest lists sources you haven't allowed: the page draws what was read before. */
	allowed: boolean;
	/** When the oldest data shown was read. */
	updatedAt?: string;
	/** The latest change the app's conversation made that Undo would take back (docs/spec/35 §15). */
	undo?: { label: string; at: string };
	/** The conversation about it, once there is one. */
	conversation?: string;
};

/** One change to an app's page: what it was before and after, and who made it. */
type Revision = { at: string; label: string; by: "conversation" | "outside"; before: string; after: string; request?: string; undone?: boolean };
type History = { current?: string; revisions: Revision[] };
/** How many changes Undo can go back. */
const MAX_REVISIONS = 30;

type AccountCache = { events?: AppEvent[]; readAt?: string; error?: string; failedAt?: string };
type Cached = { data?: unknown; readAt?: string; error?: string; failedAt?: string; accounts?: Record<string, AccountCache> };
/** An account's read gives up after this long (§3.2). */
const READ_TIMEOUT_MS = 10_000;
type CacheFile = { sources: Record<string, Cached> };
type State = { allowed: Record<string, string>; conversations: Record<string, string> };

// ── Making an app ───────────────────────────────────────────────────────────────

export type MakeInput = { title: string; html: string; sources: Record<string, AppSource> };
/** Where the conversation is: its folder, and whether that's a chat's own (temporary) folder. */
export type MakeContext = { cwd: string; chatFolder?: string };
export type MakePlan = {
	path: string;
	title: string;
	manifest: AppManifest;
	html: string;
	/** Files to copy beside the app before it's written (from a chat's own folder). */
	copies: { from: string; to: string }[];
	/** In words, for the approval card. */
	summary: string;
	/** The approval card's parts (§17): what it reads, when it refreshes, where it's saved. */
	card: { title: string; reads: string[]; refresh: string; where: string };
};

const slug = (title: string) =>
	title
		.normalize("NFKD")
		.replace(/[̀-ͯ]/g, "")
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "")
		.slice(0, 40) || "app";

function unique(path: string, taken: (p: string) => boolean): string {
	if (!taken(path)) return path;
	const ext = extname(path);
	const stem = path.slice(0, path.length - ext.length);
	for (let i = 2; ; i++) if (!taken(`${stem}-${i}${ext}`)) return `${stem}-${i}${ext}`;
}

// ── The service ─────────────────────────────────────────────────────────────────

type Open = { count: number; watchers: FSWatcher[]; timer?: NodeJS.Timeout };

export class Apps {
	private state: State = { allowed: {}, conversations: {} };
	/** What each app's conversation was last asked, by path, so the changes that follow are its (and Undo's). */
	private readonly requests = new Map<string, { id: string; text: string; at: number }>();
	private readonly open = new Map<string, Open>();

	constructor(
		private readonly opts: {
			/** The engine's folder: `apps.json` and `apps-cache/`. */
			home: string;
			/** Where apps made outside a project go (`~/Piopio/Apps`). */
			appsDir: string;
			/** An open app's new data, after one of its files changed. */
			changed?: (view: AppView) => void;
			/** A new app was written (the Library lists it). */
			made?: (path: string) => void;
			/** Your calendars (Settings › Connectors), for calendar sources. */
			calendar?: CalendarAccess;
			/** Piopio's own numbers, for piopio sources. */
			piopio?: PiopioAccess;
			settleMs?: number;
		},
	) {
		const read = readJsonFile<Partial<State>>(this.stateFile, () => ({}));
		this.state = { allowed: read.allowed ?? {}, conversations: read.conversations ?? {} };
	}

	private get stateFile() {
		return join(this.opts.home, "apps.json");
	}

	/** The plan for `make_app`: checked, nothing written. Throws with what the model should fix. */
	plan(input: MakeInput, ctx: MakeContext): MakePlan {
		const title = (input.title ?? "").trim();
		if (!title) throw new Error("The app needs a title.");
		const html = typeof input.html === "string" ? input.html : "";
		if (!html.trim()) throw new Error("The app's html is empty.");
		if (Buffer.byteLength(html, "utf8") > MAX_APP_BYTES) throw new Error("The page is over 300 KB: keep data out of it (it comes from the sources) and libraries bundled.");
		if (!/piopio\s*\.\s*onData\s*\(/.test(html)) throw new Error("The page must draw from piopio.onData((data, meta) => …): that's how its data arrives, now and whenever a file changes.");
		const manifest = checkManifest({ title, sources: this.withAccounts(input.sources) });
		const project = ctx.chatFolder ? undefined : ctx.cwd;
		const path = unique(project ? join(project, "apps", `${slug(title)}.html`) : join(this.opts.appsDir, slug(title), `${slug(title)}.html`), existsSync);
		const appDir = dirname(path);
		const chat = ctx.chatFolder ? resolve(ctx.chatFolder) : undefined;
		const copies: MakePlan["copies"] = [];
		const lines: string[] = [];
		const sources: Record<string, AppSource> = {};
		for (const [name, src] of Object.entries(manifest.sources)) {
			if (isPiopioSource(src)) {
				sources[name] = src;
				lines.push(piopioWords(src));
				continue;
			}
			if (isCalendarSource(src)) {
				const known = new Map((this.opts.calendar?.accounts() ?? []).map((a) => [a.id, a]));
				const missing = src.accounts.filter((a) => !known.has(a));
				if (missing.length) throw new Error(`The source “${name}”: ${missing.join(", ")} isn't a connected calendar account.`);
				sources[name] = src;
				lines.push(`${src.accounts.map((a) => `${known.get(a)!.app} (${known.get(a)!.label})`).join(" and ")} for ${RANGE_WORDS[src.calendar]}`);
				continue;
			}
			const from = isAbsolute(src.file) ? src.file : resolve(ctx.cwd, src.file);
			const read = readSource(from, src.columns);
			if ("error" in read) throw new Error(`The source “${name}”: ${read.error}`);
			if (chat && (from === chat || from.startsWith(`${chat}${sep}`))) {
				// A chat's folder goes when the chat does: the app keeps its own copy (§14).
				const to = unique(join(appDir, basename(from)), (p) => existsSync(p) || copies.some((c) => c.to === p));
				copies.push({ from, to });
				sources[name] = { file: basename(to), ...(src.columns ? { columns: src.columns } : {}) };
				lines.push(`a copy of ${basename(from)} kept beside it`);
			} else {
				const inside = from.startsWith(`${appDir}${sep}`) || (project && from.startsWith(`${resolve(project)}${sep}`));
				sources[name] = { file: inside ? relative(appDir, from) : from, ...(src.columns ? { columns: src.columns } : {}) };
				lines.push(project && from.startsWith(`${resolve(project)}${sep}`) ? relative(project, from) : from);
			}
		}
		const final = { title, sources };
		const where = project ? relative(project, path) : path.replace(/^.*?\/Piopio\/Apps\//, "Piopio/Apps/");
		const refresh = Object.values(sources).some((s) => !isFileSource(s)) ? "When you open it, and with Refresh · no model" : "When its files change · no model";
		return { path, title, manifest: final, html: withManifest(html, final), copies, summary: `Make the app “${title}” in ${where}, reading ${lines.join(", ")}`, card: { title, reads: lines, refresh, where: dirname(where) === "." ? where : dirname(where) } };
	}

	/** Writes a planned app (after you allowed it): the copies, the page, its sources allowed and read once. */
	async write(plan: MakePlan): Promise<AppView> {
		mkdirSync(dirname(plan.path), { recursive: true });
		for (const c of plan.copies) copyFileSync(c.from, c.to);
		writeFileSync(plan.path, plan.html);
		this.state.allowed[plan.path] = sourcesHash(plan.manifest);
		this.saveState();
		const view = await this.refresh(plan.path);
		this.opts.made?.(plan.path);
		return view;
	}

	/**
	 * An app as it is now, its files read again (they're local and small) and its calendars as last read. Those are
	 * read again behind it when the last read is over a minute old, and the app gets them as `changed`. Watched until
	 * closed.
	 */
	openApp(path: string): AppView {
		const view = this.view(path, { readFiles: true });
		this.watch(path);
		const calendars = view.sources.filter((s) => s.kind === "calendar" || s.kind === "piopio");
		const old = calendars.some((s) => !s.readAt || Date.now() - Date.parse(s.readAt) > 60_000 || s.state === "failed");
		if (view.allowed && calendars.length && old) void this.refresh(path).then((v) => this.opts.changed?.(v), () => {});
		return view;
	}

	closeApp(path: string): void {
		const o = this.open.get(resolve(path));
		if (!o) return;
		if (--o.count > 0) return;
		for (const w of o.watchers) w.close();
		clearTimeout(o.timer);
		this.open.delete(resolve(path));
	}

	/** Reads every source now (when allowed): files, then each calendar account and Piopio's numbers. */
	async refresh(path: string): Promise<AppView> {
		path = resolve(path);
		const view = this.view(path, { readFiles: true });
		if (!view.allowed) return view;
		const manifest = parseManifest(this.page(path));
		const cache = this.readCache(path);
		let read = false;
		for (const [name, src] of Object.entries(manifest.sources)) {
			if (isFileSource(src)) continue;
			cache.sources[name] = isPiopioSource(src) ? await this.readPiopio(src, cache.sources[name] ?? {}) : await this.readCalendar(src, cache.sources[name] ?? {});
			read = true;
		}
		if (!read) return view;
		// The cache again: a file may have been read meanwhile (a watch).
		const now = this.readCache(path);
		for (const [name, src] of Object.entries(manifest.sources)) if (!isFileSource(src)) now.sources[name] = cache.sources[name]!;
		this.writeCache(path, now);
		return this.view(path, {});
	}

	/** Allow: the sources the manifest lists now. */
	async allow(path: string): Promise<AppView> {
		const manifest = parseManifest(this.page(path));
		this.state.allowed[resolve(path)] = sourcesHash(manifest);
		this.saveState();
		this.rewatch(path);
		return this.refresh(path);
	}

	/**
	 * Stop reading: the app's sources aren't allowed any more, and everything it read is forgotten (files, your
	 * calendars, Piopio's numbers), so it shows nothing until you allow it again (re-audit 2026-11-25 V7: only the
	 * calendars went, and the rest kept showing). Waiting for Allow after a page edit is different: it shows what you
	 * allowed before (`view`).
	 */
	revoke(path: string): AppView {
		path = resolve(path);
		delete this.state.allowed[path];
		this.saveState();
		const cache = this.readCache(path);
		cache.sources = {};
		this.writeCache(path, cache);
		return this.view(path, {});
	}

	/** A calendar account was connected, disconnected or changed: open apps show what they may show now. */
	connectionsChanged(): void {
		for (const path of this.open.keys()) {
			try {
				this.opts.changed?.(this.view(path, {}));
			} catch {
				// A broken app: its next open says so.
			}
		}
	}

	// ── The app's conversation and Undo (docs/spec/35 §15) ─────────────────

	/** The conversation about this app, if it has one. */
	conversationOf(path: string): string | undefined {
		return this.state.conversations[resolve(path)];
	}

	/** Which app a conversation is about. */
	appOf(sessionId: string): string | undefined {
		return Object.entries(this.state.conversations).find(([, id]) => id === sessionId)?.[0];
	}

	setConversation(path: string, sessionId: string): void {
		this.state.conversations[resolve(path)] = sessionId;
		this.saveState();
	}

	/** The app's conversation was asked something: the page's changes from now on are that request's. */
	noteRequest(path: string, text: string): void {
		path = resolve(path);
		if (existsSync(path)) this.track(path, this.page(path));
		this.requests.set(path, { id: `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`, text: text.trim().split("\n")[0]!.slice(0, 120), at: Date.now() });
	}

	/** What the conversation is told about its app: where it is, what it reads, and when to change it. */
	describe(path: string): string {
		path = resolve(path);
		let manifest: AppManifest | undefined;
		try {
			manifest = parseManifest(this.page(path));
		} catch {
			// A broken page: the conversation is still about it, and can fix it.
		}
		const sources = manifest
			? Object.entries(manifest.sources)
					.map(([name, s]) =>
						isFileSource(s)
							? `- ${name}: ${sourcePath(path, s.file)}${s.columns ? ` (columns ${s.columns.join(", ")})` : ""}`
							: isPiopioSource(s)
								? `- ${name}: ${piopioWords(s)}, read from Piopio with no model (${s.piopio}${s.args ? ` ${JSON.stringify(s.args)}` : ""}): ${PIOPIO_SHAPES[s.piopio]}`
								: `- ${name}: calendar events for ${RANGE_WORDS[s.calendar]} from ${s.accounts.join(", ")}, as a list of { title, start, end, allDay, location, calendar, account } sorted by start`,
					)
					.join("\n")
			: "- (the manifest can't be read: fix it)";
		return `# This conversation is about an app
The app${manifest ? ` “${manifest.title}”` : ""} is the page ${path}. Piopio shows it beside this conversation. It reads its data from files and gets it through piopio.onData; it redraws when they change, with no model. Its sources:
${sources}
- A question about the app or its data ("which month was highest?", "why is this red?"): answer it here, and don't change the app. Read a source file only when the answer needs its data, and say which file you read.
- A change the user asks for ("add a budget line", "split it by month", "make the bars green"): edit ${path} with your edit tool. Keep the manifest (the <script id="${MANIFEST_ID}"> block) as it is unless they ask for a new or different source; a new source waits for the user's Allow. Every number and label must still come from data. The page reloads when you save, and the user can Undo.
- Unsure whether they want an answer or a change: answer, and offer the change in one line.
- A change to how it looks needs the page only, not the data: don't read the data for it.`;
	}

	/**
	 * Undo: the page as it was before the latest change its conversation made. Only the page: data files stay as they
	 * are. If the page changed since in another way (your editor), it says so unless `force`.
	 */
	undo(path: string, force = false): AppView {
		path = resolve(path);
		const html = this.page(path);
		const history = this.track(path, html);
		const target = undoable(history);
		if (!target) throw new Error("There's nothing to undo.");
		if (history.current !== target.after && !force) throw new AppConflict(`${basename(path)} changed outside Piopio after “${target.label}”. Undo would lose that change too.`);
		writeFileSync(path, target.before);
		target.undone = true;
		history.current = target.before;
		this.writeHistory(path, history);
		this.rewatch(path);
		return this.view(path, { readFiles: true });
	}

	/** Stops every watch (the engine is stopping). */
	stop(): void {
		for (const o of this.open.values()) {
			for (const w of o.watchers) w.close();
			clearTimeout(o.timer);
		}
		this.open.clear();
	}

	// ── Internals ──────────────────────────────────────────────────────────

	private page(path: string): string {
		if (!existsSync(path)) throw new Error(`There's no app at ${path}.`);
		return readFileSync(path, "utf8");
	}

	private view(path: string, how: { readFiles?: boolean }): AppView {
		path = resolve(path);
		const html = this.page(path);
		const history = this.track(path, html);
		const manifest = parseManifest(html);
		const allowed = this.state.allowed[path] === sourcesHash(manifest);
		const cache = this.readCache(path);
		const now = new Date().toISOString();
		let dirty = false;
		const sources: SourceStatus[] = [];
		for (const [name, src] of Object.entries(manifest.sources)) {
			if (isPiopioSource(src)) {
				const c = cache.sources[name] ?? {};
				sources.push({
					name,
					kind: "piopio",
					file: `Piopio · ${piopioWords(src)}`,
					path: "",
					state: !allowed ? "waiting" : c.error ? "failed" : "ok",
					...(c.error ? { error: c.error } : {}),
					...(c.readAt ? { readAt: c.readAt } : {}),
					...(c.failedAt ? { failedAt: c.failedAt } : {}),
				});
				continue;
			}
			if (isCalendarSource(src)) {
				const { status, cached, changed } = this.calendarStatus(name, src, cache.sources[name], allowed);
				if (changed) {
					cache.sources[name] = cached;
					dirty = true;
				}
				sources.push(status);
				continue;
			}
			const full = sourcePath(path, src.file);
			const had = cache.sources[name] ?? {};
			if (allowed && how.readFiles) {
				const r = readSource(full, src.columns);
				cache.sources[name] = "error" in r ? { ...had, error: r.error, failedAt: now } : { data: r.data, readAt: now };
				dirty = true;
			}
			const c = cache.sources[name] ?? {};
			sources.push({
				name,
				kind: "file",
				file: src.file,
				path: full,
				...(src.columns ? { columns: src.columns } : {}),
				state: !allowed ? "waiting" : c.error ? "failed" : "ok",
				...(c.error ? { error: c.error } : {}),
				...(c.readAt ? { readAt: c.readAt } : {}),
				...(c.failedAt ? { failedAt: c.failedAt } : {}),
			});
		}
		if (dirty) this.writeCache(path, cache);
		const data: Record<string, unknown> = {};
		for (const s of sources) {
			const c = cache.sources[s.name];
			if (s.kind === "calendar") {
				// Every account still connected that was read once: its events, the last good ones if this read failed.
				const shown = (s.accounts ?? []).filter((a) => a.state !== "gone" && c?.accounts?.[a.id]?.readAt);
				if (shown.length) data[s.name] = shown.flatMap((a) => c!.accounts![a.id]!.events ?? []).sort((x, y) => (x.start < y.start ? -1 : x.start > y.start ? 1 : 0));
			} else if (c?.readAt) data[s.name] = c.data;
		}
		const stale = sources.filter((s) => s.state !== "ok" || !s.readAt).map((s) => s.name);
		const reads = sources.map((s) => s.readAt).filter((r): r is string => Boolean(r)).sort();
		const last = undoable(history);
		return { path, title: manifest.title, html, sources, data, stale, allowed, ...(reads[0] ? { updatedAt: reads[0] } : {}), ...(last ? { undo: { label: last.label, at: last.at } } : {}), ...(this.state.conversations[path] ? { conversation: this.state.conversations[path] } : {}) };
	}

	/** make_app's calendar sources without accounts read every connected calendar whose reading isn't off. */
	private withAccounts(sources: Record<string, unknown>): Record<string, unknown> {
		const out: Record<string, unknown> = {};
		for (const [name, value] of Object.entries(sources ?? {})) {
			const v = (value ?? {}) as { calendar?: unknown; accounts?: unknown };
			if (v.calendar === undefined || (Array.isArray(v.accounts) && v.accounts.length)) {
				out[name] = value;
				continue;
			}
			const access = this.opts.calendar;
			const accounts = (access?.accounts() ?? []).filter((a) => access!.permission(a.id) !== "off").map((a) => a.id);
			if (!accounts.length) throw new Error(`The source “${name}”: no calendar is connected (or reading it is off). The user connects one in Settings › Connectors.`);
			out[name] = { ...v, accounts };
		}
		return out;
	}

	/** Piopio's numbers read now; a failed read keeps the last good data, dated. */
	private async readPiopio(src: PiopioSource, had: Cached): Promise<Cached> {
		const now = new Date().toISOString();
		const access = this.opts.piopio;
		if (!access) return { ...had, error: "Piopio's numbers aren't available here.", failedAt: now };
		try {
			const data = await withTimeout(access.read(src.piopio, src.args ?? {}), READ_TIMEOUT_MS, `Piopio didn't answer in ${READ_TIMEOUT_MS / 1000} s.`);
			if (Buffer.byteLength(JSON.stringify(data), "utf8") > MAX_SOURCE_BYTES) return { ...had, error: `${piopioWords(src)} is over the 2 MB an app can read.`, failedAt: now };
			return { data, readAt: now };
		} catch (error) {
			return { ...had, error: (error as Error).message || "Piopio couldn't read it.", failedAt: now };
		}
	}

	/** Each account of a calendar source read now, apart: one that fails keeps its last good events, dated. */
	private async readCalendar(src: CalendarSource, had: Cached): Promise<Cached> {
		const access = this.opts.calendar;
		const known = new Map((access?.accounts() ?? []).map((a) => [a.id, a]));
		const { from, to } = calendarSpan(src.calendar);
		const accounts: Record<string, AccountCache> = {};
		await Promise.all(
			src.accounts.map(async (id) => {
				const a = known.get(id);
				if (!access || !a) return; // Gone: nothing kept (§16).
				const prev = had.accounts?.[id] ?? {};
				const now = new Date().toISOString();
				const permission = access.permission(id);
				if (permission !== "runs") {
					// Off or Ask in Settings: an app reads only what runs on its own, and keeps nothing it can't read now.
					accounts[id] = { error: `Reading ${a.app} (${a.label}) ${permission === "off" ? "is off" : "asks first"} in Settings › Connectors, so apps don't read it.`, failedAt: now };
					return;
				}
				try {
					const events = await withTimeout(access.events(id, { from, to }), READ_TIMEOUT_MS, `${a.app} (${a.label}) didn't answer in ${READ_TIMEOUT_MS / 1000} s.`);
					accounts[id] = { events: events.map((e) => ({ title: e.title, start: e.start, end: e.end, allDay: e.allDay, ...(e.location ? { location: e.location } : {}), calendar: e.calendar, account: a.label })), readAt: now };
				} catch (error) {
					const message = (error as Error).message || "it didn't answer";
					accounts[id] = { ...prev, error: message.startsWith(a.app) ? message : `${a.app} (${a.label}): ${message}`, failedAt: now };
				}
			}),
		);
		return { accounts };
	}

	/** A calendar source as it stands: its accounts' states, and its cache without accounts that are gone. */
	private calendarStatus(name: string, src: CalendarSource, cached: Cached | undefined, allowed: boolean): { status: SourceStatus; cached: Cached; changed: boolean } {
		const known = new Map((this.opts.calendar?.accounts() ?? []).map((a) => [a.id, a]));
		const accounts: Record<string, AccountCache> = { ...(cached?.accounts ?? {}) };
		let changed = false;
		const states: AccountStatus[] = src.accounts.map((id) => {
			const a = known.get(id);
			const c = accounts[id];
			if (!a) {
				// Disconnected: what it read goes too, not just the next read.
				if (c) {
					delete accounts[id];
					changed = true;
				}
				return { id, label: id, state: "gone", error: `${id} isn't connected any more.` };
			}
			// Reading it set to Ask or Off in Settings › Connectors: what it read goes now, not at the next read (V7).
			const permission = this.opts.calendar?.permission(id) ?? "runs";
			if (permission !== "runs") {
				const error = `Reading ${a.app} (${a.label}) ${permission === "off" ? "is off" : "asks first"} in Settings › Connectors, so apps don't read it.`;
				if (c?.events || c?.error !== error) {
					accounts[id] = { error, failedAt: c?.failedAt ?? new Date().toISOString() };
					changed = true;
				}
				return { id, label: `${a.app} (${a.label})`, state: "failed", error, failedAt: accounts[id]!.failedAt! };
			}
			return { id, label: `${a.app} (${a.label})`, state: c?.error ? "failed" : "ok", ...(c?.error ? { error: c.error } : {}), ...(c?.readAt ? { readAt: c.readAt } : {}), ...(c?.failedAt ? { failedAt: c.failedAt } : {}) };
		});
		const problems = states.filter((s) => s.state !== "ok");
		const reads = states.filter((s) => s.state !== "gone" && s.readAt).map((s) => s.readAt!).sort();
		const status: SourceStatus = {
			name,
			kind: "calendar",
			file: `Calendar · ${RANGE_WORDS[src.calendar].replace(/ \(.*\)$/, "")}`,
			path: "",
			accounts: states,
			state: !allowed ? "waiting" : problems.length ? "failed" : "ok",
			...(problems.length ? { error: problems.map((p) => p.error).join(" ") } : {}),
			...(reads[0] ? { readAt: reads[0] } : {}),
			...(problems.find((p) => p.failedAt)?.failedAt ? { failedAt: problems.find((p) => p.failedAt)!.failedAt! } : {}),
		};
		return { status, cached: { accounts }, changed };
	}

	/**
	 * Notes a change to the page since it was last seen, as a revision: the conversation's when it was asked something
	 * in the last half hour (one revision per request), otherwise made outside Piopio.
	 */
	private track(path: string, html: string): History {
		const history = this.readHistory(path);
		if (history.current === undefined) {
			history.current = html;
			this.writeHistory(path, history);
			return history;
		}
		if (history.current === html) return history;
		const request = this.requests.get(path);
		const recent = request && Date.now() - request.at < 30 * 60_000 ? request : undefined;
		const last = history.revisions.at(-1);
		if (recent && last?.request === recent.id && !last.undone && last.after === history.current) last.after = html;
		else
			history.revisions.push({
				at: new Date().toISOString(),
				label: recent?.text ?? "Changed outside Piopio",
				by: recent ? "conversation" : "outside",
				before: history.current,
				after: html,
				...(recent ? { request: recent.id } : {}),
			});
		history.revisions = history.revisions.slice(-MAX_REVISIONS);
		history.current = html;
		this.writeHistory(path, history);
		return history;
	}

	private historyFile(path: string): string {
		return join(this.opts.home, "apps-history", `${createHash("sha1").update(resolve(path)).digest("hex").slice(0, 20)}.json`);
	}

	private readHistory(path: string): History {
		const read = readJsonFile<Partial<History>>(this.historyFile(path), () => ({}));
		return { ...(read.current !== undefined ? { current: read.current } : {}), revisions: read.revisions ?? [] };
	}

	private writeHistory(path: string, history: History): void {
		const file = this.historyFile(path);
		mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
		writeFileAtomic(file, JSON.stringify(history), { mode: 0o600 });
	}

	private cacheFile(path: string): string {
		return join(this.opts.home, "apps-cache", `${createHash("sha1").update(resolve(path)).digest("hex").slice(0, 20)}.json`);
	}

	private readCache(path: string): CacheFile {
		return { sources: readJsonFile<Partial<CacheFile>>(this.cacheFile(path), () => ({})).sources ?? {} };
	}

	private writeCache(path: string, cache: CacheFile): void {
		const file = this.cacheFile(path);
		mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
		writeFileAtomic(file, JSON.stringify(cache), { mode: 0o600 });
	}

	private saveState(): void {
		mkdirSync(this.opts.home, { recursive: true });
		writeFileAtomic(this.stateFile, JSON.stringify(this.state, null, "\t"), { mode: 0o600 });
	}

	/** Watches the page and each source's folder (a file saved by replacing it keeps being seen). */
	private watch(path: string): void {
		path = resolve(path);
		const had = this.open.get(path);
		if (had) {
			had.count++;
			return;
		}
		const o: Open = { count: 1, watchers: [] };
		this.open.set(path, o);
		this.addWatchers(path, o);
	}

	private rewatch(path: string): void {
		const o = this.open.get(resolve(path));
		if (!o) return;
		for (const w of o.watchers) w.close();
		o.watchers = [];
		this.addWatchers(resolve(path), o);
	}

	private addWatchers(path: string, o: Open): void {
		let files: string[] = [path];
		try {
			const manifest = parseManifest(this.page(path));
			files = [path, ...Object.values(manifest.sources).flatMap((s) => (isFileSource(s) ? [sourcePath(path, s.file)] : []))];
		} catch {
			// A broken manifest: only the page is watched, so fixing it is seen.
		}
		const byDir = new Map<string, Set<string>>();
		for (const f of files) {
			const dir = dirname(f);
			if (!byDir.has(dir)) byDir.set(dir, new Set());
			byDir.get(dir)!.add(basename(f));
		}
		for (const [dir, names] of byDir) {
			if (!existsSync(dir)) continue;
			try {
				const w = watch(dir, (_event, name) => {
					if (name && !names.has(name.toString())) return;
					this.changedSoon(path);
				});
				w.on("error", () => {});
				o.watchers.push(w);
			} catch {
				// A folder that can't be watched: Refresh still reads it.
			}
		}
	}

	private changedSoon(path: string): void {
		const o = this.open.get(path);
		if (!o) return;
		clearTimeout(o.timer);
		o.timer = setTimeout(() => {
			try {
				// The page may have changed its sources: watch what it lists now.
				this.rewatch(path);
				this.opts.changed?.(this.view(path, { readFiles: true }));
			} catch {
				// The app was deleted or broken while open: the next open says so.
			}
		}, this.opts.settleMs ?? 300);
		o.timer.unref?.();
	}
}

/** The change Undo takes back: the conversation's latest that isn't undone (changes made outside aren't Undo's). */
function undoable(history: History): Revision | undefined {
	return [...history.revisions].reverse().find((r) => r.by === "conversation" && !r.undone);
}

/** Undo would overwrite a change made outside Piopio. */
export class AppConflict extends Error {}

function withTimeout<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
	let timer: NodeJS.Timeout | undefined;
	const timeout = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Error(message)), ms);
		timer.unref?.();
	});
	return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
