/**
 * An agent's chat shows everything said, not the model's context: a compaction summarizes older messages for the
 * model and leaves them in the conversation's history, which the chat reads (with a marker where the summary took over).
 */
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import type { Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home = mkdtempSync(join(tmpdir(), "piopio-history-"))): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	const ctx = { home, engine, client };
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

test("after a compaction the chat still shows the earlier messages, live and after a restart, with a marker where the summary took over", async () => {
	let a = await start();
	const { ref } = await a.client.call("agents.create", { name: "Helper", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	type Item = Snapshot["items"][number];
	const items = async () => ((await a.client.call("sessions.open", { ref })) as Snapshot).items;
	const until = async (ready: (xs: Item[]) => boolean) => {
		for (let i = 0; i < 300; i++) {
			const xs = await items();
			if (ready(xs)) return xs;
			await new Promise((r) => setTimeout(r, 100));
		}
		throw new Error("the chat didn't get there");
	};
	const answers = (xs: Item[]) => xs.flatMap((i) => (i.kind === "assistant" ? [i.parts.map((p) => p.text).join("")] : []));
	/** What the chat reads top to bottom: your messages by their first words, the answers, and the marker. */
	const reading = (xs: Item[]) => xs.flatMap((i) => (i.kind === "user" ? [i.text.slice(0, 10)] : i.kind === "assistant" ? [i.parts.map((p) => p.text).join("")] : i.kind === "compaction" ? ["(summarized above)"] : []));

	for (const [i, answer] of ["One.", "Two.", "Three."].entries()) {
		a.engine.hub.faux!.setResponses([fauxAssistantMessage(answer)]);
		await a.client.call("sessions.submit", { ref, input: { text: `Message ${i + 1}. ${"A few more words to count. ".repeat(40)}` } });
		await until((xs) => answers(xs).includes(answer));
	}
	const before = reading(await items());
	expect(before.slice(-6)).toEqual(["Message 1.", "One.", "Message 2.", "Two.", "Message 3.", "Three."]);

	// A compaction that keeps little as it was (pi's default keeps the newest ~20k tokens): the model now reads a
	// summary of the older exchanges, then the ones it kept.
	const runtime = await a.engine.sessions.agent(ref);
	type Owner = { configure(change: object, c: unknown): Promise<unknown>; compact(instructions: undefined, c: unknown): Promise<unknown>; context(c: unknown): Promise<{ entries: { kind: string }[] }> };
	const { harness } = runtime.core.safety["host"] as unknown as { harness: { waitForTask(id: unknown, c: unknown): Promise<unknown> } };
	const owner = await (runtime.core as unknown as { conversation(contact: string): Promise<Owner> }).conversation("owner");
	await owner.configure({ compaction: { keepRecentTokens: 300 } }, BACKGROUND_CONTEXT);
	a.engine.hub.faux!.setResponses([fauxAssistantMessage("Summary of earlier messages.")]);
	await harness.waitForTask(await owner.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
	const context = (await owner.context(BACKGROUND_CONTEXT)).entries.map((e) => e.kind);
	expect(context[0]).toBe("pi.compaction");
	const exchanges = context.filter((k) => k === "pi.user").length;
	expect(exchanges).toBeGreaterThan(0);
	expect(exchanges).toBeLessThan(3);

	// Live: nothing left the chat, and the marker stands before the first message the model still reads as it was.
	const kept = [...before.slice(0, -2 * exchanges), "(summarized above)", ...before.slice(-2 * exchanges)];
	const live = await until((xs) => xs.some((i) => i.kind === "compaction"));
	expect(reading(live)).toEqual(kept);
	expect(live.find((i) => i.kind === "compaction")).toMatchObject({ summary: expect.stringContaining("Summary of earlier messages.") });

	// After a restart the chat is read again from the conversation's history: the same.
	await stop(a);
	a = await start(a.home);
	expect(reading(await items())).toEqual(kept);
}, 120_000);
