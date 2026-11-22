/**
 * One engine per data folder. `engine.lock` holds the pid of the engine that has the folder, from before it opens any
 * of its files until it exits; a second engine stops before touching anything. (The socket alone came too late: the
 * second engine had already opened its databases and run its migrations by the time `listen` found the first.)
 */
import { closeSync, openSync, readFileSync, statSync, unlinkSync, writeSync } from "node:fs";
import { createConnection } from "node:net";

/** A lock this old, with nobody answering on the socket, is a previous engine's (its pid reused since). */
const STARTUP_MS = 2 * 60_000;

/** Whether an engine answers on `socket`. */
export function socketAnswers(socket: string): Promise<boolean> {
	return new Promise((resolve) => {
		const s = createConnection(socket);
		s.once("connect", () => (s.destroy(), resolve(true)));
		s.once("error", () => resolve(false));
	});
}

function running(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

/**
 * Takes the folder's lock, or throws when another engine has it. Returns the release, which only removes a lock that is
 * still this process's.
 */
export async function acquireEngineLock(lockFile: string, socket: string, pid = process.pid): Promise<() => void> {
	for (let attempt = 0; attempt < 2; attempt++) {
		try {
			const fd = openSync(lockFile, "wx", 0o600);
			writeSync(fd, `${pid}\n`);
			closeSync(fd);
			return () => {
				try {
					if (Number(readFileSync(lockFile, "utf8").trim()) === pid) unlinkSync(lockFile);
				} catch {
					// Already gone.
				}
			};
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
		}
		let holder = Number.NaN;
		let age = 0;
		try {
			holder = Number(readFileSync(lockFile, "utf8").trim());
			age = Date.now() - statSync(lockFile).mtimeMs;
		} catch {
			continue; // Released meanwhile: try again.
		}
		const held = Number.isInteger(holder) && holder > 0 && holder !== pid && running(holder) && (age < STARTUP_MS || (await socketAnswers(socket)));
		if (held) throw new Error(`Another engine (pid ${holder}) is already running on this data folder`);
		try {
			unlinkSync(lockFile);
		} catch {
			// Someone else cleared it first; the exclusive create decides.
		}
	}
	throw new Error("Another engine is starting on this data folder");
}
