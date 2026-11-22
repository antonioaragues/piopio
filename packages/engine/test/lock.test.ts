import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { acquireEngineLock } from "../src/lock.js";

test("one engine per data folder: a second one stops, a dead or reused pid's lock is taken over", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-lock-"));
	const lock = join(home, "engine.lock");
	const socket = join(home, "engine.sock");

	const release = await acquireEngineLock(lock, socket);
	expect(readFileSync(lock, "utf8").trim()).toBe(String(process.pid));
	// Another process holds it now (this test's pid stands in for a live engine that is still starting).
	await expect(acquireEngineLock(lock, socket, process.pid + 100_000)).rejects.toThrow(/already running/);
	release();
	expect(existsSync(lock)).toBe(false);

	// A crashed engine's lock: its pid is gone.
	const gone = spawn(process.execPath, ["-e", ""]);
	await new Promise((resolve) => gone.on("exit", resolve));
	writeFileSync(lock, `${gone.pid}\n`);
	(await acquireEngineLock(lock, socket))();

	// An old lock whose pid is alive again (reused after a restart) but nobody answers on the socket.
	const reused = spawn(process.execPath, ["-e", "setTimeout(() => {}, 10000)"]);
	writeFileSync(lock, `${reused.pid}\n`);
	await expect(acquireEngineLock(lock, socket)).rejects.toThrow(/already running/);
	const old = (Date.now() - 10 * 60_000) / 1000;
	utimesSync(lock, old, old);
	const mine = await acquireEngineLock(lock, socket);
	expect(readFileSync(lock, "utf8").trim()).toBe(String(process.pid));
	mine();
	reused.kill();
});
