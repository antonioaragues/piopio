import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

export type EnginePaths = {
	home: string;
	socket: string;
	tokenFile: string;
	lockFile: string;
	catalogIndex: string;
	projectsIndex: string;
	/** Chats from before 2026-11-15 (pi-durable SQLite files), kept after they moved to `chatsDir`. */
	threadsDir: string;
	/** Chats' pi session files (one engine for conversations, 2026-11-15). */
	chatsDir: string;
	/** Each chat's own folder, where its pi session runs (empty: chats have no file tools). */
	scratchDir: string;
	logsDir: string;
	/** Where New project makes its folders (docs/spec/18 CF4): ~/Piopio, or inside `home` when it isn't the default. */
	projectsRoot: string;
};

const DEFAULT_HOME = join(homedir(), "Library", "Application Support", "Piopio");

/** `PIOPIO_HOME` overrides the data folder (dev, tests). */
export function enginePaths(home = process.env.PIOPIO_HOME ?? DEFAULT_HOME): EnginePaths {
	return {
		home,
		socket: join(home, "engine.sock"),
		tokenFile: join(home, "engine.token"),
		lockFile: join(home, "engine.lock"),
		catalogIndex: join(home, "sessions.json"),
		projectsIndex: join(home, "projects.json"),
		threadsDir: join(home, "threads"),
		chatsDir: join(home, "chats"),
		scratchDir: join(home, "scratch"),
		logsDir: join(home, "logs"),
		// A test copy (another PIOPIO_HOME) keeps its project folders with its data, not in the user's ~/Piopio.
		projectsRoot: process.env.PIOPIO_PROJECTS_DIR ?? (home === DEFAULT_HOME ? join(homedir(), "Piopio") : join(home, "Piopio")),
	};
}

/** The data folders, only yours (0700): `mode` applies only to a folder mkdir makes, and the app may have made them first. */
export function ensureDirs(paths: EnginePaths): void {
	for (const dir of [paths.home, paths.chatsDir, paths.scratchDir, paths.logsDir]) {
		mkdirSync(dir, { recursive: true, mode: 0o700 });
		chmodSync(dir, 0o700);
	}
}

/** Reads the shared engine token, creating it (0600) on first run. */
export function loadOrCreateToken(paths: EnginePaths): string {
	if (existsSync(paths.tokenFile)) return readFileSync(paths.tokenFile, "utf8").trim();
	const token = randomBytes(32).toString("hex");
	writeFileSync(paths.tokenFile, `${token}\n`, { mode: 0o600 });
	chmodSync(paths.tokenFile, 0o600);
	return token;
}
