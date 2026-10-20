/**
 * Space files (docs/spec/04-chat §3.2): knowledge files in `spaces/<id>/files/`, which the organizer and the topics
 * read through `space_files_*`. PDFs and other documents keep a text copy that the app extracted, next to them as
 * `.<name>.txt`.
 */
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { EngineError } from "../models.js";

export type SpaceFile = { name: string; size: number; addedAt: string };

const MAX_READ = 60_000;

export class SpaceFiles {
	constructor(private readonly dir: string) {}

	list(): SpaceFile[] {
		if (!existsSync(this.dir)) return [];
		return readdirSync(this.dir)
			.filter((n) => !n.startsWith("."))
			.map((name) => {
				const s = statSync(join(this.dir, name));
				return { name, size: s.size, addedAt: s.birthtime.toISOString() };
			})
			.sort((a, b) => a.name.localeCompare(b.name));
	}

	/** Copies a file in (or writes `text` as a new note). `extracted` is the text of a document the app read. */
	add(file: { name: string; path?: string; text?: string; extracted?: string }): SpaceFile {
		const name = basename(file.name).replace(/^\.+/, "").trim();
		if (!name) throw new EngineError("INVALID", "The file needs a name.");
		if (!file.path === (file.text === undefined)) throw new EngineError("INVALID", "Give a path or the text.");
		mkdirSync(this.dir, { recursive: true });
		const target = join(this.dir, name);
		if (file.path) {
			if (!existsSync(file.path)) throw new EngineError("NOT_FOUND", `No file ${file.path}`);
			copyFileSync(file.path, target);
		} else {
			writeFileSync(target, file.text!);
		}
		if (file.extracted !== undefined) writeFileSync(this.sidecar(name), file.extracted);
		else rmSync(this.sidecar(name), { force: true });
		return this.list().find((f) => f.name === name)!;
	}

	remove(name: string): void {
		const target = join(this.dir, basename(name));
		if (!existsSync(target)) throw new EngineError("NOT_FOUND", `No file ${name}`);
		rmSync(target);
		rmSync(this.sidecar(basename(name)), { force: true });
	}

	/** A file's text: the extracted copy, else the file itself when it is text. */
	read(name: string): string {
		const file = basename(name);
		const target = join(this.dir, file);
		if (!existsSync(target)) throw new EngineError("NOT_FOUND", `No file “${name}”. Files: ${this.list().map((f) => f.name).join(", ") || "none"}.`);
		const source = existsSync(this.sidecar(file)) ? this.sidecar(file) : target;
		const buffer = readFileSync(source);
		if (buffer.subarray(0, 8000).includes(0)) throw new EngineError("INVALID", `${file} isn't text, and has no text copy.`);
		const text = buffer.toString("utf8");
		return text.length > MAX_READ ? `${text.slice(0, MAX_READ)}\n[… cut at ${MAX_READ} characters]` : text;
	}

	/** Lines that contain `query`, with the file name and line number. */
	search(query: string, limit = 30): string[] {
		const q = query.trim().toLowerCase();
		if (!q) return [];
		const hits: string[] = [];
		for (const f of this.list()) {
			let text: string;
			try {
				text = this.read(f.name);
			} catch {
				continue;
			}
			text.split("\n").forEach((line, i) => {
				if (hits.length < limit && line.toLowerCase().includes(q)) hits.push(`${f.name}:${i + 1}: ${line.trim().slice(0, 200)}`);
			});
		}
		return hits;
	}

	private sidecar(name: string): string {
		return join(this.dir, `.${name}.txt`);
	}
}
