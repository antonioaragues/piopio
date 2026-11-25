/**
 * An agent's kept files (docs/spec/06-agents §14): `files/` in its folder, so Reveal in Finder shows them and a file
 * dropped there is the agent's too. `files/.piopio/` holds Piopio's notes on them: `index.json` (each file's note,
 * kind, size, date, who sent it) and what the model reads (`views/<id>.txt`, a PDF's text; `views/<id>.<ext>`, an
 * image at the size it was sent), and files deleted in the last two days (`deleted/<token>/`, for Undo).
 * `files/` is in the folder's `.gitignore`: the definition's history stays about the definition.
 */
import { randomBytes } from "node:crypto";
import { appendFileSync, copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, extname, join } from "node:path";
import type { Attachment } from "@piopio/protocol";
import { READ_CHARS, type AgentFileInfo, type AgentFileRead, type AgentFilesBridge } from "@piopio/runtime";
import type { KeptAttachment } from "./attachment-files.js";
import { readJsonFile, writeFileAtomic } from "./atomic.js";

type Entry = { id: string; note?: string; mimeType?: string; addedAt: string; from?: string; view?: string };
type Index = Record<string, Entry>;

const META = ".piopio";
/** Deleted files stay this long for Undo (it's offered for 24 hours). */
const KEEP_DELETED_MS = 48 * 3600_000;
/** Originals larger than this aren't kept (as for attachments). */
const MAX_BYTES = 100 * 1024 * 1024;
/** An image read from its original (no sent copy) only up to this size. */
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

const IMAGE = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif", ".tif", ".tiff", ".bmp"]);
const SHOWABLE: Record<string, string> = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp" };
const TEXT = new Set([".txt", ".md", ".markdown", ".csv", ".tsv", ".json", ".html", ".htm", ".xml", ".yaml", ".yml", ".toml", ".ics", ".vcf", ".log", ".rtf"]);

export function kindOf(name: string, mimeType?: string): AgentFileInfo["kind"] {
	const ext = extname(name).toLowerCase();
	if (IMAGE.has(ext) || mimeType?.startsWith("image/")) return "image";
	if (ext === ".pdf" || mimeType === "application/pdf") return "pdf";
	if (TEXT.has(ext) || mimeType?.startsWith("text/")) return "text";
	return "other";
}

/** A name safe to keep: no folders, no leading dots, no control characters. */
function safeName(name: string): string {
	const clean = basename(name.replaceAll("\\", "/")).replace(/^\.+/, "").replace(/[\u0000-\u001f/:]/g, "").trim();
	return clean.length > 0 ? clean.slice(0, 200) : "file";
}

export class AgentFileStore implements AgentFilesBridge {
	readonly dir: string;
	private readonly meta: string;

	constructor(
		private readonly folder: string,
		private readonly now: () => Date = () => new Date(),
	) {
		this.dir = join(folder, "files");
		this.meta = join(this.dir, META);
	}

	/** Keeps files sent in a message (or added from the app): their originals, and what the model was shown. */
	keep(attachments: readonly (KeptAttachment | Attachment)[], options: { attachmentsRoot?: string; from?: string } = {}): AgentFileInfo[] {
		if (!attachments.length) return [];
		this.prepare();
		const index = this.index();
		const kept: AgentFileInfo[] = [];
		for (const a of attachments) {
			try {
				const stored = "stored" in a && a.stored && options.attachmentsRoot ? join(options.attachmentsRoot, a.stored) : undefined;
				const original = a.path && existsSync(a.path) && statSync(a.path).isFile() && statSync(a.path).size <= MAX_BYTES ? a.path : stored && existsSync(stored) ? stored : undefined;
				// The name of what's kept: a document's text kept as text gets .txt (attachment-files does the same).
				const name = this.free(safeName(original && original === stored ? basename(stored) : a.name), index);
				const target = join(this.dir, name);
				if (original) copyFileSync(original, target);
				else if (a.kind === "image") writeFileSync(target, Buffer.from(a.data, "base64"));
				else writeFileSync(target, a.text);
				const id = randomBytes(6).toString("hex");
				const kind = kindOf(name, a.mimeType);
				let view: string | undefined;
				// What the model reads later: the image as it was sent (downscaled), a PDF's or document's text.
				if (a.kind === "image" && a.data) {
					view = `views/${id}${sentExt(a.mimeType)}`;
					writeFileSync(join(this.meta, view), Buffer.from(a.data, "base64"));
				} else if (a.kind === "text" && kind !== "text") {
					view = `views/${id}.txt`;
					writeFileSync(join(this.meta, view), a.text);
				}
				index[name] = { id, ...(a.mimeType ? { mimeType: a.mimeType } : {}), addedAt: this.now().toISOString(), ...(options.from ? { from: options.from } : {}), ...(view ? { view } : {}) };
				kept.push(this.info(name, index[name]!));
			} catch {
				// A file that can't be kept is still sent with the message.
			}
		}
		this.save(index);
		return kept;
	}

	async list(): Promise<AgentFileInfo[]> {
		return this.listSync();
	}

	listSync(): AgentFileInfo[] {
		if (!existsSync(this.dir)) return [];
		const index = this.index();
		const names = readdirSync(this.dir).filter((n) => !n.startsWith(".") && statSync(join(this.dir, n)).isFile());
		return names.map((n) => this.info(n, index[n])).sort((a, b) => b.addedAt.localeCompare(a.addedAt) || a.name.localeCompare(b.name));
	}

	async read(name: string, from = 0): Promise<AgentFileRead> {
		const file = this.find(name);
		if (!file) return { error: `No file named ${name}. Your files: ${this.listSync().map((f) => f.name).join(", ") || "none"}.` };
		const entry = this.index()[file.name];
		const path = join(this.dir, file.name);
		const view = entry?.view ? join(this.meta, entry.view) : undefined;
		if (file.kind === "image") {
			if (view && existsSync(view)) return { image: { data: readFileSync(view).toString("base64"), mimeType: SHOWABLE[extname(view).toLowerCase()] ?? "image/jpeg" } };
			const mimeType = SHOWABLE[extname(file.name).toLowerCase()];
			if (mimeType && file.size <= MAX_IMAGE_BYTES) return { image: { data: readFileSync(path).toString("base64"), mimeType } };
			return { error: `${file.name} can't be shown to you from here (${mimeType ? "too large" : "its format"}). Ask your owner to send it in your chat.` };
		}
		const source = view && existsSync(view) ? view : file.kind === "text" ? path : undefined;
		if (!source) return { error: file.kind === "pdf" ? `No text is kept for ${file.name} (it was put in the folder, not sent). Ask your owner to send it in your chat or add it in your Files.` : `${file.name} isn't text or an image, so you can't read it.` };
		const text = readFileSync(source, "utf8");
		return { text: text.slice(from, from + READ_CHARS), total: text.length };
	}

	async note(name: string, change: { note?: string; rename?: string }): Promise<AgentFileInfo> {
		const file = this.find(name);
		if (!file) throw new Error(`No file named ${name}.`);
		const index = this.index();
		const entry: Entry = index[file.name] ?? { id: randomBytes(6).toString("hex"), addedAt: file.addedAt };
		let target = file.name;
		if (change.rename) {
			const ext = extname(file.name);
			let wanted = safeName(change.rename);
			if (extname(wanted).toLowerCase() !== ext.toLowerCase()) wanted += ext;
			if (wanted !== file.name) {
				target = this.free(wanted, index);
				renameSync(join(this.dir, file.name), join(this.dir, target));
				delete index[file.name];
			}
		}
		if (change.note !== undefined) {
			const note = change.note.trim();
			if (note) entry.note = note;
			else delete entry.note;
		}
		index[target] = entry;
		this.save(index);
		return this.info(target, entry);
	}

	async remove(name: string): Promise<{ token: string; file: AgentFileInfo }> {
		const file = this.find(name);
		if (!file) throw new Error(`No file named ${name}.`);
		this.purge();
		const index = this.index();
		const token = randomBytes(8).toString("hex");
		const dir = join(this.meta, "deleted", token);
		mkdirSync(dir, { recursive: true });
		renameSync(join(this.dir, file.name), join(dir, file.name));
		writeFileSync(join(dir, "entry.json"), JSON.stringify({ name: file.name, entry: index[file.name] ?? null, at: this.now().toISOString() }));
		delete index[file.name];
		this.save(index);
		return { token, file };
	}

	async restore(token: string): Promise<void> {
		const dir = join(this.meta, "deleted", token.replace(/[^a-f0-9]/g, ""));
		if (!existsSync(join(dir, "entry.json"))) throw new Error("That file is gone for good.");
		const { name, entry } = JSON.parse(readFileSync(join(dir, "entry.json"), "utf8")) as { name: string; entry: Entry | null };
		const index = this.index();
		const target = this.free(name, index);
		renameSync(join(dir, name), join(this.dir, target));
		if (entry) index[target] = entry;
		this.save(index);
		rmSync(dir, { recursive: true, force: true });
	}

	/** A file by name, or by name ignoring case. */
	private find(name: string): AgentFileInfo | undefined {
		const files = this.listSync();
		return files.find((f) => f.name === name) ?? files.find((f) => f.name.toLowerCase() === name.trim().toLowerCase());
	}

	private info(name: string, entry: Entry | undefined): AgentFileInfo {
		const path = join(this.dir, name);
		const st = statSync(path);
		const kind = kindOf(name, entry?.mimeType);
		const view = entry?.view ? join(this.meta, entry.view) : undefined;
		const readable = kind === "text" || (view !== undefined && existsSync(view)) || (kind === "image" && Boolean(SHOWABLE[extname(name).toLowerCase()]) && st.size <= MAX_IMAGE_BYTES);
		return { name, ...(entry?.note ? { note: entry.note } : {}), kind, size: st.size, addedAt: entry?.addedAt ?? st.mtime.toISOString(), path, readable };
	}

	/** `name`, or `name 2.ext`, `name 3.ext`… when it's taken. */
	private free(name: string, index: Index): string {
		const ext = extname(name);
		const stem = name.slice(0, name.length - ext.length);
		let candidate = name;
		for (let i = 2; existsSync(join(this.dir, candidate)) || index[candidate]; i++) candidate = `${stem} ${i}${ext}`;
		return candidate;
	}

	private prepare(): void {
		mkdirSync(join(this.meta, "views"), { recursive: true, mode: 0o700 });
		ignoreFiles(this.folder);
	}

	private index(): Index {
		return readJsonFile<Index>(join(this.meta, "index.json"), () => ({}));
	}

	private save(index: Index): void {
		mkdirSync(this.meta, { recursive: true, mode: 0o700 });
		// Entries for files that are gone (deleted in Finder) go too.
		for (const name of Object.keys(index)) if (!existsSync(join(this.dir, name))) delete index[name];
		writeFileAtomic(join(this.meta, "index.json"), `${JSON.stringify(index, null, 2)}\n`);
	}

	/** Deleted files past their Undo go. */
	private purge(): void {
		const root = join(this.meta, "deleted");
		if (!existsSync(root)) return;
		for (const token of readdirSync(root)) {
			const dir = join(root, token);
			try {
				const { at } = JSON.parse(readFileSync(join(dir, "entry.json"), "utf8")) as { at: string };
				if (this.now().getTime() - Date.parse(at) > KEEP_DELETED_MS) rmSync(dir, { recursive: true, force: true });
			} catch {
				rmSync(dir, { recursive: true, force: true });
			}
		}
	}
}

/** The extension for an image as it was sent. */
function sentExt(mimeType: string): string {
	return Object.entries(SHOWABLE).find(([, m]) => m === mimeType)?.[0] ?? ".jpg";
}

/** `files/` stays out of the definition's git history. */
export function ignoreFiles(folder: string): void {
	const file = join(folder, ".gitignore");
	const current = existsSync(file) ? readFileSync(file, "utf8") : "";
	if (current.split("\n").some((l) => l.trim() === "files/" || l.trim() === "/files/")) return;
	appendFileSync(file, `${current && !current.endsWith("\n") ? "\n" : ""}files/\n`);
}
