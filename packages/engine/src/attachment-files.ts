/**
 * Sent files, kept so the app can show them again (roadmap D8). Each one lives at
 * `<home>/attachments/<container id>/<random>/<name>`: the original when the app says where it is on this Mac (a PDF
 * stays a PDF, an image keeps its full size), otherwise what was sent (the downscaled image, the text). The transcript
 * records `<random>/<name>`, so a branched thread can carry a copy of the folder. Everything stays on this Mac and goes
 * when the conversation is deleted.
 */
import { randomBytes } from "node:crypto";
import { copyFileSync, cpSync, existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, extname, join } from "node:path";
import type { Attachment } from "@piopio/protocol";

/** An attachment with where its copy is kept, relative to the conversation's folder. */
export type KeptAttachment = Attachment & { stored?: string };

/** Originals larger than this aren't copied; what was sent is kept instead. */
export const MAX_ORIGINAL_BYTES = 100 * 1024 * 1024;

export function attachmentsDir(home: string, containerId: string): string {
	return join(home, "attachments", containerId);
}

/** A name safe to use as a file name: no folders, no leading dots. */
function safeName(name: string): string {
	const clean = basename(name.replaceAll("\\", "/")).replace(/^\.+/, "").replace(/[\u0000-\u001f]/g, "").trim();
	return clean.length > 0 ? clean.slice(0, 200) : "file";
}

/** Copies each file into the conversation's folder and notes where; a file that can't be kept is still sent. */
export function keepAttachments(home: string, containerId: string, attachments: readonly Attachment[]): KeptAttachment[] {
	return attachments.map((a) => {
		try {
			const id = randomBytes(6).toString("hex");
			let name = safeName(a.name);
			const dir = join(attachmentsDir(home, containerId), id);
			mkdirSync(dir, { recursive: true, mode: 0o700 });
			const original = a.path && existsSync(a.path) ? statSync(a.path) : undefined;
			if (a.path && original?.isFile() && original.size <= MAX_ORIGINAL_BYTES) {
				copyFileSync(a.path, join(dir, name));
			} else if (a.kind === "image") {
				writeFileSync(join(dir, name), Buffer.from(a.data, "base64"));
			} else {
				// Text read out of a document (a PDF) is kept as text, so the viewer doesn't take it for a PDF.
				if (a.mimeType && !a.mimeType.startsWith("text/") && extname(name).toLowerCase() !== ".txt" && !/json|xml|javascript|yaml|toml|x-sh/.test(a.mimeType)) name = `${name}.txt`;
				writeFileSync(join(dir, name), a.text);
			}
			const { path: _, ...rest } = a;
			return { ...rest, stored: `${id}/${name}` } as KeptAttachment;
		} catch {
			const { path: _, ...rest } = a;
			return rest as KeptAttachment;
		}
	});
}

/** A branched thread gets its own copy of the files. */
export function copyAttachments(home: string, from: string, to: string): void {
	const source = attachmentsDir(home, from);
	if (existsSync(source)) cpSync(source, attachmentsDir(home, to), { recursive: true });
}

export function deleteAttachments(home: string, containerId: string): void {
	rmSync(attachmentsDir(home, containerId), { recursive: true, force: true });
}
