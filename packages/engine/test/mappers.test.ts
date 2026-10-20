import { readFileSync } from "node:fs";
import type { SessionEvent, TimelineItem } from "@piopio/protocol";
import { describe, expect, test } from "vitest";
import { TimelineBuilder, type PiMessage } from "../src/timeline/builder.js";
import { DurableEventMapper, messagesFromEntries } from "../src/timeline/pi-durable.js";
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
	test("pi-durable-chat-faux: items use committed entry ids", () => {
		const events = load("pi-durable-chat-faux");
		const live = new TimelineBuilder({ kind: "thread", id: "thr_test" });
		const mapper = new DurableEventMapper(live);
		mapper.applySnapshot(events[0]!, false);
		for (const e of events.slice(1)) mapper.apply(e);
		const entries = events.filter((e) => e.type === "message_end").map((e) => e.entry as { id: number; kind: string; model?: PiMessage[] });
		const { messages, ids } = messagesFromEntries(entries as never);
		const fresh = new TimelineBuilder({ kind: "thread", id: "thr_test" });
		fresh.reset(messages, (i) => ids[i]!, false);
		expect(stable(live.snapshot().items)).toEqual(stable(fresh.snapshot().items));
		expect(stable(live.snapshot().items)).toMatchSnapshot();
	});

	test("streams deltas on a provisional item, then swaps in the entry id", () => {
		const live = new TimelineBuilder({ kind: "thread", id: "thr_test" });
		const mapper = new DurableEventMapper(live);
		mapper.apply({ type: "message_start", message: { role: "assistant", content: [], model: "m" } });
		mapper.apply({ type: "message_update", changes: [{ type: "text_start", contentIndex: 0, block: { type: "text", text: "Hel" } }] });
		mapper.apply({ type: "message_update", changes: [{ type: "text_delta", contentIndex: 0, delta: "lo" }] });
		mapper.apply({ type: "message_end", entry: { id: 42, kind: "pi.assistant", model: [{ role: "assistant", content: [{ type: "text", text: "Hello" }], stopReason: "stop" }] } });
		const events = live.flush();
		expect(events.filter((e) => e.type === "item.delta").map((e) => (e as { textDelta: string }).textDelta)).toEqual(["Hel", "lo"]);
		expect(events.find((e) => e.type === "item.replaced")).toMatchObject({ oldId: "gen:1", item: { id: "42", status: "done" } });
		expect(live.snapshot().items).toMatchObject([{ id: "42", parts: [{ type: "text", text: "Hello" }] }]);
	});

	test("a snapshot taken mid-answer resumes the partial", () => {
		const live = new TimelineBuilder({ kind: "thread", id: "thr_test" });
		new DurableEventMapper(live).applySnapshot(
			{ type: "snapshot", entries: [{ id: 1, kind: "pi.user", model: [{ role: "user", content: "hi" }] }], run: { inputs: [] }, generation: { attempt: 1, message: { role: "assistant", content: [{ type: "text", text: "Hal" }] } }, inbox: [] },
			false,
		);
		const snap = live.snapshot();
		expect(snap.state.status).toBe("running");
		expect(snap.items).toMatchObject([{ kind: "user", id: "1" }, { kind: "assistant", status: "streaming", parts: [{ text: "Hal" }] }]);
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
