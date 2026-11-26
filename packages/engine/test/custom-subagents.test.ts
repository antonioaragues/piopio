import { mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ProjectTrustStore } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, test } from "vitest";
import { formatSubagent, listSubagents, matchModel, parseSubagent, writeSubagent } from "../src/custom-subagents.js";
import { enginePaths } from "../src/paths.js";
import { toolMatcher } from "../src/runtimes/build.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Custom subagents (roadmap PAR12): pi's agent files, yours and a trusted project's; `task` hands work to one by name.

const scratch = (name: string) => realpathSync(mkdtempSync(join(tmpdir(), `piopio-subagents-${name}-`)));

test("an agent file reads as pi writes it, tools as a list or a string, and writes back the same", () => {
	const text = "---\nname: scout\ndescription: \"Fast recon: returns what it found\"\ntools: read, grep, find, ls\nmodel: claude-haiku-4-5\n---\n\nYou are a scout.\n";
	const scout = parseSubagent(text)!;
	expect(scout).toEqual({ name: "scout", description: "Fast recon: returns what it found", tools: ["read", "grep", "find", "ls"], model: "claude-haiku-4-5", instructions: "You are a scout." });
	expect(parseSubagent(formatSubagent(scout))).toEqual(scout);
	expect(parseSubagent("---\nname: w\ndescription: d\ntools: [read, bash]\n---\nx")?.tools).toEqual(["read", "bash"]);
	// No name or description, or frontmatter that isn't YAML: not an agent file.
	expect(parseSubagent("---\nname: half\n---\nx")).toBeUndefined();
	expect(parseSubagent("---\nname: bad\ndescription: a: b\n---\nx")).toBeUndefined();
});

test("yours and a project's, the project's only once it's trusted and first by name; built-in names are skipped", () => {
	const base = scratch("list");
	const agentDir = join(base, "agent");
	const project = join(base, "project");
	mkdirSync(join(agentDir, "agents"), { recursive: true });
	mkdirSync(join(project, ".pi", "agents"), { recursive: true });
	writeFileSync(join(agentDir, "agents", "scout.md"), "---\nname: scout\ndescription: Mine\n---\nMine.");
	writeFileSync(join(agentDir, "agents", "codex.md"), "---\nname: codex\ndescription: Taken\n---\nx");
	writeFileSync(join(project, ".pi", "agents", "scout.md"), "---\nname: scout\ndescription: The project's\n---\nTheirs.");
	writeFileSync(join(project, ".pi", "agents", "tester.md"), "---\nname: tester\ndescription: Runs the tests\n---\nTest.");

	expect(listSubagents(agentDir, project).map((a) => `${a.name}:${a.where}`)).toEqual(["scout:yours"]);
	new ProjectTrustStore(agentDir).set(project, true);
	expect(listSubagents(agentDir, project).map((a) => `${a.name}:${a.where}:${a.description}`)).toEqual(["scout:project:The project's", "tester:project:Runs the tests"]);
});

test("writing one: a file named after it, a rename moves nothing else, a taken or built-in name is refused", () => {
	const root = join(scratch("write"), "agents");
	mkdirSync(root);
	const path = writeSubagent(root, { name: "Code Reviewer", description: "Reviews a diff", tools: ["read", " grep "], instructions: "Look for bugs." });
	expect(path).toBe(join(root, "code-reviewer.md"));
	expect(readFileSync(path, "utf8")).toBe("---\nname: code-reviewer\ndescription: Reviews a diff\ntools: read, grep\n---\n\nLook for bugs.\n");
	expect(writeSubagent(root, { name: "code-reviewer", description: "Reviews a diff, carefully", instructions: "Look harder." }, path)).toBe(path);
	writeSubagent(root, { name: "planner", description: "Plans", instructions: "Plan." });
	expect(() => writeSubagent(root, { name: "planner", description: "Again", instructions: "" })).toThrow(/already a subagent called planner/);
	expect(() => writeSubagent(root, { name: "piopio", description: "Mine", instructions: "" })).toThrow(/taken by a built-in agent/);
	expect(() => writeSubagent(root, { name: "x", description: " ", instructions: "" })).toThrow(/Say what it's for/);
});

test("a definition's model matches provider/id, else the same id or last part, the conversation's provider first", () => {
	const models = [
		{ provider: "openrouter", id: "anthropic/claude-haiku-4.5" },
		{ provider: "anthropic", id: "claude-haiku-4.5" },
		{ provider: "openai", id: "gpt-5.5" },
		{ provider: "claude-code", id: "haiku", agent: true },
	];
	expect(matchModel("openai/gpt-5.5", models)).toEqual({ provider: "openai", id: "gpt-5.5" });
	expect(matchModel("claude-haiku-4.5", models, "openrouter")).toEqual({ provider: "openrouter", id: "anthropic/claude-haiku-4.5" });
	expect(matchModel("claude-haiku-4.5", models, "anthropic")).toEqual({ provider: "anthropic", id: "claude-haiku-4.5" });
	expect(matchModel("no-such-model", models)).toBeUndefined();
	// A coding agent's model would make the child a Claude Code conversation: never matched.
	expect(matchModel("haiku", models)).toBeUndefined();
	expect(matchModel("claude-code/haiku", models)).toBeUndefined();
});

test("tool patterns match names as pi's allowlist does", () => {
	const allowed = toolMatcher(["read", "web_*"]);
	expect(["read", "web_search", "web_fetch", "bash", "reader"].filter(allowed)).toEqual(["read", "web_search", "web_fetch"]);
});

// ── Through the engine: `task` with `agent` ─────────────────────────────────

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 30_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 1500)}`);
		await new Promise((r) => setTimeout(r, 80));
	}
}

test("a task for a named subagent runs with its instructions and only its tools, and says which one it is", async () => {
	const home = scratch("engine");
	const agentDir = join(home, "pi-agent");
	mkdirSync(join(agentDir, "agents"), { recursive: true });
	writeFileSync(join(agentDir, "agents", "scout.md"), "---\nname: scout\ndescription: Reads the code and reports what it found\ntools: read, grep, ls\nmodel: faux/no-such-model\n---\n\nReport in three bullet points at most.\n");
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: agentDir, trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	const dir = scratch("dir");
	const { project } = (await client.call("projects.add", { path: dir })) as { project: { id: string } };
	await client.call("projects.configure", { id: project.id, trust: true });

	expect(((await client.call("subagents.list", {})) as { subagents: { name: string; tools?: string[] }[] }).subagents).toMatchObject([{ name: "scout", tools: ["read", "grep", "ls"] }]);

	const { ref } = (await client.call("sessions.create", { kind: "build", cwd: dir, approvalMode: "auto_edit" })) as { ref: { kind: "build"; id: string } };
	const parent = await engine.sessions.runtime(ref);
	const taskTool = (parent as unknown as { session: { getAllTools(): { name: string; parameters: unknown }[] } }).session.getAllTools().find((t) => t.name === "task")!;
	expect(JSON.stringify(taskTool.parameters)).toContain('\\"scout\\": Reads the code and reports what it found');

	await client.call("sessions.submit", { ref, input: { text: `call: task | ${JSON.stringify({ description: "Look around", prompt: "hello", agent: "scout" })}` } });
	type Child = { ref: { kind: "build"; id: string }; parent?: { id: string; agent?: string } };
	const [child] = await until(async () => ((await client.call("sessions.list", { kind: "build" })).sessions as Child[]).filter((s) => s.parent?.id === ref.id), (c) => c.length === 1);
	expect(child!.parent?.agent).toBe("scout");
	const session = ((await engine.sessions.runtime(child!.ref)) as unknown as { session: { getActiveToolNames(): string[]; systemPrompt: string; model?: { provider: string; id: string } } }).session;
	expect(session.getActiveToolNames().sort()).toEqual(["grep", "ls", "read"]);
	expect(session.systemPrompt).toContain('You are working as the subagent "scout"');
	expect(session.systemPrompt).toContain("Report in three bullet points at most.");

	// A name that isn't there is an error for the model, not a plain subagent.
	await client.call("sessions.submit", { ref, input: { text: `call: task | ${JSON.stringify({ description: "Nope", prompt: "hello", agent: "nobody" })}` } });
	const items = await until(async () => (await client.call("sessions.open", { ref })).items as { tool?: string; status?: string; output?: string }[], (x) => x.filter((i) => i.tool === "task" && i.status !== "running").length === 2);
	expect(items.filter((i) => i.tool === "task").at(-1)?.output).toMatch(/must be equal to one of the allowed values|nobody/);
}, 60_000);
