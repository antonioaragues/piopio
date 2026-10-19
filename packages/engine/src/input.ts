/**
 * User input with attachments. The model gets one content array: each text attachment as a tagged
 * block, each image as an image block, and the user's words last. The transcript gets a display entry
 * (`piopio.user`) with just the words and the file names.
 */
import type { Attachment, AttachmentInfo } from "@piopio/protocol";
import { EngineError } from "./models.js";

export const USER_ENTRY = "piopio.user";

export const LIMITS = { textChars: 200_000, totalTextChars: 400_000, images: 10, imageBase64Bytes: 8 * 1024 * 1024 };

export type ContentBlock = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
export type UserEntryData = { text: string; attachments: AttachmentInfo[] };
export type BuiltInput = { content: string | ContentBlock[]; entry?: { kind: string; data: UserEntryData } };

export function isUserEntry(kind: string): boolean {
	return kind === "pi.user" || kind === USER_ENTRY;
}

export function buildInput(text: string, attachments: readonly Attachment[] = []): BuiltInput {
	if (attachments.length === 0) return { content: text };
	const images = attachments.filter((a) => a.kind === "image");
	if (images.length > LIMITS.images) throw new EngineError("INVALID", `At most ${LIMITS.images} images per message.`);
	const blocks: ContentBlock[] = [];
	const infos: AttachmentInfo[] = [];
	let totalText = 0;
	for (const a of attachments) {
		if (a.kind === "image") {
			if (a.data.length > LIMITS.imageBase64Bytes) throw new EngineError("INVALID", `${a.name} is too large; images are limited to about 6 MB.`);
			blocks.push({ type: "image", data: a.data, mimeType: a.mimeType });
			infos.push({ name: a.name, kind: "image", mimeType: a.mimeType, size: Math.floor((a.data.length * 3) / 4) });
		} else {
			let body = a.text;
			if (body.length > LIMITS.textChars) body = `${body.slice(0, LIMITS.textChars)}\n[… truncated: the file has ${a.text.length} characters]`;
			totalText += body.length;
			if (totalText > LIMITS.totalTextChars) throw new EngineError("INVALID", "The attached files are too long together. Attach fewer or shorter files.");
			blocks.push({ type: "text", text: `<attachment name="${a.name.replaceAll('"', "'")}">\n${body}\n</attachment>` });
			infos.push({ name: a.name, kind: "text", ...(a.mimeType ? { mimeType: a.mimeType } : {}), size: a.text.length });
		}
	}
	blocks.push({ type: "text", text });
	return { content: blocks, entry: { kind: USER_ENTRY, data: { text, attachments: infos } } };
}

/** The same input with new words (edits keep the attachments). */
export function withText(content: unknown, entry: { kind: string; data?: unknown }, text: string): BuiltInput {
	if (entry.kind !== USER_ENTRY || !Array.isArray(content)) return { content: text };
	const blocks = (content as ContentBlock[]).slice(0, -1).concat({ type: "text", text });
	const data = entry.data as UserEntryData;
	return { content: blocks, entry: { kind: USER_ENTRY, data: { ...data, text } } };
}

/** The stored input, as it was submitted (regenerate). */
export function asSubmitted(content: unknown, entry: { kind: string; data?: unknown }): BuiltInput {
	if (entry.kind === USER_ENTRY && Array.isArray(content)) return { content: content as ContentBlock[], entry: { kind: USER_ENTRY, data: entry.data as UserEntryData } };
	return { content: typeof content === "string" ? content : (content as ContentBlock[]).filter((b) => b.type === "text").map((b) => (b as { text: string }).text).join("\n") };
}
