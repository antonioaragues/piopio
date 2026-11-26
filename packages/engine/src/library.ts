/**
 * The Library (docs/spec/35 §4): everything Piopio and your agents made, listed where it already lives. It's an index
 * of files and visuals, not a store: `library.json` holds each item's path (or the visual's conversation and call), its
 * kind, the note on it, where it came from, who made it and when, plus your pins and what you removed.
 *
 * It fills itself from conversations as search does (it reads the same items): every file a `present_files` call
 * handed over, every file a chat wrote in its own folder that's meant to be looked at, and every visual that wasn't
 * replaced by a fix in the same turn. You add any other file by hand; Remove hides an item and never touches its file.
 */
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { ContainerRef, LibraryItem, LibraryKind, TimelineItem } from "@piopio/protocol";
import { modelOf } from "@piopio/runtime";
import type { ModelRef } from "@piopio/protocol";
import { agentUtility } from "./runtimes/agent.js";
import { SearchIndex } from "./search.js";
import { replacedVisuals } from "./tools/visuals.js";
import { isAppFile } from "./app-manifest.js";
import { readJsonFile, writeFileAtomic } from "./atomic.js";

/** Where an item came from, as the session manager knows it. */
export type LibraryOrigin = {
	ref: ContainerRef;
	/** The conversation's title (an agent's: "Rita", or "Rita › Run 12"). */
	title: string;
	/** Who made it: "Piopio", or the agent's name. */
	by: string;
	/** The project's folder, for a conversation in a project. */
	project?: string;
	/** A chat's own folder: files written there come in even when not handed over (35 §4.2). */
	chatFolder?: string;
};

type Stored = {
	key: string;
	kind: LibraryKind;
	name: string;
	path?: string;
	note?: string;
	at: string;
	how: "presented" | "written" | "visual" | "added";
	origin?: { ref: ContainerRef; title: string; project?: string };
	by: string;
	visual?: { callId: string; version?: string };
	/** Paths it was known by before Locate… (`file:<path>` keys): a conversation that hands one over again finds it. */
	aliases?: string[];
	/** When its file was first found missing; after 30 days the item leaves (docs/spec/35 §6). */
	missingSince?: string;
};

/** How long a missing file stays listed, marked, for Locate… or Remove. */
export const MISSING_DAYS = 30;

type File = { version: 1; items: Stored[]; pins: string[]; hidden: string[] };

const KINDS: Record<string, LibraryKind> = {
	md: "document", markdown: "document", txt: "document", pdf: "document", docx: "document", doc: "document", rtf: "document", pages: "document",
	html: "page", htm: "page", xhtml: "page",
	png: "image", jpg: "image", jpeg: "image", gif: "image", webp: "image", svg: "image", heic: "image",
	csv: "data", tsv: "data", json: "data", xlsx: "data", xls: "data", numbers: "data",
	pptx: "slides", key: "slides",
};

/** What a file is, by its extension (an `.html` with an app manifest is an app); `file` for anything else. */
export function kindOf(path: string): LibraryKind {
	const kind = KINDS[extname(path).slice(1).toLowerCase()] ?? "file";
	return kind === "page" && isAppFile(path) ? "app" : kind;
}

const idOf = (key: string) => createHash("sha1").update(key).digest("hex").slice(0, 16);
const fileKey = (path: string) => `file:${resolve(path)}`;
const convPrefix = (ref: ContainerRef) => `visual:${ref.kind}:${ref.id}:${ref.conversationId ?? ""}:`;
const visualKey = (ref: ContainerRef, callId: string) => `${convPrefix(ref)}${callId}`;
const titleKey = (title: string | undefined) => (title ?? "").trim().toLowerCase();

/** What a file is, in a line, from its first few KB (the utility model); undefined to leave it without one. */
export type Describe = (file: { name: string; text: string }, origin: LibraryOrigin) => Promise<string | undefined>;

/** Text files whose start says what they are; other files keep only the note they were handed over with. */
const NOTED = new Set(["md", "markdown", "txt", "csv", "tsv", "json", "html", "htm"]);
const NOTES_PER_HOUR = 20;

/**
 * Which utility model writes a note for a file from this conversation (docs/spec/35 §4.2), the way its maker would
 * choose one: an agent's own `models.utility` (on its default model's provider), so `off` means no call at all; a
 * conversation's model otherwise. `null`: write none.
 */
export function noteRequest(agent: { default: string; utility?: string } | undefined, conversationModel?: ModelRef): { model?: ModelRef; choice?: ReturnType<typeof agentUtility>["choice"] } | null {
	if (!agent) return conversationModel ? { model: conversationModel } : {};
	const own = agentUtility(agent.utility);
	if (own.choice === "off") return null;
	const { provider, modelId } = modelOf(agent.default);
	return { model: { provider, id: modelId }, ...own };
}

export const NOTE_PROMPT = `You name files in a list of things an assistant made. Given a file's name and its first lines, answer with one line of at most 12 words that says what it is, specific enough to find it again ("Gas offers from Iberdrola, Naturgy and Repsol, compared"). No quotes, no final period, nothing else.`;

export class Library {
	private data: File;
	/** Writes a note for a new file that came without one (set by the engine; nothing in tests unless given). */
	describe?: Describe;
	private notes: { key: string; origin: LibraryOrigin }[] = [];
	private noting = false;
	private notedAt: number[] = [];
	/** When each open conversation's current turn started (your latest message), for replacing drafts. */
	private readonly turnStart = new Map<string, string>();

	/** A copy of each listed visual's HTML (`<id>.html`), so the app can draw it without opening its conversation. */
	private readonly visualsDir: string;

	constructor(
		private readonly file: string,
		private readonly onChange: () => void = () => {},
	) {
		this.visualsDir = join(dirname(file), "library-visuals");
		this.data = { version: 1, items: [], pins: [], hidden: [] };
		// A broken index is moved aside and rebuilt from conversations; its pins and removals stay in the file moved aside.
		const read = readJsonFile<Partial<File>>(file, () => ({}));
		this.data = { version: 1, items: read.items ?? [], pins: read.pins ?? [], hidden: read.hidden ?? [] };
	}

	/**
	 * A conversation's items (opened, re-read, or backfilled at start). Its visuals are replaced by what it shows now;
	 * files only ever come in (the same file may be handed over from several conversations).
	 */
	observe(origin: LibraryOrigin, items: readonly TimelineItem[]): void {
		const prefix = convPrefix(origin.ref);
		const before = this.data.items.length;
		const keptVisuals = new Set<string>();
		let changed = false;
		const replaced = replacedVisuals(items);
		for (const item of items) {
			if (item.kind !== "tool") continue;
			if (item.tool === "show_visual" && replaced.has(item.id)) continue;
			for (const key of this.take(origin, item)) {
				if (key.startsWith(prefix)) keptVisuals.add(key);
				changed = true;
			}
		}
		this.keepOnly((s) => !s.key.startsWith(prefix) || keptVisuals.has(s.key));
		if (changed || this.data.items.length !== before) this.save();
	}

	/**
	 * One item as it changes in an open conversation. A visual fixed within the same turn takes the place of its draft
	 * (25 §3.4), as `replacedVisuals` decides for a whole conversation: a turn starts at your message.
	 */
	observeItem(origin: LibraryOrigin, item: TimelineItem): void {
		const conv = convPrefix(origin.ref);
		if (item.kind === "user" || item.kind === "agent_msg") {
			this.turnStart.set(conv, item.at);
			return;
		}
		if (item.kind !== "tool") return;
		const fresh = new Set(this.data.items.map((s) => s.key));
		const keys = this.take(origin, item);
		if (!keys.length) return;
		// Files new to the Library, made now (not your history, read at start), get a note when they lack one.
		for (const key of keys) if (!fresh.has(key)) this.noteLater(key, origin);
		const since = this.turnStart.get(conv);
		if (item.tool === "show_visual" && since !== undefined) {
			const title = titleKey(this.data.items.find((s) => s.key === keys[0])?.name);
			this.keepOnly((s) => !(s.key.startsWith(conv) && s.key !== keys[0] && s.at >= since && titleKey(s.name) === title));
		}
		this.save();
	}

	/** Every item you haven't removed, newest first, with what's on disk now. A file missing for 30 days leaves. */
	list(now = Date.now()): { items: LibraryItem[]; pins: string[]; removed: LibraryItem[] } {
		this.sweepMissing(now);
		const hidden = new Set(this.data.hidden);
		const newest = (a: LibraryItem, b: LibraryItem) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0);
		const items = this.data.items.filter((s) => !hidden.has(idOf(s.key))).map((s) => this.view(s)).sort(newest);
		const removed = this.data.items.filter((s) => hidden.has(idOf(s.key))).map((s) => this.view(s)).sort(newest);
		const shown = new Set(items.map((i) => i.id));
		return { items, pins: this.data.pins.filter((id) => shown.has(id)), removed };
	}

	/** Put back: an item you removed comes back where it was (Undo, or the Removed list). */
	restore(id: string): void {
		this.require(id);
		this.data.hidden = this.data.hidden.filter((h) => h !== id);
		this.save();
	}

	/**
	 * Save… on a visual's card wrote it to a file: the visual keeps its conversation and pin, and now has a file too.
	 * A later handover of that file finds the same item.
	 */
	saved(callId: string, path: string): LibraryItem | undefined {
		const s = this.data.items.find((i) => i.kind === "visual" && i.visual?.callId === callId);
		if (!s || !isAbsolute(path)) return undefined;
		s.path = resolve(path);
		const key = fileKey(path);
		s.aliases = [...new Set([...(s.aliases ?? []), key])];
		// A file item for the same path (handed over before, or added) gives way to the visual, keeping its pin.
		const twin = this.data.items.find((i) => i !== s && i.key === key);
		if (twin) {
			const twinId = idOf(twin.key);
			this.data.pins = this.data.pins.map((p) => (p === twinId ? idOf(s.key) : p)).filter((p, i, all) => all.indexOf(p) === i);
			this.data.items = this.data.items.filter((i) => i !== twin);
		}
		this.save();
		return this.view(s);
	}

	/** Pins go on the shelf and under Library in the sidebar; a new pin goes first. */
	pin(id: string, pinned: boolean): void {
		this.require(id);
		this.data.pins = this.data.pins.filter((p) => p !== id);
		if (pinned) this.data.pins.unshift(id);
		this.save();
	}

	reorder(ids: string[]): void {
		const known = new Set(this.data.pins);
		const ordered = ids.filter((id) => known.has(id));
		this.data.pins = [...ordered, ...this.data.pins.filter((id) => !ordered.includes(id))];
		this.save();
	}

	/** Remove from Library: hidden from now on; its file stays where it is. */
	remove(id: string): void {
		this.require(id);
		if (!this.data.hidden.includes(id)) this.data.hidden.push(id);
		this.data.pins = this.data.pins.filter((p) => p !== id);
		this.save();
	}

	/** Add to Library: any file, by hand (it comes back if you'd removed it). */
	add(path: string, origin?: LibraryOrigin): LibraryItem {
		if (!isAbsolute(path)) throw new Error("A full path is needed.");
		if (!existsSync(path)) throw new Error(`No file at ${path}.`);
		const key = fileKey(path);
		this.data.hidden = this.data.hidden.filter((h) => h !== idOf(key));
		this.upsert({ key, kind: kindOf(path), name: basename(path), path: resolve(path), at: new Date().toISOString(), how: "added", by: origin?.by ?? "You", ...(origin ? { origin: originOf(origin) } : {}) });
		this.save();
		return this.view(this.data.items.find((s) => s.key === key)!);
	}

	/** Locate…: a moved file, found again. Its pin and history follow it. */
	relocate(id: string, path: string): LibraryItem {
		const s = this.require(id);
		if (!existsSync(path)) throw new Error(`No file at ${path}.`);
		const key = fileKey(path);
		const newId = idOf(key);
		this.data.items = this.data.items.filter((o) => o.key !== key || o === s);
		if (s.key !== key && s.key.startsWith("file:")) s.aliases = [...new Set([...(s.aliases ?? []), s.key])].filter((a) => a !== key);
		Object.assign(s, { key, path: resolve(path), name: basename(path), ...(s.kind === "visual" ? {} : { kind: kindOf(path) }) });
		delete s.missingSince;
		this.data.pins = this.data.pins.map((p) => (p === id ? newId : p));
		this.save();
		return this.view(s);
	}

	/** A conversation (or an agent, with all of its) was deleted: its visuals go; its files stay listed while they exist. */
	forget(id: string): void {
		const before = this.data.items.length;
		this.keepOnly((s) => !(s.key.startsWith("visual:") && s.key.split(":")[2] === id));
		if (this.data.items.length !== before) this.save();
	}

	/** A listed visual's title and HTML, for its picture and to show it large. */
	visual(id: string): { title: string; html: string } {
		const s = this.require(id);
		if (s.kind !== "visual") throw new Error("That item isn't a visual.");
		const file = join(this.visualsDir, `${id}.html`);
		if (!existsSync(file)) throw new Error("This visual's drawing isn't kept: open its conversation.");
		return { title: s.name, html: readFileSync(file, "utf8") };
	}

	// ── Internals ──────────────────────────────────────────────────────────

	private sweepMissing(now: number): void {
		let changed = false;
		const stamp = new Date(now).toISOString();
		const cutoff = now - MISSING_DAYS * 86_400_000;
		const gone = new Set<string>();
		for (const s of this.data.items) {
			if (!s.path || s.kind === "visual") continue;
			const there = existsSync(s.path);
			if (there && s.missingSince) {
				delete s.missingSince;
				changed = true;
			} else if (!there && !s.missingSince) {
				s.missingSince = stamp;
				changed = true;
			} else if (!there && Date.parse(s.missingSince!) < cutoff) gone.add(s.key);
		}
		if (gone.size) {
			const ids = new Set([...gone].map(idOf));
			this.keepOnly((s) => !gone.has(s.key));
			this.data.pins = this.data.pins.filter((p) => !ids.has(p));
			changed = true;
		}
		if (changed) this.save();
	}

	/** Waits until the queued notes are written (tests). */
	async notesDone(): Promise<void> {
		while (this.noting || this.notes.length) await new Promise((r) => setTimeout(r, 5));
	}

	private noteLater(key: string, origin: LibraryOrigin): void {
		const s = this.data.items.find((i) => i.key === key);
		if (!this.describe || !s?.path || s.note || !NOTED.has(extname(s.path).slice(1).toLowerCase())) return;
		this.notes.push({ key, origin });
		void this.writeNotes();
	}

	/** One at a time, at most 20 an hour; a note that can't be written is simply left out. */
	private async writeNotes(): Promise<void> {
		if (this.noting) return;
		this.noting = true;
		try {
			for (let job = this.notes.shift(); job; job = this.notes.shift()) {
				const now = Date.now();
				this.notedAt = this.notedAt.filter((t) => now - t < 3_600_000);
				if (this.notedAt.length >= NOTES_PER_HOUR) continue;
				const s = this.data.items.find((i) => i.key === job.key);
				if (!s?.path || s.note) continue;
				let text: string;
				try {
					text = readFileSync(s.path, "utf8").slice(0, 3000);
				} catch {
					continue;
				}
				if (!text.trim()) continue;
				this.notedAt.push(now);
				const line = await this.describe!({ name: s.name, text }, job.origin).catch(() => undefined);
				const note = line?.split("\n")[0]?.trim().replace(/^["'“]|["'”]$/g, "").replace(/\.$/, "").slice(0, 160);
				if (note && !s.note) {
					s.note = note;
					this.save();
				}
			}
		} finally {
			this.noting = false;
		}
	}

	/** Items leave the index; their visuals' copies go with them. */
	private keepOnly(keep: (s: Stored) => boolean): void {
		const [kept, gone] = [this.data.items.filter(keep), this.data.items.filter((s) => !keep(s))];
		this.data.items = kept;
		for (const s of gone) if (s.kind === "visual") rmSync(join(this.visualsDir, `${idOf(s.key)}.html`), { force: true });
	}

	/** What one tool call brings in; the keys it added or refreshed. */
	private take(origin: LibraryOrigin, item: Extract<TimelineItem, { kind: "tool" }>): string[] {
		if (item.status !== "done") return [];
		const base = { at: item.at, by: origin.by, origin: originOf(origin) };
		// make_app hands over the app it wrote, as present_files does its files (docs/spec/35 §14).
		if (item.tool === "present_files" || item.tool === "make_app") {
			const files = item.details?.type === "files" ? item.details.files : [];
			return files.flatMap((f) => {
				if ((f as { missing?: boolean }).missing || !f.path || !isAbsolute(f.path)) return [];
				return [this.upsert({ key: fileKey(f.path), kind: kindOf(f.path), name: f.name || basename(f.path), path: resolve(f.path), how: "presented", ...(f.description ? { note: f.description } : {}), ...base })];
			});
		}
		if (item.tool === "show_visual") {
			const title = typeof (item.args as { title?: unknown })?.title === "string" ? ((item.args as { title: string }).title.trim() || "Visual") : "Visual";
			const html = typeof (item.args as { html?: unknown })?.html === "string" ? (item.args as { html: string }).html : "";
			const version = html ? createHash("sha1").update(html).digest("hex").slice(0, 12) : undefined;
			const key = this.upsert({ key: visualKey(origin.ref, item.callId), kind: "visual", name: title, how: "visual", visual: { callId: item.callId, ...(version ? { version } : {}) }, ...base });
			if (html) this.keepVisual(idOf(key), html);
			return [key];
		}
		if (item.tool === "write" && origin.chatFolder) {
			const raw = (item.args as { path?: unknown })?.path;
			if (typeof raw !== "string" || !raw) return [];
			const path = resolve(origin.chatFolder, raw);
			const folder = resolve(origin.chatFolder);
			// Not a file a tool keeps for itself: anything in a hidden folder (.cache/, .piopio/) stays out.
			const hidden = relative(folder, path).split(sep).some((part) => part.startsWith("."));
			if (!path.startsWith(`${folder}/`) || kindOf(path) === "file" || hidden) return [];
			return [this.upsert({ key: fileKey(path), kind: kindOf(path), name: basename(path), path, how: "written", ...base })];
		}
		return [];
	}

	/** By its key, or a path it was known by before Locate…. */
	private find(key: string): Stored | undefined {
		return this.data.items.find((s) => s.key === key) ?? this.data.items.find((s) => s.aliases?.includes(key));
	}

	private keepVisual(id: string, html: string): void {
		const file = join(this.visualsDir, `${id}.html`);
		if (existsSync(file) && readFileSync(file, "utf8") === html) return;
		mkdirSync(this.visualsDir, { recursive: true, mode: 0o700 });
		writeFileSync(file, html, { mode: 0o600 });
	}

	/** The first time decides where it came from; a later handover only adds a note it lacked. Returns the item's key. */
	private upsert(next: Stored): string {
		const had = this.find(next.key) ?? (next.path ? this.data.items.find((s) => s.path === next.path && s.kind !== "visual") : undefined);
		if (!had) {
			this.data.items.push(next);
			return next.key;
		}
		// The conversation was renamed since (a chat's first title is its prompt): the item follows it.
		if (had.origin && next.origin && sameRef(had.origin.ref, next.origin.ref)) had.origin.title = next.origin.title;
		if (next.note && !had.note) had.note = next.note;
		if (next.how === "presented" && had.how === "written") had.how = "presented";
		if (next.kind === "visual") {
			had.name = next.name;
			if (next.visual?.version) had.visual = { ...had.visual!, version: next.visual.version };
		}
		return had.key;
	}

	private require(id: string): Stored {
		const s = this.data.items.find((i) => idOf(i.key) === id);
		if (!s) throw new Error("That item isn't in the Library.");
		return s;
	}

	private view(s: Stored): LibraryItem {
		const id = idOf(s.key);
		const disk = s.path ? stat(s.path) : undefined;
		if (s.kind === "visual" && s.path && !disk) return this.view({ ...s, path: undefined });
		return {
			id,
			kind: s.kind,
			name: s.name,
			at: s.at,
			by: s.by,
			how: s.how,
			...(s.path ? { path: s.path } : {}),
			...(s.note ? { note: s.note } : {}),
			...(s.origin ? { origin: s.origin } : {}),
			...(s.visual ? { visual: s.visual } : {}),
			...(s.path && !disk ? { missing: true } : {}),
			...(disk ? { size: disk.size, changedAt: disk.changedAt } : {}),
			...(this.data.pins.includes(id) ? { pinned: true } : {}),
		};
	}

	private save(): void {
		writeFileAtomic(this.file, JSON.stringify(this.data), { mode: 0o600 });
		this.onChange();
	}
}

const sameRef = (a: ContainerRef, b: ContainerRef) => a.kind === b.kind && a.id === b.id && (a.conversationId ?? "") === (b.conversationId ?? "");

function originOf(o: LibraryOrigin): Stored["origin"] {
	return { ref: o.ref, title: o.title, ...(o.project ? { project: o.project } : {}) };
}

function stat(path: string): { size: number; changedAt: string } | undefined {
	try {
		const s = statSync(path);
		return s.isFile() ? { size: s.size, changedAt: s.mtime.toISOString() } : undefined;
	} catch {
		return undefined;
	}
}

/**
 * Search, with the Library listening: the Library reads the same items search indexes (a whole conversation when it's
 * opened, re-read or backfilled at start; one item as it changes), so it fills itself from history with no pass of its own.
 */
export class LibrarySearch extends SearchIndex {
	constructor(
		file: string,
		private readonly tap: { replaced(key: string, items: readonly TimelineItem[]): void; item(key: string, item: TimelineItem): void; deleted(id: string): void },
	) {
		super(file);
	}

	override replaceSession(sessionId: string, title: string, at: string, items: readonly TimelineItem[]): void {
		if (this.skips(sessionId)) return;
		super.replaceSession(sessionId, title, at, items);
		this.quietly(() => this.tap.replaced(sessionId, items));
	}

	override upsertItem(sessionId: string, item: TimelineItem, replacing?: string): void {
		if (this.skips(sessionId)) return;
		super.upsertItem(sessionId, item, replacing);
		this.quietly(() => this.tap.item(sessionId, item));
	}

	override deleteContainer(id: string): void {
		super.deleteContainer(id);
		this.quietly(() => this.tap.deleted(id));
	}

	/** The Library never breaks search or a conversation. */
	private quietly(f: () => void): void {
		try {
			f();
		} catch {
			// A full disk or a broken index: the item is picked up again at the next start.
		}
	}
}
