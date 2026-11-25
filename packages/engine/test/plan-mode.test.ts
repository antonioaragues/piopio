/**
 * Plan mode is kept in the pi session, as an entry of its own (extensions/src/plan.ts): it follows the branch you're
 * on, survives a restart from the file alone, and can be set on a conversation that isn't open.
 */
import { mkdtempSync, readFileSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { PLAN_ENTRY, planFrom } from "@piopio/pi-extensions";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home = mkdtempSync(join(tmpdir(), "piopio-plan-"))): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	const ctx = { home, engine, client };
	open.push(ctx);
	return ctx;
}

async function stop(ctx: Ctx) {
	ctx.client.close();
	await ctx.engine.stop();
	open.splice(open.indexOf(ctx), 1);
}

afterEach(async () => {
	for (const ctx of [...open]) await stop(ctx);
});

async function idle(a: Ctx, ref: unknown, until: (s: Snapshot) => boolean = () => true): Promise<Snapshot> {
	for (let i = 0; i < 200; i++) {
		const s: Snapshot = await a.client.call("sessions.open", { ref });
		if (s.state.status === "idle" && until(s)) return s;
		await new Promise((r) => setTimeout(r, 50));
	}
	throw new Error("the session didn't settle");
}

test("plan mode is in the session's entries: it follows the branch, comes back after a restart, and is set on a closed conversation", async () => {
	let a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-plan-folder-")));
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	const turn = async (text: string, answer: string) => {
		a.engine.hub.faux!.setResponses([fauxAssistantMessage(answer)]);
		await a.client.call("sessions.submit", { ref, input: { text } });
		return idle(a, ref, (s) => s.items.some((i) => i.kind === "assistant" && i.parts.some((p) => p.text === answer)));
	};
	const file = async () => (await SessionManager.list(folder, join(a.home, "pi-sessions")))[0]!.path;
	/** What pi's own session says, read from the file. */
	const inFile = async () => planFrom(SessionManager.open(await file()).getBranch() as never);
	const shown = async () => ((await a.client.call("sessions.open", { ref })) as Snapshot).state.planMode;

	await turn("First", "One.");
	const second = await turn("Second", "Two.");
	expect(await shown()).toBe(false);
	expect(await inFile()).toBeUndefined();

	// Turned on after the second answer: an entry at the tip of the session.
	await a.client.call("sessions.configure", { ref, planMode: true });
	expect(await shown()).toBe(true);
	expect(await inFile()).toBe(true);

	// Back to before the second message: on that branch it was never turned on.
	const users = second.items.filter((i) => i.kind === "user");
	await a.client.call("sessions.rewind", { ref, itemId: users[1]!.id, files: false });
	expect(await shown()).toBe(false);

	// On again here, then a restart: the new engine reads it from the file (the catalog doesn't hold it).
	await a.client.call("sessions.configure", { ref, planMode: true });
	await stop(a);
	a = await start(a.home);
	expect(readFileSync(enginePaths(a.home).catalogIndex, "utf8")).not.toContain('"planMode"');
	expect(await shown()).toBe(true);

	// Turned off while it's closed: written to the file, whose date stays.
	await stop(a);
	a = await start(a.home);
	const before = statSync(await file()).mtimeMs;
	await a.client.call("sessions.configure", { ref, planMode: false });
	expect(SessionManager.open(await file()).getBranch().filter((e) => e.type === "custom" && e.customType === PLAN_ENTRY).at(-1)).toMatchObject({ data: { on: false } });
	expect(Math.abs(statSync(await file()).mtimeMs - before)).toBeLessThan(1);
	expect(await shown()).toBe(false);
}, 30_000);
