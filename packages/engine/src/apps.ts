/**
 * Apps (docs/spec/35 §3, §14): a visual that reads its data instead of carrying it. An app is one `.html` file whose
 * manifest (`<script type="application/json" id="piopio-app">`) lists its sources; the engine reads them and the app
 * hands the result to the page through `piopio.onData`, so the page never reaches out.
 *
 * L2 reads files only: CSV, TSV, JSON, Markdown and text. A source can list the columns it needs; a file that's gone,
 * empty, too big, unparseable or missing a column fails, and the app keeps that source's last good data, dated. What's
 * allowed is the manifest's list of sources (§3.4): a page edit asks nothing, a new or changed source waits for Allow.
 */
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";

export const MANIFEST_ID = "piopio-app";
/** The most a source may hand the page (§3.2). */
export const MAX_SOURCE_BYTES = 2 * 1024 * 1024;
/** Larger than any reasonable app page (as visuals, 25). */
export const MAX_APP_BYTES = 300 * 1024;

export type AppSource = { file: string; columns?: string[] };
export type AppManifest = { title: string; sources: Record<string, AppSource> };

export type SourceStatus = {
	name: string;
	/** As the manifest says it (relative to the app's file, or absolute). */
	file: string;
	/** Where it is. */
	path: string;
	columns?: string[];
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
};

type Cached = { data?: unknown; readAt?: string; error?: string; failedAt?: string };
type CacheFile = { sources: Record<string, Cached> };
type State = { allowed: Record<string, string> };

// ── The manifest ────────────────────────────────────────────────────────────────

const MANIFEST_RE = new RegExp(`<script[^>]*\\bid\\s*=\\s*["']${MANIFEST_ID}["'][^>]*>([\\s\\S]*?)</script>\\s*`, "i");
const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]{0,39}$/;

/** True when an `.html` file's start has an app manifest (the Library's kind). */
export function isAppFile(path: string): boolean {
	if (!/\.html?$/i.test(path)) return false;
	try {
		const head = readFileSync(path, "utf8").slice(0, 16_384);
		return MANIFEST_RE.test(head);
	} catch {
		return false;
	}
}

/** The page's manifest, checked; throws with what's wrong. */
export function parseManifest(html: string): AppManifest {
	const m = MANIFEST_RE.exec(html);
	if (!m) throw new Error("This page has no app manifest.");
	let raw: unknown;
	try {
		raw = JSON.parse(m[1]!);
	} catch {
		throw new Error("The app's manifest isn't valid JSON.");
	}
	return checkManifest(raw);
}

function checkManifest(raw: unknown): AppManifest {
	const o = (raw ?? {}) as { title?: unknown; sources?: unknown };
	const title = typeof o.title === "string" && o.title.trim() ? o.title.trim() : "App";
	if (!o.sources || typeof o.sources !== "object" || Array.isArray(o.sources)) throw new Error("The manifest has no sources.");
	const sources: Record<string, AppSource> = {};
	for (const [name, value] of Object.entries(o.sources as Record<string, unknown>)) {
		if (!NAME_RE.test(name)) throw new Error(`“${name}” can't name a source: letters, digits and _ only.`);
		const v = (value ?? {}) as { file?: unknown; columns?: unknown; tool?: unknown; script?: unknown; piopio?: unknown };
		if (v.tool || v.script || v.piopio) throw new Error(`The source “${name}” isn't a file. Apps read files for now: write what it needs to a CSV or JSON file, and read that.`);
		if (typeof v.file !== "string" || !v.file.trim()) throw new Error(`The source “${name}” needs a file.`);
		const columns = Array.isArray(v.columns) ? v.columns.filter((c): c is string => typeof c === "string" && c.trim() !== "").map((c) => c.trim()) : undefined;
		sources[name] = { file: v.file.trim(), ...(columns?.length ? { columns } : {}) };
	}
	if (!Object.keys(sources).length) throw new Error("The manifest has no sources.");
	return { title, sources };
}

/** What allowing covers: the sources, not the page (§3.4). */
export function sourcesHash(m: AppManifest): string {
	const sorted = Object.keys(m.sources)
		.sort()
		.map((k) => [k, m.sources[k]!.file, m.sources[k]!.columns ?? []]);
	return createHash("sha1").update(JSON.stringify(sorted)).digest("hex").slice(0, 16);
}

/** The page with this manifest at the top (replacing any it had), and a stand-in `piopio` for other browsers. */
export function withManifest(html: string, manifest: AppManifest): string {
	const body = html.replace(MANIFEST_RE, "");
	const json = JSON.stringify(manifest, null, "\t").replace(/</g, "\\u003c");
	const top = `<script type="application/json" id="${MANIFEST_ID}">\n${json}\n</script>\n${STANDIN}\n`;
	const head = /<head[^>]*>/i.exec(body);
	if (head) return body.slice(0, head.index + head[0].length) + "\n" + top + body.slice(head.index + head[0].length);
	return top + body.replace(/^\s+/, "");
}

/** Outside Piopio there's no `piopio`: the page says where to open it instead of failing. Piopio's own comes first. */
const STANDIN = `<script>window.piopio ??= { send() {}, prefill() {}, onData() { addEventListener("DOMContentLoaded", () => document.body.insertAdjacentHTML("afterbegin", '<p style="font:13px system-ui;color:#888">Open in Piopio to see live data.</p>')); } };</script>`;

// ── Reading a source ────────────────────────────────────────────────────────────

const READABLE = new Set(["csv", "tsv", "json", "md", "markdown", "txt"]);

export function sourcePath(appPath: string, file: string): string {
	return isAbsolute(file) ? file : resolve(dirname(appPath), file);
}

/** One source, read and checked: its data, or why it can't be used. */
export function readSource(path: string, columns?: string[]): { data: unknown } | { error: string } {
	const name = basename(path);
	const ext = extname(path).slice(1).toLowerCase();
	if (!READABLE.has(ext)) return { error: `${name} isn't a file an app can read (CSV, TSV, JSON, Markdown or text).` };
	let size: number;
	try {
		const s = statSync(path);
		if (!s.isFile()) return { error: `${name} isn't a file.` };
		size = s.size;
	} catch {
		return { error: `${name} isn't there any more.` };
	}
	if (size > MAX_SOURCE_BYTES) return { error: `${name} is ${(size / 1024 / 1024).toFixed(1)} MB, over the 2 MB an app can read.` };
	let text: string;
	try {
		text = readFileSync(path, "utf8").replace(/^﻿/, "");
	} catch (error) {
		return { error: `${name} can't be read: ${(error as Error).message}` };
	}
	if (!text.trim()) return { error: `${name} is empty.` };
	if (ext === "json") {
		try {
			return { data: JSON.parse(text) };
		} catch {
			return { error: `${name} isn't valid JSON.` };
		}
	}
	if (ext === "csv" || ext === "tsv") {
		const table = parseTable(text, ext === "tsv" ? "\t" : undefined);
		if (!table.columns.length) return { error: `${name} has no header row.` };
		const missing = (columns ?? []).filter((c) => !table.columns.includes(c));
		if (missing.length) return { error: `${name} has no ${missing.map((c) => `“${c}”`).join(", ")} column${missing.length > 1 ? "s" : ""} (it has ${table.columns.map((c) => `“${c}”`).join(", ")}).` };
		return { data: table.rows };
	}
	return { data: text };
}

/**
 * A CSV or TSV as rows by column. The separator is `,` unless the header has more `;` (a spreadsheet in Spanish or
 * French) or it's a TSV. Plain numbers become numbers; everything else stays text.
 */
export function parseTable(text: string, separator?: string): { columns: string[]; rows: Record<string, string | number>[] } {
	const firstLine = text.slice(0, text.indexOf("\n") === -1 ? text.length : text.indexOf("\n"));
	const sep = separator ?? ((firstLine.match(/;/g)?.length ?? 0) > (firstLine.match(/,/g)?.length ?? 0) ? ";" : ",");
	const records = splitRecords(text, sep);
	const header = records.shift()?.map((c) => c.trim()) ?? [];
	const columns = header.filter((c) => c !== "");
	const rows = records
		.filter((r) => r.some((c) => c.trim() !== ""))
		.map((r) => {
			const row: Record<string, string | number> = {};
			header.forEach((col, i) => {
				if (!col) return;
				const raw = (r[i] ?? "").trim();
				row[col] = /^-?\d+(\.\d+)?$/.test(raw) ? Number(raw) : raw;
			});
			return row;
		});
	return { columns, rows };
}

function splitRecords(text: string, sep: string): string[][] {
	const out: string[][] = [];
	let row: string[] = [];
	let cell = "";
	let quoted = false;
	for (let i = 0; i < text.length; i++) {
		const ch = text[i]!;
		if (quoted) {
			if (ch === '"' && text[i + 1] === '"') {
				cell += '"';
				i++;
			} else if (ch === '"') quoted = false;
			else cell += ch;
		} else if (ch === '"' && cell.trim() === "") {
			quoted = true;
			cell = "";
		} else if (ch === sep) {
			row.push(cell);
			cell = "";
		} else if (ch === "\n" || ch === "\r") {
			if (ch === "\r" && text[i + 1] === "\n") i++;
			row.push(cell);
			out.push(row);
			row = [];
			cell = "";
		} else cell += ch;
	}
	if (cell !== "" || row.length) {
		row.push(cell);
		out.push(row);
	}
	return out;
}

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
	private state: State = { allowed: {} };
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
			settleMs?: number;
		},
	) {
		try {
			const read = JSON.parse(readFileSync(this.stateFile, "utf8")) as Partial<State>;
			this.state = { allowed: read.allowed ?? {} };
		} catch {
			// Nothing allowed yet.
		}
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
		const manifest = checkManifest({ title, sources: input.sources });
		const project = ctx.chatFolder ? undefined : ctx.cwd;
		const path = unique(project ? join(project, "apps", `${slug(title)}.html`) : join(this.opts.appsDir, slug(title), `${slug(title)}.html`), existsSync);
		const appDir = dirname(path);
		const chat = ctx.chatFolder ? resolve(ctx.chatFolder) : undefined;
		const copies: MakePlan["copies"] = [];
		const lines: string[] = [];
		const sources: Record<string, AppSource> = {};
		for (const [name, src] of Object.entries(manifest.sources)) {
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
		return { path, title, manifest: final, html: withManifest(html, final), copies, summary: `Make the app “${title}” in ${where}, reading ${lines.join(", ")}` };
	}

	/** Writes a planned app (after you allowed it): the copies, the page, its sources allowed and read once. */
	write(plan: MakePlan): AppView {
		mkdirSync(dirname(plan.path), { recursive: true });
		for (const c of plan.copies) copyFileSync(c.from, c.to);
		writeFileSync(plan.path, plan.html);
		this.state.allowed[plan.path] = sourcesHash(plan.manifest);
		this.saveState();
		const view = this.refresh(plan.path);
		this.opts.made?.(plan.path);
		return view;
	}

	/** An app as it is now, its files read again (they're local and small). Watches it until closed. */
	openApp(path: string): AppView {
		const view = this.view(path, { readAll: true });
		this.watch(path);
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

	/** Reads every source now (when allowed). */
	refresh(path: string): AppView {
		return this.view(path, { readAll: true });
	}

	/** Allow: the sources the manifest lists now. */
	allow(path: string): AppView {
		const manifest = parseManifest(this.page(path));
		this.state.allowed[resolve(path)] = sourcesHash(manifest);
		this.saveState();
		this.rewatch(path);
		return this.refresh(path);
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

	private view(path: string, how: { readAll?: boolean }): AppView {
		path = resolve(path);
		const html = this.page(path);
		const manifest = parseManifest(html);
		const allowed = this.state.allowed[path] === sourcesHash(manifest);
		const cache = this.readCache(path);
		const now = new Date().toISOString();
		let dirty = false;
		const sources: SourceStatus[] = [];
		for (const [name, src] of Object.entries(manifest.sources)) {
			const full = sourcePath(path, src.file);
			const had = cache.sources[name] ?? {};
			if (allowed && how.readAll) {
				const r = readSource(full, src.columns);
				cache.sources[name] = "error" in r ? { ...had, error: r.error, failedAt: now } : { data: r.data, readAt: now };
				dirty = true;
			}
			const c = cache.sources[name] ?? {};
			sources.push({
				name,
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
		for (const s of sources) if (cache.sources[s.name]?.readAt) data[s.name] = cache.sources[s.name]!.data;
		const stale = sources.filter((s) => s.state !== "ok" || !s.readAt).map((s) => s.name);
		const reads = sources.map((s) => s.readAt).filter((r): r is string => Boolean(r)).sort();
		return { path, title: manifest.title, html, sources, data, stale, allowed, ...(reads[0] ? { updatedAt: reads[0] } : {}) };
	}

	private cacheFile(path: string): string {
		return join(this.opts.home, "apps-cache", `${createHash("sha1").update(resolve(path)).digest("hex").slice(0, 20)}.json`);
	}

	private readCache(path: string): CacheFile {
		try {
			const read = JSON.parse(readFileSync(this.cacheFile(path), "utf8")) as Partial<CacheFile>;
			return { sources: read.sources ?? {} };
		} catch {
			return { sources: {} };
		}
	}

	private writeCache(path: string, cache: CacheFile): void {
		const file = this.cacheFile(path);
		mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
		writeFileSync(`${file}.tmp`, JSON.stringify(cache), { mode: 0o600 });
		renameSync(`${file}.tmp`, file);
	}

	private saveState(): void {
		mkdirSync(this.opts.home, { recursive: true });
		writeFileSync(`${this.stateFile}.tmp`, JSON.stringify(this.state, null, "\t"), { mode: 0o600 });
		renameSync(`${this.stateFile}.tmp`, this.stateFile);
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
			files = [path, ...Object.values(manifest.sources).map((s) => sourcePath(path, s.file))];
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
				this.opts.changed?.(this.refresh(path));
			} catch {
				// The app was deleted or broken while open: the next open says so.
			}
		}, this.opts.settleMs ?? 300);
		o.timer.unref?.();
	}
}
