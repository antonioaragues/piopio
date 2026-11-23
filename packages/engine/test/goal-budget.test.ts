/**
 * /goal has a budget as well as rounds (extensions/src/goal.ts; the budget itself is tested there, since the faux
 * model always reports a cost of zero). Here: a real Build session tells the user both limits when the goal is set.
 */
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

let stop: (() => Promise<void>) | undefined;
afterEach(async () => {
	await stop?.();
	stop = undefined;
});

test("setting a goal says it runs for up to 25 rounds or $5.00", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-goal-budget-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	stop = async () => {
		client.close();
		await engine.stop();
	};
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	engine.hub.faux!.setResponses([fauxAssistantMessage([fauxToolCall("update_goal", { status: "done", note: "Done." })], { stopReason: "toolUse" }), fauxAssistantMessage("Done.")]);
	const { ref } = await client.call("sessions.create", { kind: "build", cwd: home });
	await client.call("sessions.submit", { ref, input: { text: "/goal make the tests pass" } });
	let notes: string[] = [];
	for (let i = 0; i < 200; i++) {
		const s: Snapshot = await client.call("sessions.open", { ref });
		notes = s.items.flatMap((x) => (x.kind === "system" ? [x.text] : []));
		if (s.state.status === "idle" && s.items.some((x) => x.kind === "assistant")) break;
		await new Promise((r) => setTimeout(r, 30));
	}
	expect(notes[0]).toBe("Goal set: make the tests pass. Piopio keeps it going for up to 25 rounds or $5.00, until it's done or needs you.");
}, 30_000);

test("/goal works in a chat too: listed there, another round until the model says it's done (docs/spec/32 CM4)", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-goal-chat-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	stop = async () => {
		client.close();
		await engine.stop();
	};
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	// Round 1 answers without ending the goal, so round 2 comes on its own and ends it.
	engine.hub.faux!.setResponses([
		fauxAssistantMessage("A first draft of the plan."),
		fauxAssistantMessage([fauxToolCall("update_goal", { status: "done", note: "The plan is written." })], { stopReason: "toolUse" }),
		fauxAssistantMessage("Done: the plan is written."),
	]);
	const { ref } = await client.call("sessions.create", { kind: "thread" });
	expect((await client.call("sessions.commands", { ref })).commands.map((c: { name: string }) => c.name)).toContain("goal");
	await client.call("sessions.submit", { ref, input: { text: "/goal a trip plan for Lisbon" } });
	let s: Snapshot | undefined;
	for (let i = 0; i < 300; i++) {
		s = await client.call("sessions.open", { ref });
		if (s!.state.status === "idle" && s!.items.some((x) => x.kind === "assistant" && x.parts.some((p) => p.text?.includes("Done: the plan")))) break;
		await new Promise((r) => setTimeout(r, 30));
	}
	const texts = s!.items.flatMap((x) => (x.kind === "system" ? [x.text] : x.kind === "assistant" ? x.parts.map((p) => p.text ?? "") : []));
	expect(texts[0]).toMatch(/^Goal set: a trip plan for Lisbon\./);
	expect(texts).toContain("A first draft of the plan.");
	expect(texts.at(-1)).toBe("Done: the plan is written.");
}, 30_000);
