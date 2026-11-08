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
	threadsDir: string;
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
		logsDir: join(home, "logs"),
		// A test copy (another PIOPIO_HOME) keeps its project folders with its data, not in the user's ~/Piopio.
		projectsRoot: process.env.PIOPIO_PROJECTS_DIR ?? (home === DEFAULT_HOME ? join(homedir(), "Piopio") : join(home, "Piopio")),
	};
}

export function ensureDirs(paths: EnginePaths): void {
	for (const dir of [paths.home, paths.threadsDir, paths.logsDir]) mkdirSync(dir, { recursive: true, mode: 0o700 });
}

/** Reads the shared engine token, creating it (0600) on first run. */
export function loadOrCreateToken(paths: EnginePaths): string {
	if (existsSync(paths.tokenFile)) return readFileSync(paths.tokenFile, "utf8").trim();
	const token = randomBytes(32).toString("hex");
	writeFileSync(paths.tokenFile, `${token}\n`, { mode: 0o600 });
	chmodSync(paths.tokenFile, 0o600);
	return token;
}
