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
