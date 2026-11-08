/**
 * piopio-present: the agent hands over the files it made for you (docs/research/deepseek-harness.md §2.5). A report, a
 * document, an export or an image it produced, with commands or file tools, shows as a card per file that opens in
 * Piopio's viewer. Only paths and descriptions are recorded; the files stay where they are.
 */
import { statSync } from "node:fs";
import { basename, isAbsolute, resolve } from "node:path";
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type PresentedFile = { path: string; name: string; description?: string; size?: number; missing?: boolean };

export const MAX_PRESENTED = 12;

/** The files as they are now: absolute paths, sizes, and which ones don't exist. */
export function presentedFiles(cwd: string, files: readonly { path: string; description?: string }[]): PresentedFile[] {
	return files.slice(0, MAX_PRESENTED).map((f) => {
		const path = isAbsolute(f.path) ? f.path : resolve(cwd, f.path);
		const description = f.description?.trim();
		try {
			const s = statSync(path);
			return { path, name: basename(path), ...(description ? { description } : {}), ...(s.isFile() ? { size: s.size } : {}) };
		} catch {
			return { path, name: basename(path), ...(description ? { description } : {}), missing: true };
		}
	});
}

/**
 * The same, after a short wait for files that aren't there yet: models often write a file and hand it over in the
 * same step, and those tools run side by side, so the write may still be finishing (seen on a real run, 2026-11-08).
 */
export async function presentedFilesSettled(cwd: string, files: readonly { path: string; description?: string }[], waitMs = 3_000, signal?: AbortSignal): Promise<PresentedFile[]> {
	let out = presentedFiles(cwd, files);
	for (const end = Date.now() + waitMs; out.some((f) => f.missing) && Date.now() < end && !signal?.aborted; ) {
		await new Promise((r) => setTimeout(r, 100));
		out = presentedFiles(cwd, files);
	}
	return out;
}

export function presentExtension(): ExtensionFactory {
	return (pi) => {
		pi.registerTool(
			defineTool({
				name: "present_files",
				label: "Present files",
				description:
					"Hand the user the files you made for them (a report, a document, an export, an image, a build) as cards they can open. Call it once, at the end, with the final files only: not for every file you edited, and not for source code changes, which the user reviews in the diff.",
				promptSnippet: "present_files: hand the user the files you made for them",
				parameters: Type.Object({
					files: Type.Array(
						Type.Object({
							path: Type.String({ description: "The file, relative to the project or absolute." }),
							description: Type.Optional(Type.String({ description: "What it is, in a few words." })),
						}),
						{ minItems: 1, maxItems: MAX_PRESENTED },
					),
				}),
				async execute(_toolCallId, params, signal, _onUpdate, ctx) {
					const files = await presentedFilesSettled(ctx.cwd, params.files, 3_000, signal);
					const missing = files.filter((f) => f.missing);
					const shown = files.filter((f) => !f.missing);
					const lines = [
						...(shown.length ? [`Shown to the user: ${shown.map((f) => f.name).join(", ")}.`] : []),
						...(missing.length ? [`Not found, so not shown: ${missing.map((f) => f.path).join(", ")}. Check the paths.`] : []),
					];
					return { content: [{ type: "text", text: lines.join("\n") }], details: { files }, ...(shown.length === 0 ? { isError: true } : {}) } as never;
				},
			}),
		);
	};
}
