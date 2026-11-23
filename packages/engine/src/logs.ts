/**
 * `logs/engine.log`: what the engine writes to stderr, opened by whoever starts it (the app, or the LaunchAgent's
 * launcher), both in append mode. It grew without end, so it's rotated in place: past `max` bytes its contents move to
 * `engine.log.1` (replacing the one before) and it starts empty again. In place, because the open file is the
 * engine's own stderr; the writers append, so they carry on at its new end.
 */
import { copyFileSync, existsSync, statSync, truncateSync } from "node:fs";

/** 10 MB: weeks of ordinary use, and a size TextEdit still opens. */
export const LOG_MAX_BYTES = 10 * 1024 * 1024;

/** Rotates `file` when it's over `max`; true when it did. Never throws: a log that can't rotate keeps growing. */
export function rotateLog(file: string, max = LOG_MAX_BYTES): boolean {
	try {
		if (!existsSync(file) || statSync(file).size <= max) return false;
		copyFileSync(file, `${file}.1`);
		truncateSync(file, 0);
		return true;
	} catch {
		return false;
	}
}

/** One log line, with when it was written (they had no time at all). */
export function logLine(line: string, now = new Date()): string {
	return `${now.toISOString()} ${line}\n`;
}
