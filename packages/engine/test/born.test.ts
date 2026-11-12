import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Teams born in a project (docs/spec/21 D7): Piopio offers a team or a routine, drafts a team from the project, and
// the conversation becomes the lead's.

type Ctx = { engine: Engine; client: TestClient };
const open: Ctx[] = [];
async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-d7-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, log: () => {} } as ConstructorParameters<typeof Engine>[0]);
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	const ctx = { engine, client };
	open.push(ctx);
	return ctx;
}
afterEach(async () => {
	for (const ctx of open.splice(0)) {
		ctx.client.close();
		await ctx.engine.stop();
	}
});

async function until<T>(read: () => Promise<T>, ready: (value: T) => boolean, timeout = 20_000): Promise<T> {
	const end = Date.now() + timeout;
	for (;;) {
		const value = await read();
		if (ready(value)) return value;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(value)}`);
		await new Promise((r) => setTimeout(r, 150));
	}
}

function project(): string {
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-d7-p-")));
	writeFileSync(join(folder, "package.json"), JSON.stringify({ name: "app", scripts: { test: "node --test" }, devDependencies: { typescript: "5" } }));
	execFileSync("git", ["init", "-q", "-b", "main"], { cwd: folder });
	execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], { cwd: folder });
	return folder;
}

const call = (tool: string, args: object) => `call: ${tool} | ${JSON.stringify(args)}`;

test("Piopio offers a team or a routine in a project; a draft is read from the project; the conversation becomes the lead's", async () => {
	const a = await start();
	const faux = { provider: "faux", id: "faux-1" };
	const { ref: rita } = await a.client.call("agents.create", { name: "Rita", owner: "Antonio", instructions: "You review code.", model: faux });
	await a.client.call("agents.save", { ref: rita, ...(await (async () => { const g = await a.client.call("agents.get", { ref: rita }); return { definition: { ...g.definition, description: "Reviews code before it ships" }, instructions: g.instructions }; })()) });
	const folder = project();
	await a.client.call("projects.add", { path: folder });
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, approvalMode: "full_auto" });
	const items = () => a.client.call("sessions.open", { ref, fold: true }).then((s: Snapshot) => s.items);
	type Tool = Extract<Snapshot["items"][number], { kind: "tool" }>;
	const tool = (xs: Snapshot["items"], name: string) => xs.flatMap((i) => (i.kind === "steps" ? (i.tools as Tool[]) : [i])).filter((i): i is Tool => i.kind === "tool" && i.tool === name);

	// The offers are Piopio's tools here.
	await a.client.call("sessions.submit", { ref, input: { text: call("offer_team", { why: "Three screens can be built at once.", parts: ["Settings", "Profile", "Search"] }) } });
	let xs = await until(items, (x) => tool(x, "offer_team").some((t) => t.status === "done") && x.at(-1)?.kind === "assistant");
	expect(tool(xs, "offer_team")[0]).toMatchObject({ output: expect.stringContaining("Offered"), args: { parts: ["Settings", "Profile", "Search"] } });
	await a.client.call("sessions.submit", { ref, input: { text: call("offer_repeat", { what: "Summarize yesterday's commits", when: "Every weekday at 9:00", cron: "0 9 * * 1-5" }) } });
	xs = await until(items, (x) => tool(x, "offer_repeat").some((t) => t.status === "done") && x.at(-1)?.kind === "assistant");

	// A draft from the project: TypeScript, its checks, git; Rita suggested as the reviewer.
	const drafted = await a.client.call("teams.draftFor", { cwd: folder, request: "Build the settings, profile and search screens" });
	expect(drafted.found).toEqual({ git: true, checks: "npm test", agentsMd: false, language: "TypeScript" });
	expect(drafted.draft.roles.map((r: { kind: string }) => r.kind)).toEqual(["lead", "write", "review", "integrate"]);
	const qa = drafted.draft.roles.find((r: { kind: string }) => r.kind === "review");
	expect(drafted.suggestions).toEqual([{ role: qa.id, agent: rita.id, name: "Rita" }]);

	// The team, from the draft with Rita as its reviewer, lives only here.
	const roles = drafted.draft.roles.map((r: { id: string }) => (r.id === qa.id ? { ...r, agent: rita.id, name: "Rita" } : r));
	const { team } = await a.client.call("teams.create", { name: drafted.draft.name, template: "custom", cwd: folder, roles, style: drafted.draft.style, testCommand: drafted.found.checks });
	expect(team.roles.find((r: { kind: string }) => r.kind === "review")).toMatchObject({ agent: rita.id });
	const defs = (await a.client.call("teams.definitions", {})).definitions;
	expect(defs.find((d: { id: string }) => d.id === team.definitionId)).toMatchObject({ saved: false, template: "custom" });

	// With a team here, Piopio no longer offers one.
	await a.client.call("sessions.submit", { ref, input: { text: call("offer_team", { why: "x", parts: ["a", "b"] }) } });
	xs = await until(items, (x) => tool(x, "offer_team").length === 2 && tool(x, "offer_team")[1]!.status !== "running" && x.at(-1)?.kind === "assistant");
	expect(tool(xs, "offer_team")[1]).toMatchObject({ status: "error" });

	// The same conversation becomes the lead's: told to plan, with the board's tools.
	await until(() => a.client.call("sessions.open", { ref }).then((x: Snapshot) => x.state.status), (st) => st === "idle");
	await a.client.call("teams.adopt", { id: team.id, sessionId: ref.id });
	const listed = await a.client.call("sessions.list", {});
	expect(listed.sessions.find((s: { ref: { id: string } }) => s.ref.id === ref.id)).toMatchObject({ team: { id: team.id, kind: "lead" } });
	xs = await until(items, (x) => x.some((i) => i.kind === "user" && i.text.startsWith("[Board] The user brought in")) && x.at(-1)?.kind === "assistant");
	await a.client.call("sessions.submit", { ref, input: { text: call("list_tasks", {}) } });
	xs = await until(items, (x) => tool(x, "list_tasks").some((t) => t.status !== "running") && x.at(-1)?.kind === "assistant");
	expect(tool(xs, "list_tasks")[0]).toMatchObject({ status: "done" });
	await expect(a.client.call("teams.adopt", { id: team.id, sessionId: ref.id })).rejects.toThrow(/already with the lead/);

	// Another project's conversation can't be this team's lead's.
	const other = project();
	await a.client.call("projects.add", { path: other });
	const { ref: elsewhere } = await a.client.call("sessions.create", { kind: "build", cwd: other, approvalMode: "full_auto" });
	await expect(a.client.call("teams.adopt", { id: team.id, sessionId: elsewhere.id })).rejects.toThrow(/another project/);
}, 90_000);
