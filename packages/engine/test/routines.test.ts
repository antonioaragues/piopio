import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Watch } from "@piopio/runtime";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { AgentWatchers, matches } from "../src/watchers.js";
import { TestClient } from "./client.js";

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 10_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 500)}`);
		await new Promise((r) => setTimeout(r, 50));
	}
}

type Runs = { runs: { kind: string; source: string; prompt: string; status: string }[]; upcoming: { id: string; kind: string; label: string }[] };

test("an agent sets its own routines by asking: a folder and a webhook, each fire a run (docs/spec/19 S3)", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-routines-"));
	const inbox = mkdtempSync(join(tmpdir(), "piopio-inbox-"));
	writeFileSync(join(inbox, "already-there.pdf"), "old");
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {}, watchers: { settleMs: 100 } });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	// No template: every agent can set routines (schedule and watch are on by default).
	const { ref } = await client.call("agents.create", { name: "Invoices", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	await client.call("sessions.subscribe", { ref });

	await client.call("sessions.submit", { ref, input: { text: `call: watch | ${JSON.stringify({ on: "folder", prompt: "Tell Antonio what the new file is.", folder: inbox })}` } });
	const folder = await until(() => client.call("agents.runs", { ref }) as Promise<Runs>, (r) => r.upcoming.some((u) => u.kind === "watch"));
	expect(folder.upcoming.find((u) => u.kind === "watch")!.label).toContain(`When a file appears or changes in ${inbox}`);

	// What was already in the folder doesn't count; a new file does, once.
	writeFileSync(join(inbox, "invoice-1042.pdf"), "new");
	const fired = await until(() => client.call("agents.runs", { ref }) as Promise<Runs>, (r) => r.runs.some((x) => x.kind === "trigger"));
	const run = fired.runs.find((x) => x.kind === "trigger")!;
	expect(run.prompt).toContain("Tell Antonio what the new file is.");
	expect(run.prompt).toContain(`A file appeared in ${inbox}: ${join(inbox, "invoice-1042.pdf")}`);
	expect(run.prompt).not.toContain("already-there.pdf");

	// A webhook routine: the agent gets a URL; calling it runs the prompt with the body.
	await client.call("sessions.submit", { ref, input: { text: `call: watch | ${JSON.stringify({ on: "webhook", prompt: "A deploy finished: {{body}}" })}` } });
	await until(() => client.call("agents.runs", { ref }) as Promise<Runs>, (r) => r.upcoming.filter((u) => u.kind === "watch").length === 2);
	const said = JSON.stringify((await client.call("sessions.open", { ref })).items);
	const url = /http:\/\/127\.0\.0\.1:\d+\/hooks\/[^\s"\\]+/.exec(said)?.[0];
	expect(url).toBeTruthy();
	const response = await fetch(url!, { method: "POST", body: "piopio 1.2 is live", headers: { "X-Delivery-Id": "d1" } });
	expect(response.status).toBeLessThan(300);
	await fetch(url!, { method: "POST", body: "piopio 1.2 is live", headers: { "X-Delivery-Id": "d1" } }); // a retry: no second run
	const hooked = await until(() => client.call("agents.runs", { ref }) as Promise<Runs>, (r) => r.runs.some((x) => x.prompt.includes("A deploy finished: piopio 1.2 is live")));
	expect(hooked.runs.filter((x) => x.prompt.includes("A deploy finished")).length).toBe(1);
}, 40_000);

test("mail routines: new messages from someone or about something, each once", async () => {
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
