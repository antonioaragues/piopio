import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { Automations } from "../src/automations/service.js";
import { nameOf } from "../src/automations/model.js";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Automations (docs/spec/27): one list of work that starts on its own, made by asking Piopio or an agent, run as one
// of them; the rules refuse what isn't allowed and say what to do instead; old schedules and routines move in.

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function start(home = mkdtempSync(join(tmpdir(), "piopio-auto-"))) {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, log: () => {}, watchers: { settleMs: 100 } });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	return { home, client, engine };
}

async function stop(): Promise<void> {
	const o = open.splice(0)[0]!;
	o.client.close();
	await o.engine.stop();
}

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 20_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 800)}`);
		await new Promise((r) => setTimeout(r, 80));
	}
}

type A = { id: string; name: string; on: string; runsAs: string; project?: string; by: string; result: string; label: string; runnerName: string; resultLabel: string; url?: string; next?: number; runCount: number; enabled: boolean; fresh?: boolean; aliases?: string[] };
type Run = { id: string; automation: string; status: string; conversation?: string; agent?: string; agentRun?: string; summary?: string };
const call = (tool: string, args: object) => `call: ${tool} | ${JSON.stringify(args)}`;
const list = async (client: TestClient, filter: object = {}) => ((await client.call("automations.list", filter)) as { automations: A[] }).automations;
const runs = async (client: TestClient, id?: string) => ((await client.call("automations.runs", id ? { id } : {})) as { runs: Run[] }).runs;
const textOf = async (client: TestClient, id: string) => JSON.stringify((await client.call("sessions.open", { ref: { kind: id.startsWith("thr") ? "thread" : "build", id } })).items);

test("Piopio makes automations in a project by asking; a file, a URL and Run now each open a conversation with it there", async () => {
	const { client } = await start();
	const inbox = realpathSync(mkdtempSync(join(tmpdir(), "piopio-auto-inbox-")));
	const created = (await client.call("projects.create", { name: "Market" })) as { project: { id: string; path: string } };
	const project = created.project.id;
	const { ref: piopio } = (await client.call("sessions.create", { kind: "build", cwd: created.project.path })) as { ref: { kind: string; id: string } };
	await client.call("sessions.submit", { ref: piopio, input: { text: `${call("automate", { when: "0 9 * * 1", prompt: "Write this week's brief" })}\n${call("automate", { on: "folder", folder: inbox, prompt: "Summarize the new report" })}` } });
	const set = await until(() => list(client, { project }), (r) => r.length === 2);
	expect(set.map((a) => [a.on, a.by, a.label, a.runnerName, a.resultLabel, a.fresh])).toEqual([
		["time", "piopio", "Every Monday at 09:00", "Piopio in Market", "A conversation in Market", true],
		["folder", "piopio", `When a file appears or changes in ${inbox}`, "Piopio in Market", "A conversation in Market", true],
	]);
	// The tool call carries its card, so the app draws it (A3: in a real conversation it fell back to a plain tool card).
	const made = await until(() => client.call("sessions.open", { ref: piopio }).then((x) => x.items as { kind: string; tool?: string; details?: { type: string; automation?: { id: string } } }[]), (xs) => xs.filter((i) => i.tool === "automate" && i.details).length === 2);
	expect(made.filter((i) => i.tool === "automate").map((i) => [i.details?.type, i.details?.automation?.id])).toEqual(set.map((a) => ["automation", a.id]));
	// Opening one clears its "New" badge.
	const got = (await client.call("automations.get", { id: set[0]!.id })) as { automation: A; summary: { when: string; runsOn: string } };
	expect(got.summary).toMatchObject({ when: "Every Monday at 09:00", runsOn: "This Mac, only while it's awake" });
	expect((await list(client, { project }))[0]!.fresh).toBeUndefined();

	// A file appears: a new conversation with Piopio in the project, with the path.
	await new Promise((r) => setTimeout(r, 300));
	writeFileSync(join(inbox, "q3.pdf"), "report");
	const fileRun = await until(() => runs(client, set[1]!.id), (r) => r.length === 1 && !!r[0]!.conversation);
	await until(() => textOf(client, fileRun[0]!.conversation!), (s) => s.includes("[Automation] “Summarize the new report”") && s.includes("q3.pdf"));

	// A webhook you make in the app: its own address; a retry with the same delivery id is one run.
	const { automation: hook } = (await client.call("automations.add", { runsAs: "piopio", project, on: "webhook", prompt: "Look into the new lead" })) as { automation: A };
	expect(hook).toMatchObject({ by: "you", url: expect.stringMatching(/^http:\/\/127\.0\.0\.1:\d+\/hooks\/a\//) });
	for (let i = 0; i < 2; i++) expect((await fetch(hook.url!, { method: "POST", headers: { "Idempotency-Key": "d1" }, body: '{"name":"Acme"}' })).status).toBe(202);
	const hookRuns = await until(() => runs(client, hook.id), (r) => r.length === 1 && !!r[0]!.conversation);
	await until(() => textOf(client, hookRuns[0]!.conversation!), (s) => s.includes("Look into the new lead") && s.includes("Acme"));
	expect((await list(client, { project })).find((a) => a.id === hook.id)).toMatchObject({ runCount: 1 });

	// Run now; pausing stops events but not Run now; removing takes it out.
	const { run } = (await client.call("automations.run", { id: set[0]!.id })) as { run: Run };
	await until(() => textOf(client, run.conversation!), (s) => s.includes("Write this week's brief"));
	await client.call("automations.update", { id: hook.id, enabled: false });
	expect((await fetch(hook.url!, { method: "POST", body: "again" })).status).toBeGreaterThanOrEqual(400);
	await client.call("automations.remove", { id: set[1]!.id });
	expect((await list(client, { project })).map((a) => a.on)).toEqual(["time", "webhook"]);
}, 60_000);

test("an agent makes its own automations by asking: they run as it, in a run of its own, and the rules keep it to itself", async () => {
	const { client } = await start();
	const inbox = realpathSync(mkdtempSync(join(tmpdir(), "piopio-auto-agent-")));
	writeFileSync(join(inbox, "already-there.pdf"), "old");
	const { ref } = await client.call("agents.create", { name: "Invoices", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	await client.call("sessions.subscribe", { ref });
	await client.call("sessions.submit", { ref, input: { text: call("automate", { on: "folder", folder: inbox, prompt: "Tell Antonio what the new file is.", name: "New invoices" }) } });
	const [made] = await until(() => list(client, { runsAs: ref.id }), (r) => r.length === 1);
	expect(made).toMatchObject({ name: "New invoices", runsAs: ref.id, by: ref.id, result: "chat", runnerName: "Invoices", resultLabel: "Invoices’s chat", approval: "wait", budgetPerRunUsd: 0.25 });

	// What was already in the folder doesn't count; a new file does, once, as the agent's run.
	writeFileSync(join(inbox, "invoice-1042.pdf"), "new");
	const [run] = await until(() => runs(client, made!.id), (r) => r.length === 1 && r[0]!.status !== "running");
	expect(run).toMatchObject({ agent: ref.id, conversation: expect.stringMatching(/^run:/) });
	const agentRuns = (await client.call("agents.runs", { ref })) as { runs: { kind: string; source: string; prompt: string }[] };
	const theirs = agentRuns.runs.find((r) => r.kind === "automation")!;
	expect(theirs).toMatchObject({ source: made!.id, prompt: expect.stringContaining(`A file appeared in ${inbox}: ${join(inbox, "invoice-1042.pdf")}`) });
	expect(theirs.prompt).not.toContain("already-there.pdf");

	// The rules: no Telegram it doesn't have, no project for an agent, nothing that isn't its own.
	await client.call("sessions.submit", { ref, input: { text: call("automate", { when: "0 8 * * *", prompt: "Morning", result: "telegram" }) } });
	await client.call("sessions.submit", { ref, input: { text: call("cancel_automation", { id: "a_not_mine" }) } });
	await until(() => client.call("sessions.open", { ref }).then((s) => JSON.stringify(s.items)), (s) => s.includes("isn't connected to Telegram") && s.includes("You have no automation a_not_mine"));
	const created = (await client.call("projects.create", { name: "Books" })) as { project: { id: string } };
	await expect(client.call("automations.add", { runsAs: ref.id, project: created.project.id, prompt: "File it" })).rejects.toThrow(/Only Piopio works in a project/);
	await expect(client.call("automations.add", { runsAs: "piopio", result: "telegram", prompt: "Tell me" })).rejects.toThrow(/Piopio has no channels/);
	await expect(client.call("automations.add", { runsAs: "piopio", when: "2020-01-01T09:00", prompt: "Too late" })).rejects.toThrow(/passed/);
	// An email automation with no mailbox connected would never fire (A3): it says to connect one first.
	await expect(client.call("automations.add", { runsAs: "piopio", on: "email", from: "orders@", prompt: "Pass it on" })).rejects.toThrow(/No mailbox is connected/);
	expect(await list(client, { runsAs: ref.id })).toHaveLength(1);
}, 60_000);

test("a template's schedule is an automation the agent runs, not part of its definition", async () => {
	const { client } = await start();
	const { ref } = await client.call("agents.create", { name: "Mornings", template: "daily-briefing", owner: "Antonio", schedule: "30 7 * * 1-5", model: { provider: "faux", id: "faux-1" } });
	expect((await client.call("agents.get", { ref })).definition).not.toHaveProperty("schedules");
	expect(await list(client, { runsAs: ref.id })).toEqual([expect.objectContaining({ on: "time", cron: "30 7 * * 1-5", label: "Every weekday at 07:30", result: "chat", fresh: true })]);
}, 30_000);

test("a time automation missed while the engine was off runs once when it's back", async () => {
	const first = await start();
	const { automation } = (await first.client.call("automations.add", { runsAs: "piopio", when: "0 9 * * 1", prompt: "Write the weekly brief" })) as { automation: A };
	await stop();
	const file = join(first.home, "automations.json");
	const store = JSON.parse(readFileSync(file, "utf8")) as { automations: { next: number }[] };
	store.automations[0]!.next = Date.now() - 60_000;
	writeFileSync(file, JSON.stringify(store));
	const { client } = await start(first.home);
	const [run] = await until(() => runs(client, automation.id), (r) => r.length === 1 && !!r[0]!.conversation);
	expect(run!.conversation).toMatch(/^thr/);
	expect((await list(client))[0]!.next).toBeGreaterThan(Date.now());
	await until(() => textOf(client, run!.conversation!), (s) => s.includes("[Automation] “Write the weekly brief”") && s.includes("Write the weekly brief"));
}, 40_000);

test("project routines from before become automations; their webhook URLs still work and a report says what changed", async () => {
	const first = await start();
	const created = (await first.client.call("projects.create", { name: "Leads" })) as { project: { id: string; path: string } };
	const project = created.project.id;
	const oldUrl = first.engine.hooks.url(project, "r_hook");
	await stop();
	const at = new Date().toISOString();
	writeFileSync(
		join(first.home, "project-routines.json"),
		JSON.stringify([
			{
				project,
				path: created.project.path,
				routines: [
					{ id: "r_week", on: "time", prompt: "Plan next week", cron: "0 9 * * 1", tz: "UTC", by: "you", createdAt: at, runs: 3, lastRun: at, lastConversation: "ses_old" },
					{ id: "r_hook", on: "webhook", prompt: "A new lead: {{body}}", by: "piopio", createdAt: at, runs: 0 },
				],
			},
		]),
	);
	const { client, engine } = await start(first.home);
	const moved = await list(client, { project });
	expect(moved.map((a) => [a.id, a.on, a.runsAs, a.by, a.runCount])).toEqual([
		["r_week", "time", "piopio", "you", 3],
		["r_hook", "webhook", "piopio", "piopio", 0],
	]);
	expect(moved[1]!.aliases).toEqual([`${project}/r_hook`]);
	// The same address (the port is the test's own each time).
	const sameUrl = engine.hooks.url(project, "r_hook");
	expect(new URL(sameUrl).pathname).toBe(new URL(oldUrl).pathname);
	expect((await fetch(sameUrl, { method: "POST", body: "Acme" })).status).toBe(202);
	const [run] = await until(() => runs(client, "r_hook"), (r) => r.length === 1 && !!r[0]!.conversation);
	await until(() => textOf(client, run!.conversation!), (s) => s.includes("A new lead: Acme") && s.includes("[Automation] “A new lead”"));
	const { report } = (await client.call("automations.migrationReport", {})) as { report?: string };
	expect(report).toContain("What changed in your routines");
	expect(report).toContain("the routine “Plan next week”");
	await client.call("automations.dismissMigrationReport", {});
	expect(((await client.call("automations.migrationReport", {})) as { report?: string }).report).toBeUndefined();
}, 40_000);

test("an agent's run that needs your OK waits, named after its automation, or is skipped; a contact's name reaches them", async () => {
	const { client } = await start();
	const { ref } = await client.call("agents.create", { name: "Rita", owner: "Toño", instructions: "Help Toño.", model: { provider: "faux", id: "faux-1" } });
	const got = await client.call("agents.get", { ref });
	const def = got.definition as Record<string, unknown> & { contacts: object[] };
	const definition = { ...def, tools: { builtin: ["memory", "send_message"] }, contacts: [...def.contacts, { id: "lucia", name: "Lucía", role: "contact" }], policies: { requireApproval: ["send_message:to_non_owner"] } };
	expect(await client.call("agents.save", { ref, definition, instructions: got.instructions })).toEqual({ saved: true, errors: [] });
	// The model writes the name, as a real one did in A3; the rule and the send both find Lucía.
	const { automation } = (await client.call("automations.add", { runsAs: ref.id, on: "webhook", name: "Café Norte orders", prompt: call("send_message", { to: "Lucía", text: "60 croissants for Friday" }) })) as { automation: A };

	await client.call("automations.run", { id: automation.id });
	const [waiting] = await until(() => runs(client, automation.id), (r) => r[0]?.status === "waiting");
	expect(waiting!.summary).toMatch(/^Waiting for your OK: Send to Lucía/);
	const box = (await client.call("inbox.list", {})) as { items: { kind: string; title: string; approval?: { approvalId: string; args: { to: string } } }[] };
	const asked = box.items.find((i) => i.kind === "approval")!;
	expect(asked).toMatchObject({ title: "Café Norte orders · needs your OK", approval: { args: { to: "lucia" } } });
	await client.call("agents.decide", { ref, approvalId: asked.approval!.approvalId, approve: true });
	await until(() => runs(client, automation.id), (r) => r[0]?.status === "done");
	const sent = (await client.call("sessions.open", { ref: { ...ref, conversationId: "person:lucia" } })).items as { kind: string; parts?: { text: string }[] }[];
	expect(sent.filter((i) => i.kind === "assistant").map((i) => i.parts?.[0]?.text)).toEqual(["60 croissants for Friday"]);

	// Set to skip: the run ends skipped, says why, and keeps what it cost.
	await client.call("automations.update", { id: automation.id, approval: "skip" });
	await client.call("automations.run", { id: automation.id });
	const [skipped] = await until(() => runs(client, automation.id), (r) => r.length === 2 && r[0]!.status === "skipped" && (r[0] as { costUsd?: number }).costUsd !== undefined);
	expect(skipped!.summary).toMatch(/^Skipped: it needed your OK/);
}, 60_000);

test("a fire due when the engine starts waits for the app to unlock the keys", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-auto-ready-"));
	let unlock!: () => void;
	const fired: string[] = [];
	const service = new Automations({
		file: join(home, "automations.json"),
		runsFile: join(home, "automation-runs.json"),
		log: () => {},
		agent: () => undefined,
		project: () => undefined,
		runAgent: async () => ({ runId: "r", conversationId: "c", status: "done" }),
		runPiopio: async (a) => (fired.push(a.id), "ses_1"),
		ready: () => new Promise<void>((resolve) => (unlock = resolve)),
		changed: () => {},
		watchesChanged: () => {},
	});
	const a = service.add({ runsAs: "piopio", when: "0 9 * * 1", prompt: "Weekly brief" }, "you");
	a.next = Date.now() - 60_000;
	service.start();
	await new Promise((r) => setTimeout(r, 200));
	expect(fired).toEqual([]);
	unlock();
	await until(() => fired, (f) => f.length === 1);
	expect(fired).toEqual([a.id]);
	service.stop();
});

test("a webhook's {{body}} isn't part of its name", () => {
	expect(nameOf("A new order came in from the shop form: {{body}}. Tell Toño in one line.")).toBe("A new order came in from the shop form");
	expect(nameOf("{{body}}")).toBe("Automation");
	expect(nameOf("Write the weekly brief.")).toBe("Write the weekly brief");
});
