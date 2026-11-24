/** Ports a coding agent's commands serve, for the project preview (docs/spec/22 §6.1; real-use pass F4, 2026-11-24). */
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { descendants, portsServedIn } from "../src/ports.js";

const started: ChildProcess[] = [];
afterEach(() => {
	for (const c of started.splice(0)) c.kill("SIGKILL");
});

/** A server under a shell (as an agent's command runs), listening in `cwd`; resolves with its port. */
function serve(cwd: string): Promise<number> {
	const script = `require("http").createServer(() => {}).listen(0, "127.0.0.1", function () { console.log(this.address().port) })`;
	const child = spawn("/bin/sh", ["-c", `exec "${process.execPath}" -e '${script}'`], { cwd, stdio: ["ignore", "pipe", "inherit"] });
	started.push(child);
	return new Promise((resolve) => child.stdout!.once("data", (d: Buffer) => resolve(Number(d.toString().trim()))));
}

test.skipIf(process.platform !== "darwin")("a server started under this process in the session's folder is the session's; one elsewhere isn't", { timeout: 20_000 }, async () => {
	const project = realpathSync(mkdtempSync(join(tmpdir(), "piopio-ports-")));
	const other = realpathSync(mkdtempSync(join(tmpdir(), "piopio-ports-other-")));
	const mine = await serve(project);
	const theirs = await serve(other);
	expect(await portsServedIn(project)).toEqual([mine]);
	expect(await portsServedIn(other)).toEqual([theirs]);
	// Through a symlinked path too (/var → /private/var on macOS).
	expect(await portsServedIn(project.replace(/^\/private/, ""))).toEqual([mine]);
	// Not under another root: a server you start yourself isn't Piopio's.
	const bystander = spawn("sleep", ["10"]);
	started.push(bystander);
	expect(await portsServedIn(project, bystander.pid!)).toEqual([]);
	expect((await descendants(process.pid)).length).toBeGreaterThanOrEqual(2);
});
