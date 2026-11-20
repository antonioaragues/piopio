/**
 * A conversation that changed who runs it (docs/spec/31 CA7): Piopio's agent ⇄ a coding agent. Each runner keeps its own
 * history file, so the conversation is a list of segments: the earlier ones (`Segment`, kept in the catalog) and the
 * current one (the entry's own `sessionFile` or `agentFile`). The transcript shows every segment in order, with a line
 * where it switched; the new runner starts from a summary of what came before, sent once as a text attachment
 * ("Conversation so far.md") with the first message after the switch.
 */
import { existsSync, readFileSync } from "node:fs";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { Attachment, ContainerRef, ModelRef, SessionEvent, Snapshot, TimelineItem } from "@piopio/protocol";
import { agentName, isCodingAgent } from "../coding-agents.js";
import { TimelineBuilder, type PiMessage } from "../timeline/builder.js";
import { sdkMessages, SdkEventMapper } from "../timeline/pi-sdk.js";
import type { Runtime, SubmitOptions } from "./runtime.js";

/** An earlier part of a conversation: who ran it, and its history file. */
export type Segment = { model: ModelRef; sessionFile?: string; agentFile?: string; at: string };

/** Who runs a model: Piopio's agent, or a coding agent by name. */
export const runnerName = (model: ModelRef): string => (isCodingAgent(model.provider) ? agentName(model.provider) : "Piopio's agent");

/** A history file's items as the transcript shows them (pi session or a coding agent's copy), without opening a runtime. */
export function fileItems(ref: ContainerRef, files: { sessionFile?: string; agentFile?: string }): TimelineItem[] {
	const builder = new TimelineBuilder(ref);
	if (files.agentFile && existsSync(files.agentFile)) {
		try {
			const stored = JSON.parse(readFileSync(files.agentFile, "utf8")) as { messages?: PiMessage[] };
			builder.reset(stored.messages ?? [], (i) => `m${i}`, false);
		} catch {
			return [];
		}
	} else if (files.sessionFile && existsSync(files.sessionFile)) {
		builder.reset(sdkMessages(SessionManager.open(files.sessionFile).buildSessionContext().messages as unknown as PiMessage[]), (i) => SdkEventMapper.idOf(i), false);
	} else return [];
	return builder.snapshot().items;
}

const said = (items: readonly TimelineItem[]) => items.filter((i) => i.kind === "user" || i.kind === "assistant").length;

/**
 * The earlier segments' items, each id prefixed with its segment ("s0:m3"), and after each one the line that says who
 * runs the conversation from there on.
 */
export function pastItems(ref: ContainerRef, segments: readonly Segment[], current: ModelRef): TimelineItem[] {
	const out: TimelineItem[] = [];
	segments.forEach((segment, i) => {
		const items = fileItems(ref, segment).map((item) => ({ ...item, id: `s${i}:${item.id}` }) as TimelineItem);
		out.push(...items);
		const next = segments[i + 1]?.model ?? current;
		const count = said(out);
		const into = isCodingAgent(next.provider) ? `Now running in ${runnerName(next)}` : "Now running on Piopio's agent";
		out.push({ kind: "system", id: `switch:${i}`, at: segments[i + 1]?.at ?? segment.at, level: "info", text: `${into} · it starts from a summary of the ${count} message${count === 1 ? "" : "s"} above` });
	});
	return out;
}

/** What came before, for the next runner: who said what, tool calls as one line each, the most recent part kept. */
export function handoffSummary(items: readonly TimelineItem[], limit = 16_000): string {
	const lines: string[] = [];
	// The line about this very switch closes the earlier parts: it's news to nobody.
	const last = items.at(-1)?.kind === "system" && items.at(-1)!.id.startsWith("switch:") ? items.length - 1 : items.length;
	for (const item of items.slice(0, last)) {
		if (item.kind === "user") lines.push(`User: ${item.text}`);
		else if (item.kind === "assistant") {
			const text = item.parts.filter((p) => p.type === "text").map((p) => p.text).join("").trim();
			if (text) lines.push(`Assistant (${item.model ?? "earlier assistant"}): ${text}`);
		} else if (item.kind === "tool") {
			const args = item.args as { path?: unknown; command?: unknown } | undefined;
			const what = typeof args?.command === "string" ? args.command : typeof args?.path === "string" ? args.path : "";
			lines.push(`(${item.tool}${what ? ` ${what.slice(0, 160)}` : ""}${item.status === "done" ? "" : ` · ${item.status}`})`);
		} else if (item.kind === "system" && item.id.startsWith("switch:")) lines.push(`— ${item.text} —`);
	}
	let body = lines.join("\n\n");
	if (body.length > limit) body = `…(the earlier part is left out)\n\n${body.slice(body.length - limit)}`;
	return [
		"This conversation was run by another assistant until now (or by you, in an earlier session you no longer have). Here is what was said, with tool calls as one line each. Carry on from it; you don't have its tool results, so check files again before relying on them.",
		"",
		body,
	].join("\n");
}

/** The handoff as the attachment the first message after a switch carries. */
export function handoffAttachment(summary: string): Attachment {
	return { kind: "text", name: "Conversation so far.md", mimeType: "text/markdown", text: summary };
}

/** A conversation with earlier segments: their items first, then the current runtime's; everything else is the runtime's. */
export class SegmentedRuntime implements Runtime {
	readonly ref: ContainerRef;
	edit?: Runtime["edit"];
	regenerate?: Runtime["regenerate"];
	switchBranch?: Runtime["switchBranch"];
	removeQueued?: Runtime["removeQueued"];

	constructor(
		readonly inner: Runtime,
		private readonly past: TimelineItem[],
		/** The summary for the first message after the switch, and how to mark it sent. */
		private handoff?: { summary: string; sent: () => void },
	) {
		this.ref = inner.ref;
		if (inner.edit) this.edit = (id, text) => inner.edit!(id, text);
		if (inner.regenerate) this.regenerate = (id) => inner.regenerate!(id);
		if (inner.switchBranch) this.switchBranch = (b) => inner.switchBranch!(b);
		if (inner.removeQueued) this.removeQueued = (id) => inner.removeQueued!(id);
	}

	snapshot(): Snapshot {
		const s = this.inner.snapshot();
		return { ...s, items: [...this.past, ...s.items] };
	}

	onEvents(listener: (events: SessionEvent[]) => void): () => void {
		return this.inner.onEvents((events) => listener(events.map((e) => (e.type === "resnapshot" ? { ...e, snapshot: { ...e.snapshot, items: [...this.past, ...e.snapshot.items] } } : e))));
	}

	async submit(text: string, options: SubmitOptions) {
		const handoff = this.handoff;
		if (!handoff) return this.inner.submit(text, options);
		this.handoff = undefined;
		const result = await this.inner.submit(text, { ...options, attachments: [handoffAttachment(handoff.summary), ...(options.attachments ?? [])] });
		handoff.sent();
		return result;
	}

	abort() {
		return this.inner.abort();
	}
	configure(change: Parameters<Runtime["configure"]>[0]) {
		return this.inner.configure(change);
	}
	close() {
		return this.inner.close();
	}
}

/** The runtime under a segmented one (for what only a Build session or Claude Code can do). */
export const innerOf = (runtime: Runtime): Runtime => (runtime instanceof SegmentedRuntime ? runtime.inner : runtime);
