/** Build and Chat get the agents' stop for a tool that keeps failing the same way (runtime/context/failures.ts). */
import { mkdtempSync, readFileSync, realpathSync } from "node:fs";
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

test("Build: the third same failure tells the model to stop; later calls of that tool are blocked and end the run", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-fails-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	stop = async () => {
		client.close();
		await engine.stop();
	};
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-fails-folder-")));
	const { ref } = await client.call("sessions.create", { kind: "build", cwd: folder });
	const read = (n: number) => fauxAssistantMessage([fauxToolCall("read", { path: "missing.txt" }, { id: `call_${n}` })], { stopReason: "toolUse" });
	engine.hub.faux!.setResponses([read(1), read(2), read(3), read(4), read(5), read(6), fauxAssistantMessage("I couldn't read it.")]);
	await client.call("sessions.submit", { ref, input: { text: "Read missing.txt" } });
	let snap: Snapshot | undefined;
	for (let i = 0; i < 200; i++) {
		snap = await client.call("sessions.open", { ref });
		if (snap!.state.status === "idle" && snap!.items.some((x) => x.kind === "assistant")) break;
		await new Promise((r) => setTimeout(r, 30));
	}
	const reads = snap!.items.filter((i): i is Extract<Snapshot["items"][number], { kind: "tool" }> => i.kind === "tool" && i.tool === "read");
	expect(reads[2]!.output).toContain("[Piopio: read failed 3 times this turn with this same error.");
	expect(reads[3]!.output).toContain("Not run: read already failed 3 times this turn");
	// Two blocked calls end the run: the sixth call is never made.
	expect(reads.length).toBe(5);
}, 30_000);
