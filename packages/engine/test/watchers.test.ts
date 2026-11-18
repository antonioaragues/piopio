import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Watch } from "@piopio/runtime";
import { expect, test } from "vitest";
import { AgentWatchers, matches } from "../src/watchers.js";

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 10_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 500)}`);
		await new Promise((r) => setTimeout(r, 50));
	}
}


test("mail watches (automations, docs/spec/27 §5): new messages from someone or about something, each once", async () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-mail-"));
	const watch: Watch = { id: "w1", on: "email", prompt: "Summarize it", from: "bank", createdAt: "2026-11-10T08:00:00Z", by: "owner" };
	const inbox = [
		{ id: "m0", subject: "Old", from: "My Bank <alerts@bank.es>", to: [], received: "2026-11-10T07:00:00Z", preview: "before the routine" },
		{ id: "m1", subject: "Your statement", from: "My Bank <alerts@bank.es>", to: [], received: "2026-11-10T09:00:00Z", preview: "ready" },
		{ id: "m2", subject: "Lunch?", from: "ana@example.com", to: [], received: "2026-11-10T09:30:00Z", preview: "hi" },
	];
	const fired: { key: string; happened: string }[] = [];
	const watchers = new AgentWatchers({
		watches: async () => [{ agentId: "agt_x", watches: [watch] }],
		fire: async (_a, _w, happened, key) => void fired.push({ key, happened }),
		mail: () => [{ name: "Outlook", search: async () => inbox }],
		stateFile: join(dir, "watchers.json"),
		log: () => {},
		mailEveryMs: 60,
	});
	await watchers.sync();
	await until(() => fired, (f) => f.length >= 1);
	await new Promise((r) => setTimeout(r, 200));
	watchers.stop();
	expect(fired.map((f) => f.key)).toEqual(["mail:m1"]);
	expect(fired[0]!.happened).toContain("Subject: Your statement");
	expect(matches({ from: "Ana <ana@example.com>", subject: "Invoice 12" }, { subject: "invoice" })).toBe(true);
	expect(matches({ from: "Ana", subject: "Invoice" }, { from: "bank", subject: "invoice" })).toBe(false);
});
