import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProjectInfo, Snapshot } from "@piopio/protocol";
import { afterEach, describe, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// A Build session in a project you haven't trusted (docs/spec/39): its commands go through the network filter.
type Ctx = { engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-netb-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
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

type State = Snapshot["state"];
async function stateWhere(a: Ctx, sub: string, predicate: (s: State) => boolean): Promise<State> {
	const latest = () => a.client.events.filter((n) => n.subscriptionId === sub).flatMap((n) => n.events).filter((e) => e.type === "state").at(-1) as { state: State } | undefined;
	await a.client.waitFor(() => Boolean(latest() && predicate(latest()!.state)), 20_000);
	return latest()!.state;
}

describe.skipIf(process.platform !== "darwin")("the network filter in Build", () => {
	test("a command in a project you just added asks before reaching a new site; no reaches the agent as a note", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-netb-project-")));
		writeFileSync(join(folder, "package.json"), "{}");
		const { project } = (await a.client.call("projects.add", { path: folder })) as { project: ProjectInfo };
		expect(project.network).toBe("filtered");
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;

		await a.client.call("sessions.submit", { ref, input: { text: "$ curl -sS --max-time 15 -o /dev/null https://not-allowed.example/" } });
		// Auto-edit asks about the command itself first.
		const command = await stateWhere(a, sub, (st) => st.status === "waiting_approval" && st.prompts![0]!.tool === "bash");
		await a.client.call("sessions.respond", { ref, promptId: command.prompts![0]!.id, response: { decision: "allow" } });
		const site = await stateWhere(a, sub, (st) => st.status === "waiting_approval" && st.prompts![0]!.tool === "network");
		expect(site.prompts![0]).toMatchObject({ title: "Let this project's commands reach not-allowed.example", detail: "not-allowed.example", rule: { kind: "host", pattern: "not-allowed.example" } });
		await a.client.call("sessions.respond", { ref, promptId: site.prompts![0]!.id, response: { decision: "deny" } });
		await stateWhere(a, sub, (st) => st.status === "idle");
		const snap: Snapshot = await a.client.call("sessions.open", { ref });
		const tool = snap.items.find((i) => i.kind === "tool" && i.tool === "bash") as { output?: string } | undefined;
		expect(tool?.output).toContain("Piopio's network filter kept this command from reaching not-allowed.example");

		// Trusting the project opens its network: the next command isn't filtered.
		const trusted = (await a.client.call("projects.configure", { id: project.id, trust: true })) as { project: ProjectInfo };
		expect(trusted.project.network).toBe("open");
	}, 60_000);

	test("with the project's network off, a command can't reach even a package registry, nobody is asked, and the agent hears why", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-netb-off-")));
		writeFileSync(join(folder, "package.json"), "{}");
		const { project } = (await a.client.call("projects.add", { path: folder })) as { project: ProjectInfo };
		const off = (await a.client.call("projects.configure", { id: project.id, network: "off" })) as { project: ProjectInfo };
		expect(off.project.network).toBe("off");
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
		const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;

		await a.client.call("sessions.submit", { ref, input: { text: "$ curl -sS --max-time 15 -o /dev/null https://registry.npmjs.org/" } });
		const command = await stateWhere(a, sub, (st) => st.status === "waiting_approval" && st.prompts![0]!.tool === "bash");
		await a.client.call("sessions.respond", { ref, promptId: command.prompts![0]!.id, response: { decision: "allow" } });
		// No question about the site: straight to the end of the turn.
		const end = await stateWhere(a, sub, (st) => st.status === "idle" || (st.status === "waiting_approval" && st.prompts![0]!.tool === "network"));
		expect(end.status).toBe("idle");
		const snap: Snapshot = await a.client.call("sessions.open", { ref });
		const tool = snap.items.find((i) => i.kind === "tool" && i.tool === "bash") as { output?: string } | undefined;
		expect(tool?.output).toContain("couldn't reach registry.npmjs.org: the user turned this project's network off");

		// Trusting the project leaves it off.
		const trusted = (await a.client.call("projects.configure", { id: project.id, trust: true })) as { project: ProjectInfo };
		expect(trusted.project.network).toBe("off");
	}, 60_000);

	test("a session can't be put in Full access while its project is filtered, and doesn't start in it", async () => {
		const a = await start();
		const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-netb-fa-")));
		writeFileSync(join(folder, "package.json"), "{}");
		await a.client.call("projects.add", { path: folder });
		const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder, approvalMode: "full_auto" });
		const snap: Snapshot = await a.client.call("sessions.open", { ref });
		expect(snap.state.approvalMode).toBe("auto_edit");
		await expect(a.client.call("sessions.configure", { ref, approvalMode: "full_auto" })).rejects.toMatchObject({ data: { code: "INVALID" } });
	}, 60_000);
});

