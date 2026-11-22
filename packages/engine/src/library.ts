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
import { existsSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, extname, isAbsolute, resolve } from "node:path";
import type { ContainerRef, LibraryItem, LibraryKind, TimelineItem } from "@piopio/protocol";
import { SearchIndex } from "./search.js";
import { replacedVisuals } from "./tools/visuals.js";

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
	visual?: { callId: string };
};

type File = { version: 1; items: Stored[]; pins: string[]; hidden: string[] };

const KINDS: Record<string, LibraryKind> = {
	md: "document", markdown: "document", txt: "document", pdf: "document", docx: "document", doc: "document", rtf: "document", pages: "document",
	html: "page", htm: "page", xhtml: "page",
	png: "image", jpg: "image", jpeg: "image", gif: "image", webp: "image", svg: "image", heic: "image",
	csv: "data", tsv: "data", json: "data", xlsx: "data", xls: "data", numbers: "data",
	pptx: "slides", key: "slides",
};

/** What a file is, by its extension; `file` for anything else (only listed when handed over or added). */
export function kindOf(path: string): LibraryKind {
	return KINDS[extname(path).slice(1).toLowerCase()] ?? "file";
}

const idOf = (key: string) => createHash("sha1").update(key).digest("hex").slice(0, 16);
const fileKey = (path: string) => `file:${resolve(path)}`;
const convPrefix = (ref: ContainerRef) => `visual:${ref.kind}:${ref.id}:${ref.conversationId ?? ""}:`;
const visualKey = (ref: ContainerRef, callId: string) => `${convPrefix(ref)}${callId}`;
const titleKey = (title: string | undefined) => (title ?? "").trim().toLowerCase();

export class Library {
	private data: File;
	/** When each open conversation's current turn started (your latest message), for replacing drafts. */
	private readonly turnStart = new Map<string, string>();

	constructor(
		private readonly file: string,
		private readonly onChange: () => void = () => {},
	) {
		this.data = { version: 1, items: [], pins: [], hidden: [] };
		if (existsSync(file)) {
			try {
				const read = JSON.parse(readFileSync(file, "utf8")) as Partial<File>;
				this.data = { version: 1, items: read.items ?? [], pins: read.pins ?? [], hidden: read.hidden ?? [] };
			} catch {
				// A broken index is rebuilt from conversations at the next start; pins and removals are lost.
			}
		}
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
		this.data.items = this.data.items.filter((s) => !s.key.startsWith(prefix) || keptVisuals.has(s.key));
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
		const keys = this.take(origin, item);
		if (!keys.length) return;
		const since = this.turnStart.get(conv);
		if (item.tool === "show_visual" && since !== undefined) {
			const title = titleKey(this.data.items.find((s) => s.key === keys[0])?.name);
			this.data.items = this.data.items.filter((s) => !(s.key.startsWith(conv) && s.key !== keys[0] && s.at >= since && titleKey(s.name) === title));
		}
		this.save();
	}

	/** Every item you haven't removed, newest first, with what's on disk now. */
	list(): { items: LibraryItem[]; pins: string[] } {
		const hidden = new Set(this.data.hidden);
		const items = this.data.items
			.filter((s) => !hidden.has(idOf(s.key)))
			.map((s) => this.view(s))
			.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
		const shown = new Set(items.map((i) => i.id));
		return { items, pins: this.data.pins.filter((id) => shown.has(id)) };
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
		Object.assign(s, { key, path: resolve(path), name: basename(path), kind: kindOf(path) });
		this.data.pins = this.data.pins.map((p) => (p === id ? newId : p));
		this.save();
		return this.view(s);
	}

	/** A conversation (or an agent, with all of its) was deleted: its visuals go; its files stay listed while they exist. */
	forget(id: string): void {
		const before = this.data.items.length;
		this.data.items = this.data.items.filter((s) => !(s.key.startsWith("visual:") && s.key.split(":")[2] === id));
		if (this.data.items.length !== before) this.save();
	}

	// ── Internals ──────────────────────────────────────────────────────────

	/** What one tool call brings in; the keys it added or refreshed. */
	private take(origin: LibraryOrigin, item: Extract<TimelineItem, { kind: "tool" }>): string[] {
		if (item.status !== "done") return [];
		const base = { at: item.at, by: origin.by, origin: originOf(origin) };
		if (item.tool === "present_files") {
			const files = item.details?.type === "files" ? item.details.files : [];
			return files.flatMap((f) => {
				if ((f as { missing?: boolean }).missing || !f.path || !isAbsolute(f.path)) return [];
				const key = fileKey(f.path);
				this.upsert({ key, kind: kindOf(f.path), name: f.name || basename(f.path), path: resolve(f.path), how: "presented", ...(f.description ? { note: f.description } : {}), ...base });
				return [key];
			});
		}
		if (item.tool === "show_visual") {
			const title = typeof (item.args as { title?: unknown })?.title === "string" ? ((item.args as { title: string }).title.trim() || "Visual") : "Visual";
			const key = visualKey(origin.ref, item.callId);
			this.upsert({ key, kind: "visual", name: title, how: "visual", visual: { callId: item.callId }, ...base });
			return [key];
		}
		if (item.tool === "write" && origin.chatFolder) {
			const raw = (item.args as { path?: unknown })?.path;
			if (typeof raw !== "string" || !raw) return [];
			const path = resolve(origin.chatFolder, raw);
			const folder = resolve(origin.chatFolder);
			if (!path.startsWith(`${folder}/`) || kindOf(path) === "file" || basename(path).startsWith(".")) return [];
			const key = fileKey(path);
			this.upsert({ key, kind: kindOf(path), name: basename(path), path, how: "written", ...base });
			return [key];
		}
		return [];
	}

	/** The first time decides where it came from; a later handover only adds a note it lacked. */
	private upsert(next: Stored): void {
		const had = this.data.items.find((s) => s.key === next.key);
		if (!had) {
			this.data.items.push(next);
			return;
		}
		// The conversation was renamed since (a chat's first title is its prompt): the item follows it.
		if (had.origin && next.origin && sameRef(had.origin.ref, next.origin.ref)) had.origin.title = next.origin.title;
		if (next.note && !had.note) had.note = next.note;
		if (next.how === "presented" && had.how === "written") had.how = "presented";
		if (next.kind === "visual") had.name = next.name;
	}

	private require(id: string): Stored {
		const s = this.data.items.find((i) => idOf(i.key) === id);
		if (!s) throw new Error("That item isn't in the Library.");
		return s;
	}

	private view(s: Stored): LibraryItem {
		const id = idOf(s.key);
		const disk = s.path ? stat(s.path) : undefined;
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
		const tmp = `${this.file}.tmp`;
		writeFileSync(tmp, JSON.stringify(this.data), { mode: 0o600 });
		renameSync(tmp, this.file);
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
		super.replaceSession(sessionId, title, at, items);
		this.quietly(() => this.tap.replaced(sessionId, items));
	}

	override upsertItem(sessionId: string, item: TimelineItem, replacing?: string): void {
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
