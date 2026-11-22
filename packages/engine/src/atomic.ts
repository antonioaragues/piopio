/**
 * Writes that a crash can't leave half done: the new contents go to a temporary file beside the target, reach the disk,
 * and then replace the target in one rename. A store written in place and cut off mid-write was empty or truncated JSON
 * on the next start.
 */
import { closeSync, existsSync, fsyncSync, openSync, readFileSync, renameSync, rmSync, writeSync } from "node:fs";

let seq = 0;

export function writeFileAtomic(path: string, data: string | Uint8Array, options: { mode?: number } = {}): void {
	const tmp = `${path}.${process.pid}.${++seq}.tmp`;
	try {
		const fd = openSync(tmp, "w", options.mode ?? 0o644);
		try {
			writeSync(fd, typeof data === "string" ? Buffer.from(data) : data);
			fsyncSync(fd);
		} finally {
			closeSync(fd);
		}
		renameSync(tmp, path);
	} catch (error) {
		rmSync(tmp, { force: true });
		throw error;
	}
}

/**
 * A JSON file read at startup, or `fallback` when there's none. One that doesn't parse is moved aside
 * (`<file>.corrupt-<time>`, for the user or support to recover) and the engine starts without it: thrown, it stopped
 * every start in a loop; reset in place, the next save wrote over what was left.
 */
export function readJsonFile<T>(file: string, fallback: () => T): T {
	if (!existsSync(file)) return fallback();
	const text = readFileSync(file, "utf8");
	try {
		return JSON.parse(text) as T;
	} catch (error) {
		const aside = `${file}.corrupt-${new Date().toISOString().replace(/[:.]/g, "-")}`;
		renameSync(file, aside);
		process.stderr.write(`piopio-engine: ${file} didn't parse (${(error as Error).message}); moved it to ${aside} and started without it\n`);
		return fallback();
	}
}
