/**
 * Chats from before 2026-11-15 ran on pi-durable, one SQLite file each (`threads/`). Since then every conversation is
 * a pi SDK session, so each old chat is copied once into one: the branch it showed, message by message, with its files
 * (tagged as `sdkContent` tags them, so their chips still open the kept copy) and its `/commands` as typed. Other
 * branches, approval cards and notes stay behind. The SQLite file isn't touched: it stays as it was (`migratedFrom`)
 * until the chat is deleted.
 */
import { existsSync } from "node:fs";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { AttachmentInfo } from "@piopio/protocol";
import { TYPED_ENTRY, USER_ENTRY, type ContentBlock } from "./input.js";
import type { ModelHub } from "./models.js";

const ctx = BACKGROUND_CONTEXT;

type Entry = { id: string | number; kind: string; model?: { role: string; content?: unknown; [key: string]: unknown }[]; data?: unknown };

/** A pi-durable user message's blocks as an SDK message's (files first, tagged; images after the text). */
export function sdkFromDurable(content: unknown, infos: readonly AttachmentInfo[]): string | ContentBlock[] {
	if (!Array.isArray(content)) return typeof content === "string" ? content : "";
	const blocks = content as ContentBlock[];
	const tag = (info: AttachmentInfo | undefined) => `${info?.mimeType ? ` type="${info.mimeType}"` : ""}${info?.stored ? ` stored="${info.stored}"` : ""}`;
	const texts: string[] = [];
	const images: ContentBlock[] = [];
	let i = 0;
	blocks.forEach((block, index) => {
		const last = index === blocks.length - 1;
		if (block.type === "image") {
			const info = infos[i++];
			texts.push(`<attachment name="${(info?.name ?? "image").replaceAll('"', "'")}"${tag(info)}/>`);
			images.push(block);
		} else if (!last && block.text.startsWith("<attachment name=")) {
			const info = infos[i++];
			texts.push(block.text.replace(/^<attachment name="([^"]*)">/, `<attachment name="$1"${tag(info)}>`));
		} else texts.push(block.text);
	});
	return [{ type: "text", text: texts.join("\n") }, ...images];
}

/** Copies one chat's shown branch into a new pi session in `cwd`; undefined when it has nothing to copy. */
export async function migrateChat(file: string, activeBranch: string | undefined, hub: ModelHub, cwd: string, sessionDir: string): Promise<string | undefined> {
	if (!existsSync(file)) return undefined;
	const storage = await openNodeSqliteStorage(file);
	const harness = await Harness.open(storage, { models: hub.models, registry: createRegistry() }, ctx);
	try {
		const root = await harness.root(ctx, {} as Parameters<Harness["root"]>[1]);
		const shown = activeBranch ? ((await harness.conversation(Number(activeBranch) as never, ctx).catch(() => undefined)) ?? root) : root;
		const view = await shown.viewState(ctx);
		const entries = view.value.entries as readonly Entry[];
		view.dispose();
		const sm = SessionManager.create(cwd, sessionDir);
		for (const e of entries) {
			if (e.kind === "pi.compaction") continue;
			for (const m of e.model ?? []) {
				if (m.role !== "user" && m.role !== "assistant" && m.role !== "toolResult") continue;
				const typed = (e.kind === USER_ENTRY || e.kind === "piopio.imported") && m.role === "user" ? (e.data as { text?: unknown; attachments?: AttachmentInfo[] } | undefined) : undefined;
				const message = typed ? { ...m, content: sdkFromDurable(m.content, typed.attachments ?? []) } : m;
				const id = sm.appendMessage(message as never);
				// What was typed, when it isn't what the model read (a `/command` the engine expanded).
				const words = typeof typed?.text === "string" ? typed.text : undefined;
				if (words?.startsWith("/")) sm.appendCustomEntry(TYPED_ENTRY, { text: words, entryId: id });
			}
		}
		const out = sm.getSessionFile();
		return out && existsSync(out) ? out : undefined;
	} finally {
		await harness.close(ctx);
	}
}
