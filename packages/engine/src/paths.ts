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
};

/** `PIOPIO_HOME` overrides the data folder (dev, tests). */
export function enginePaths(home = process.env.PIOPIO_HOME ?? join(homedir(), "Library", "Application Support", "Piopio")): EnginePaths {
	return {
		home,
		socket: join(home, "engine.sock"),
		tokenFile: join(home, "engine.token"),
		lockFile: join(home, "engine.lock"),
		catalogIndex: join(home, "sessions.json"),
		projectsIndex: join(home, "projects.json"),
		threadsDir: join(home, "threads"),
		logsDir: join(home, "logs"),
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
