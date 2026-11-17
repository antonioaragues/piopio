import { readFileSync } from "node:fs";
import type { SessionEvent, TimelineItem } from "@piopio/protocol";
import { describe, expect, test } from "vitest";
import { TimelineBuilder, type PiMessage } from "../src/timeline/builder.js";
import { DurableViewMapper, messagesFromEntries } from "../src/timeline/pi-durable.js";
import { SdkEventMapper } from "../src/timeline/pi-sdk.js";
import { endDetails, startDetails } from "../src/timeline/tool-details.js";

const load = (name: string) =>
	readFileSync(new URL(`./fixtures/${name}.jsonl`, import.meta.url), "utf8")
		.split("\n")
		.filter(Boolean)
		.map((l) => JSON.parse(l) as { type: string; [k: string]: unknown });

/** Drops wall-clock fields so results compare across runs. */
const stable = (items: TimelineItem[]) => items.map(({ at: _at, ...rest }) => rest);

describe("pi SDK mapper", () => {
	for (const fixture of ["pi-sdk-chat-faux", "pi-sdk-tools-faux"]) {
		test(`${fixture}: streamed timeline equals a fresh snapshot of the same transcript`, () => {
			const events = load(fixture);
			const live = new TimelineBuilder({ kind: "build", id: "ses_test" });
			const mapper = new SdkEventMapper(live, 0);
			const emitted: SessionEvent[] = [];
			for (const e of events) {
				mapper.apply(e);
				emitted.push(...live.flush());
			}
			const transcript = events.filter((e) => e.type === "message_end").map((e) => e.message as PiMessage);
			const fresh = new TimelineBuilder({ kind: "build", id: "ses_test" });
			fresh.reset(transcript, (i) => SdkEventMapper.idOf(i), false);

			const liveSnap = live.snapshot();
			expect(stable(liveSnap.items).map(({ durationMs: _d, ...i }: Record<string, unknown>) => i)).toEqual(stable(fresh.snapshot().items));
			expect(liveSnap.state.status).toBe("idle");
			expect(emitted.some((e) => e.type === "item.delta")).toBe(true);
			expect(stable(liveSnap.items)).toMatchSnapshot();
		});
	}

	test("tool calls become tool items with output", () => {
		const live = new TimelineBuilder({ kind: "build", id: "ses_test" });
		const mapper = new SdkEventMapper(live, 0);
		for (const e of load("pi-sdk-tools-faux")) mapper.apply(e);
		const tool = live.snapshot().items.find((i) => i.kind === "tool");
		expect(tool).toMatchObject({ kind: "tool", tool: "bash", status: "done", args: { command: "echo from-tool" } });
		expect(tool && tool.kind === "tool" && tool.output?.trim()).toBe("from-tool");
	});
});

describe("pi-durable mapper", () => {
	type V = Parameters<DurableViewMapper["apply"]>[0];
	const user = (id: number, text: string) => ({ id, kind: "piopio.user", model: [{ role: "user", content: text, timestamp: 1 }], data: { text } });
	const answer = (id: number, content: unknown[], stopReason = "stop") => ({ id, kind: "pi.assistant", model: [{ role: "assistant", content, stopReason, model: "m" }] });
	const result = (id: number, callId: string, text: string, isError = false) => ({ id, kind: "pi.tool_result", model: [{ role: "toolResult", toolCallId: callId, toolName: "bash", content: [{ type: "text", text }], isError }] });
	const view = (entries: unknown[], live: object = {}, inbox: unknown[] = []): V => ({ entries: entries as never, docs: { "pi.live": live, "pi.inbox": { items: inbox } } });
	const run = { taskId: 9, inputs: [], turns: 0 };

	test("streams the partial answer on a provisional item, then swaps in the entry id", () => {
		const live = new TimelineBuilder({ kind: "agent", id: "agt_test" });
		const mapper = new DurableViewMapper(live);
		mapper.load([user(1, "hi")], view([user(1, "hi")]), false);
		live.flush();
		mapper.apply(view([user(1, "hi")], { run, generation: { attempt: 1, message: { role: "assistant", content: [{ type: "text", text: "Hel" }], model: "m" } } }));
		mapper.apply(view([user(1, "hi")], { run, generation: { attempt: 1, message: { role: "assistant", content: [{ type: "text", text: "Hello" }], model: "m" } } }));
		const change = mapper.apply(view([user(1, "hi"), answer(2, [{ type: "text", text: "Hello" }])], {}));
		expect(change).toMatchObject({ runEnded: true, appended: [{ id: 2 }] });
		const events = live.flush();
		expect(events.filter((e) => e.type === "item.delta").map((e) => (e as { textDelta: string }).textDelta)).toEqual(["Hel", "lo"]);
		expect(events.find((e) => e.type === "item.replaced")).toMatchObject({ oldId: "gen:1", item: { id: "2", status: "done" } });
		expect(live.snapshot().items).toMatchObject([{ kind: "user", id: "1" }, { id: "2", parts: [{ type: "text", text: "Hello" }] }]);
		expect(live.snapshot().state.status).toBe("idle");
	});

	test("a tool round: the card starts when the call runs, takes its output, and ends with the result entry", () => {
		const live = new TimelineBuilder({ kind: "agent", id: "agt_test" });
		const mapper = new DurableViewMapper(live);
		const call = answer(2, [{ type: "toolCall", id: "c1", name: "bash", arguments: { command: "echo hi" } }], "toolUse");
		mapper.load([user(1, "go")], view([user(1, "go")], { run }), false);
		mapper.apply(view([user(1, "go"), call], { run, tools: [{ callId: "c1", name: "bash", status: "pending", taskId: 10 }] }));
		expect(live.snapshot().items.some((i) => i.kind === "tool")).toBe(false); // waiting for beforeTool (an approval)
		mapper.apply(view([user(1, "go"), call], { run, tools: [{ callId: "c1", name: "bash", status: "running", taskId: 10, output: "h" }] }));
		mapper.apply(view([user(1, "go"), call], { run, tools: [{ callId: "c1", name: "bash", status: "running", taskId: 10, output: "hi\n" }] }));
		expect(live.snapshot().items.find((i) => i.kind === "tool")).toMatchObject({ status: "running", output: "hi\n", args: { command: "echo hi" } });
		mapper.apply(view([user(1, "go"), call, result(3, "c1", "hi")], { run, tools: [{ callId: "c1", name: "bash", status: "done", taskId: 10, entry: 3 }] }));
		expect(live.snapshot().items.find((i) => i.kind === "tool")).toMatchObject({ status: "done", output: "hi" });
	});

	test("a call that never ran (blocked) or ran between two values still gets its card", () => {
		const live = new TimelineBuilder({ kind: "agent", id: "agt_test" });
		const mapper = new DurableViewMapper(live);
		mapper.load([], view([]), false);
		const calls = answer(1, [
			{ type: "toolCall", id: "c1", name: "bash", arguments: { command: "rm x" } },
			{ type: "toolCall", id: "c2", name: "bash", arguments: { command: "ls" } },
		], "toolUse");
		mapper.apply(view([calls, result(2, "c1", "Denied", true), result(3, "c2", "a b")], { run }));
		expect(live.snapshot().items.filter((i) => i.kind === "tool")).toMatchObject([
			{ callId: "c1", status: "error", args: { command: "rm x" } },
			{ callId: "c2", status: "done", output: "a b" },
		]);
	});

	test("the first value resumes an answer in progress and the queue; an old run failure isn't shown again", () => {
		const live = new TimelineBuilder({ kind: "agent", id: "agt_test" });
		const mapper = new DurableViewMapper(live, (id) => (id === "7" ? "later" : undefined));
		mapper.load(
			[user(1, "hi")],
			view([user(1, "hi")], { run, runFailure: { taskId: 3, reason: "faulted", inputs: [] }, generation: { attempt: 1, message: { role: "assistant", content: [{ type: "text", text: "Hal" }] } } }, [{ id: 7, mode: "followUp" }]),
			false,
		);
		const snap = live.snapshot();
		expect(snap.state.status).toBe("running");
		expect(snap.state.queue).toEqual([{ id: "7", mode: "followUp", text: "later" }]);
		expect(snap.items).toMatchObject([{ kind: "user", id: "1" }, { kind: "assistant", status: "streaming", parts: [{ text: "Hal" }] }]);
		expect(snap.items.some((i) => i.kind === "system")).toBe(false);
	});

	test("a run that ends without an answer, a retry and a failed compaction get notices once", () => {
		const live = new TimelineBuilder({ kind: "agent", id: "agt_test" });
		const mapper = new DurableViewMapper(live);
		mapper.load([user(1, "hi")], view([user(1, "hi")], { run }), false);
		const retrying = { run, generation: { attempt: 2, retry: { at: 0, error: "overloaded" } } };
		mapper.apply(view([user(1, "hi")], retrying));
		mapper.apply(view([user(1, "hi")], retrying));
		const failed = { runFailure: { taskId: 9, reason: "faulted", detail: "boom", inputs: [] }, compactionFailure: { taskId: 4, trigger: "threshold", error: "no model" } };
		expect(mapper.apply(view([user(1, "hi")], failed)).runEnded).toBe(true);
		mapper.apply(view([user(1, "hi")], failed));
		expect(live.snapshot().items.filter((i) => i.kind === "system").map((i) => (i as { text: string }).text)).toEqual([
			"Retrying (attempt 2): overloaded",
			"Not answered (faulted): boom",
			"Compaction failed: no model",
		]);
	});

	test("committed entries load as messages with their entry ids", () => {
		const { messages, ids } = messagesFromEntries([user(1, "hi"), answer(2, [{ type: "text", text: "yo" }]), { id: 3, kind: "pi.compaction", data: { summary: "s" } }] as never);
		expect(ids).toEqual(["1", "2"]);
		expect(messages).toMatchObject([{ role: "user", content: "hi" }, { role: "assistant" }]);
	});
});

describe("tool details", () => {
	test("edit shows pi's patch, write shows the new file, bash its exit code, read its path", () => {
		const patch = "--- a.ts\n+++ a.ts\n@@ -1 +1 @@\n-old\n+new";
		expect(endDetails("edit", { path: "a.ts", edits: [] }, { details: { patch } }, "ok", false)).toEqual({ type: "diff", path: "a.ts", diff: patch });
		expect(startDetails("write", { path: "b.md", content: "one\ntwo\n" })).toEqual({ type: "diff", path: "b.md", diff: "@@ -0,0 +1,2 @@\n+one\n+two" });
		expect(endDetails("bash", { command: "false" }, { structuredContent: { exit_code: 1 } }, "", true)).toEqual({ type: "terminal", command: "false", exitCode: 1 });
		// Reloaded from the session file there is no structuredContent: the code comes from the output.
		expect(endDetails("bash", { command: "exit 3" }, {}, "\n\nCommand exited with code 3", true)).toMatchObject({ exitCode: 3 });
		expect(endDetails("bash", { command: "true" }, {}, "", false)).toMatchObject({ exitCode: 0 });
		expect(startDetails("read", { path: "src/x.swift", offset: 3 })).toEqual({ type: "file", path: "src/x.swift", language: "swift" });
		expect(startDetails("web_search", { query: "x" })).toBeUndefined();
	});
});

describe("tool images", () => {
	test("a read screenshot is kept once and listed on the tool item, live and after a rebuild", async () => {
		const { mkdtempSync, existsSync, readFileSync: read } = await import("node:fs");
		const { tmpdir } = await import("node:os");
		const { join } = await import("node:path");
		const { toolImageKeeper } = await import("../src/attachment-files.js");
		const dir = mkdtempSync(join(tmpdir(), "piopio-tool-images-"));
		const png = Buffer.from("not really a png").toString("base64");
		const content = [{ type: "text" as const, text: "Read image file [image/png]" }, { type: "image" as const, mimeType: "image/png", data: png }];
		const live = new TimelineBuilder({ kind: "build", id: "ses_test" });
		live.keepImages = toolImageKeeper(dir);
		live.toolStart("call|1", "read", { path: "/tmp/probe.png" });
		live.toolEnd("call|1", "Read image file [image/png]\n[image]", false, 5, { content });
		const tool = live.snapshot().items.find((i) => i.kind === "tool") as Extract<TimelineItem, { kind: "tool" }>;
		expect(tool.images).toEqual([{ name: "probe.png", kind: "image", mimeType: "image/png", stored: "tools/call_1-1.png" }]);
		expect(read(join(dir, "tools/call_1-1.png"), "utf8")).toBe("not really a png");

		const fresh = new TimelineBuilder({ kind: "build", id: "ses_test" });
		fresh.keepImages = toolImageKeeper(dir);
		fresh.reset(
			[
				{ role: "assistant", content: [{ type: "toolCall", id: "call|1", name: "read", arguments: { path: "/tmp/probe.png" } }] },
				{ role: "toolResult", toolCallId: "call|1", toolName: "read", content },
			],
			(i) => `m${i}`,
			false,
		);
		const again = fresh.snapshot().items.find((i) => i.kind === "tool") as Extract<TimelineItem, { kind: "tool" }>;
		expect(again.images).toEqual(tool.images);
		expect(existsSync(join(dir, "tools"))).toBe(true);
	});

	test("without a keeper, images stay out of the item", () => {
		const b = new TimelineBuilder({ kind: "build", id: "ses_test" });
		b.toolStart("c1", "read", { path: "/tmp/a.png" });
		b.toolEnd("c1", "[image]", false, 1, { content: [{ type: "image", mimeType: "image/png", data: "AAAA" }] });
		const tool = b.snapshot().items.find((i) => i.kind === "tool") as Extract<TimelineItem, { kind: "tool" }>;
		expect(tool.images).toBeUndefined();
	});
});
