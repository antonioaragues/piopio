/**
 * Reading an app's file sources (docs/spec/35 §3.2): where a source's file is, its data as the page gets it, and a
 * small CSV/TSV parser. A file that's gone, empty, too big, unparseable or missing a column says why.
 */
import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, isAbsolute, resolve } from "node:path";
import { credentialAt } from "@piopio/pi-extensions";
import { MAX_SOURCE_BYTES } from "./app-manifest.js";

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
	// Keys and credentials, wherever a symlink makes them look like they are: never an app's data.
	const secret = credentialAt(path, { home: homedir() });
	if (secret) return { error: `${name} is a key or credentials file (in ${secret.label}), which apps don't read.` };
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
