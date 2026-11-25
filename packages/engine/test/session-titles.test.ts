/**
 * A conversation's title is also its pi session's name (pi's own `session_info` entry, what `/name` writes): pi's CLI
 * lists it by that name, and a sync from the file never brings an older title back.
 */
import { mkdtempSync, readFileSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home = mkdtempSync(join(tmpdir(), "piopio-titles-"))): Promise<Ctx> {
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

test("the title from the first message, a rename, and a rename while it's closed all reach pi's session; none counts as activity", async () => {
	let a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-titles-folder-")));
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	/** The session as pi's own listing sees it. */
	const inPi = async () => (await SessionManager.list(folder, join(a.home, "pi-sessions")))[0];
	const title = async () => (await a.client.call("sessions.list", { kind: "build" })).sessions.find((s: { ref: { id: string } }) => s.ref.id === ref.id)!.title as string;

	// The first message titles it; pi's session gets the same name once the answer is in.
	a.engine.hub.faux!.setResponses([fauxAssistantMessage("Done.")]);
	await a.client.call("sessions.submit", { ref, input: { text: "Fix the flaky login test" } });
	await idle(a, ref, (s) => s.items.some((i) => i.kind === "assistant"));
	expect(await title()).toBe("Fix the flaky login test");
	expect((await inPi())?.name).toBe("Fix the flaky login test");

	// A rename while it's open.
	await a.client.call("sessions.rename", { ref, title: "Login test" });
	expect((await inPi())?.name).toBe("Login test");

	// A rename while it's closed (a new engine hasn't opened it): written to the file, whose date stays.
	await stop(a);
	a = await start(a.home);
	const file = (await inPi())!.path;
	const before = statSync(file).mtimeMs;
	// The catalog first takes the file's own date (the last answer's), as any sync does.
	await a.engine.sessions.syncFolder(folder);
	const listed = (await a.client.call("sessions.list", { kind: "build" })).sessions.find((s: { ref: { id: string } }) => s.ref.id === ref.id)!;
	await a.client.call("sessions.rename", { ref, title: "Login, again" });
	expect((await inPi())?.name).toBe("Login, again");
	expect(Math.abs(statSync(file).mtimeMs - before)).toBeLessThan(1);
	// A sync from pi's files leaves it as it is: same title, same place in the list.
	await a.engine.sessions.syncFolder(folder);
	const after = (await a.client.call("sessions.list", { kind: "build" })).sessions.find((s: { ref: { id: string } }) => s.ref.id === ref.id)!;
	expect(after).toMatchObject({ title: "Login, again", updatedAt: listed.updatedAt });

	// Opened again, it still reads and answers (the name entries are not messages).
	a.engine.hub.faux!.setResponses([fauxAssistantMessage("Still here.")]);
	await a.client.call("sessions.submit", { ref, input: { text: "Are you there?" } });
	const s = await idle(a, ref, (x) => x.items.some((i) => i.kind === "assistant" && i.parts.some((p) => p.text === "Still here.")));
	expect(s.items.filter((i) => i.kind === "user").map((i) => (i.kind === "user" ? i.text : ""))).toEqual(["Fix the flaky login test", "Are you there?"]);
}, 30_000);
