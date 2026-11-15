/**
 * Chats from before 2026-11-15 (pi-durable SQLite) move to pi sessions when the engine starts. The fixture was made with
 * the old ThreadRuntime: a message with a text file and an image (kept copies aa11/notes.md, bb22/shot.png), a second
 * message edited into a second version (the one shown), and `/greet Ana`, which the engine expanded before sending.
 */
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home: string): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	const ctx = { engine, client };
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

const ref = { kind: "thread" as const, id: "thr_legacy" };

async function idle(a: Ctx, until: (s: Snapshot) => boolean = () => true): Promise<Snapshot> {
	for (let i = 0; i < 200; i++) {
		const s: Snapshot = await a.client.call("sessions.open", { ref });
		if (s.state.status === "idle" && until(s)) return s;
		await new Promise((r) => setTimeout(r, 50));
	}
	throw new Error("the chat didn't settle");
}

const lines = (s: Snapshot) => s.items.flatMap((i) => (i.kind === "user" ? [`> ${i.text}`] : i.kind === "assistant" ? [i.parts.map((p) => p.text).join("")] : []));

test("an old chat moves to the new engine: the branch it showed, its files as chips, its /command as typed", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-migrate-"));
	const sqlite = join(home, "threads", "thr_legacy.sqlite");
	mkdirSync(join(home, "threads"), { recursive: true });
	copyFileSync(fileURLToPath(new URL("./fixtures/legacy-chat.sqlite", import.meta.url)), sqlite);
	const now = "2026-11-14T10:00:00.000Z";
	writeFileSync(join(home, "sessions.json"), JSON.stringify([{ ref, title: "Kitchen", createdAt: now, updatedAt: now, model: { provider: "faux", id: "faux-1" }, file: sqlite, branches: { active: "16", activity: {} } }]));

	let a = await start(home);
	let s = await idle(a);
	expect(lines(s)).toEqual([
		"> Read this",
		expect.stringContaining("The sink moves 40 cm left."),
		"> second, edited",
		"Echo: second, edited",
		"> /greet Ana",
		"Echo: Say hello warmly to Ana.",
	]);
	expect(s.items.find((i) => i.kind === "user")).toMatchObject({
		attachments: [
			{ name: "notes.md", kind: "text", stored: "aa11/notes.md" },
			{ name: "shot.png", kind: "image", mimeType: "image/png", stored: "bb22/shot.png" },
		],
	});
	// The old file stays as it was; the chat now has a pi session of its own.
	expect(existsSync(sqlite)).toBe(true);
	const [entry] = JSON.parse(readFileSync(join(home, "sessions.json"), "utf8"));
	expect(entry).toMatchObject({ migratedFrom: sqlite, sessionFile: expect.stringContaining(join(home, "chats")) });
	expect(entry.file).toBeUndefined();
	const listed = (await a.client.call("sessions.list", {})).sessions[0];
	expect(listed).toMatchObject({ ref, title: "Kitchen" });
	expect(listed.cwd).toBeUndefined();

	// It goes on as any chat, and stays moved after a restart.
	await a.client.call("sessions.submit", { ref, input: { text: "after the move" } });
	s = await idle(a, (x) => lines(x).includes("Echo: after the move"));
	await stop(a);
	a = await start(home);
	s = await idle(a);
	expect(lines(s).slice(-2)).toEqual(["> after the move", "Echo: after the move"]);
	expect(lines(s)).toHaveLength(8);

	// Deleting it removes the old file too.
	await a.client.call("sessions.delete", { ref });
	expect(existsSync(sqlite)).toBe(false);
	expect(existsSync(entry.sessionFile)).toBe(false);
}, 30_000);
