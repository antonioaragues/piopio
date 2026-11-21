/**
 * User input with attachments. The model gets one content array: each text attachment as a tagged
 * block, each image as an image block, and the user's words last. The transcript gets a display entry
 * (`piopio.user`) with just the words and the file names.
 */
import type { Attachment, AttachmentInfo } from "@piopio/protocol";
import { EngineError } from "./models.js";

export const USER_ENTRY = "piopio.user";

/** In a pi SDK session: a `/command` as you typed it, for the message (`entryId`) pi expanded it into. */
export const TYPED_ENTRY = "piopio.typed";

export const LIMITS = { textChars: 200_000, totalTextChars: 400_000, images: 10, imageBase64Bytes: 8 * 1024 * 1024 };

export type ContentBlock = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
export type UserEntryData = { text: string; attachments: AttachmentInfo[] };
export type BuiltInput = { content: string | ContentBlock[]; entry?: { kind: string; data: UserEntryData } };

export function buildInput(text: string, attachments: readonly (Attachment & { stored?: string })[] = []): BuiltInput {
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
			infos.push({ name: a.name, kind: "image", mimeType: a.mimeType, size: Math.floor((a.data.length * 3) / 4), ...(a.stored ? { stored: a.stored } : {}) });
		} else {
			let body = a.text;
			if (body.length > LIMITS.textChars) body = `${body.slice(0, LIMITS.textChars)}\n[… truncated: the file has ${a.text.length} characters]`;
			totalText += body.length;
			if (totalText > LIMITS.totalTextChars) throw new EngineError("INVALID", "The attached files are too long together. Attach fewer or shorter files.");
			blocks.push({ type: "text", text: `<attachment name="${a.name.replaceAll('"', "'")}">\n${body}\n</attachment>` });
			infos.push({ name: a.name, kind: "text", ...(a.mimeType ? { mimeType: a.mimeType } : {}), size: a.text.length, ...(a.stored ? { stored: a.stored } : {}) });
		}
	}
	blocks.push({ type: "text", text });
	return { content: blocks, entry: { kind: USER_ENTRY, data: { text, attachments: infos } } };
}

// ── pi SDK sessions (folder conversations and chats) ─────────────────────────
//
// A pi session file is all there is, so a message's files go in the message itself. pi keeps a user message as one
// text and its images, so the text starts with the files, each in a tag that carries what the transcript's chips need
// (name, type, where Piopio keeps a copy): a text file with its contents, an image as a tag on its own (the images
// follow the text, in the same order). The words come last. `sdkUser` reads it back; chats moved from pi-durable have
// tags without the extra attributes, and images without a tag.

export type ImageBlock = { type: "image"; data: string; mimeType: string };
/** What a message sends to pi: its words, or its text (files first) and images. */
export type SdkInput = string | { text: string; images: ImageBlock[] };

const OPEN_TAG = /^<attachment name="([^"]*)"((?: [a-z]+="[^"]*")*)(\/?)>\n?/;
const CLOSE_TAG = "\n</attachment>";

const attr = (name: string, value: string | undefined) => (value ? ` ${name}="${value.replaceAll('"', "'")}"` : "");

/** A message's words with its files, as pi will keep it; the plain words when there are none. */
export function sdkContent(text: string, attachments: readonly (Attachment & { stored?: string })[] = []): SdkInput {
	const built = buildInput(text, attachments);
	if (typeof built.content === "string") return built.content;
	const infos = built.entry?.data.attachments ?? [];
	const parts: string[] = [];
	const images: ImageBlock[] = [];
	built.content.slice(0, -1).forEach((block, i) => {
		const info = infos[i];
		const tags = `${attr("type", info?.mimeType)}${attr("stored", info?.stored)}`;
		if (block.type === "image") {
			parts.push(`<attachment name="${(info?.name ?? "image").replaceAll('"', "'")}"${tags}/>`);
			images.push(block);
		} else {
			// The body as buildInput framed it; a closing tag inside it can't end the file early.
			const body = block.text.slice(block.text.indexOf("\n") + 1, block.text.length - CLOSE_TAG.length).replaceAll("</attachment>", "<\\/attachment>");
			parts.push(`<attachment name="${(info?.name ?? "file").replaceAll('"', "'")}"${tags}>\n${body}${CLOSE_TAG}`);
		}
	});
	return { text: `${parts.join("\n")}\n${text}`, images };
}

/** The notes pi adds after the words of a message with images ("[Image: original 2048x1166, displayed at…]",
 *  "[Image converted from…]", "[Image omitted: …]"): for the model only; pi writes them again on each send. */
const IMAGE_HINTS = /\n\n(\[Image[ :][^\n]*\](?:\n\[Image[ :][^\n]*\])*)$/;

/** A stored user message split into its files' part, its words, pi's notes on its images, and its images. */
export function sdkSplit(content: string | readonly ContentBlock[] | undefined): { files: string; words: string; hints: string; images: ImageBlock[]; attachments: AttachmentInfo[] } {
	const images = typeof content === "string" || !content ? [] : (content.filter((b) => b.type === "image") as ImageBlock[]);
	let rest = typeof content === "string" ? content : (content ?? []).flatMap((b) => (b.type === "text" ? [b.text] : [])).join("\n");
	const attachments: AttachmentInfo[] = [];
	let files = "";
	let image = 0;
	for (;;) {
		const m = OPEN_TAG.exec(rest);
		if (!m) break;
		const attrs = Object.fromEntries([...m[2]!.matchAll(/ ([a-z]+)="([^"]*)"/g)].map((a) => [a[1]!, a[2]!]));
		const info: AttachmentInfo = { name: m[1]!, kind: "text", ...(attrs.type ? { mimeType: attrs.type } : {}), ...(attrs.stored ? { stored: attrs.stored } : {}) };
		let length = m[0].length;
		if (m[3]) {
			const block = images[image++];
			attachments.push({ ...info, kind: "image", ...(block ? { mimeType: info.mimeType ?? block.mimeType, size: Math.floor((block.data.length * 3) / 4) } : {}) });
		} else {
			const end = rest.indexOf(CLOSE_TAG, length);
			if (end < 0) break;
			attachments.push({ ...info, size: rest.slice(length, end).replaceAll("<\\/attachment>", "</attachment>").length });
			length = end + CLOSE_TAG.length;
			if (rest[length] === "\n") length++;
		}
		files += rest.slice(0, length);
		rest = rest.slice(length);
	}
	// Images without a tag (chats from before): named by kind.
	for (const block of images.slice(image)) attachments.push({ name: "image", kind: "image", mimeType: block.mimeType, size: Math.floor((block.data.length * 3) / 4) });
	const hint = images.length ? IMAGE_HINTS.exec(rest) : null;
	const words = hint ? rest.slice(0, hint.index) : rest;
	return { files, words, hints: hint?.[1] ?? "", images, attachments };
}

/** A user message as the transcript shows it: the words, and the files as chips. */
export function sdkUser(content: string | readonly ContentBlock[] | undefined): { text: string; attachments: AttachmentInfo[] } {
	const { words, attachments } = sdkSplit(content);
	return { text: words, attachments };
}

/** A stored message again, with new words (an edit keeps its files). */
export function sdkWithWords(content: string | readonly ContentBlock[] | undefined, words: string): SdkInput {
	const split = sdkSplit(content);
	return split.files || split.images.length ? { text: split.files + words, images: split.images } : words;
}

/** A stored message as it was sent (a retry). */
export function sdkAsSent(content: string | readonly ContentBlock[] | undefined): SdkInput {
	const split = sdkSplit(content);
	return split.images.length ? { text: split.files + split.words, images: split.images } : split.files + split.words;
}
