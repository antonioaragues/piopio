/**
 * `make_app` (docs/spec/35 §14): turns a chart or a small page into an app that reads its data from files, so it stays
 * current without a model. The engine writes the manifest itself (paths relative to the app's file), copies sources
 * out of a chat's temporary folder, and writes nothing until the user allows the card that names those files.
 */
import { Type } from "typebox";
import { defineTool as defineCodingTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { Apps, MakeContext } from "../apps.js";
import { promptSection, type PromptEvent } from "./prompt-sections.js";

export const MAKE_APP = "make_app";

/** How a conversation asks before the app is written: true when the user allowed it. */
export type AppConfirm = (request: { tool: string; title: string; args: Record<string, unknown> }) => Promise<{ approved: boolean; reason?: string }>;

const DESCRIPTION = `Make an app: a page that reads its data from files and redraws when they change, with no model. Use it when the user asks for an app, or to keep a chart you drew (show_visual) up to date ("Make the … visual into an app"). The user sees a card naming the files it will read and where it's saved, and allows it; nothing is written before.
- sources: each one a file the page reads, by a name you choose: { "expenses": { "file": "data/expenses.csv", "columns": ["date", "category", "amount"] } }. CSV, TSV, JSON, Markdown or text, at most 2 MB. List in columns the CSV columns the page needs: if the file loses one, the app says so instead of drawing wrong numbers. Figures that exist only in this conversation: write them to a CSV file first, then read that.
- html: like show_visual's (Piopio's CSS variables, bundled libraries, no network), but with no data in it. Draw from piopio.onData((data, meta) => draw(data)): data.expenses is the CSV's rows as objects by column (plain numbers already numbers, everything else text), a JSON file's value, or a text file's text. It's called again whenever a file changes, so draw everything from scratch each time.
- Every number, label and conclusion must come from data: totals, counts, averages, categories, the latest rows, "over budget". Nothing copied from this conversation, or the app goes wrong when the file changes.
- meta.stale lists sources whose latest read failed (their data is the last good one); Piopio already says why above the page.`;

const PARAMETERS = Type.Object({
	title: Type.String({ description: "The app's name, 1 to 4 words: 'Spending'." }),
	html: Type.String({ description: "The page: an HTML fragment that draws from piopio.onData. No data in it." }),
	sources: Type.Record(
		Type.String(),
		Type.Object({
			file: Type.String({ description: "The file, relative to your folder or absolute." }),
			columns: Type.Optional(Type.Array(Type.String(), { description: "For a CSV or TSV: the columns the page needs." })),
		}),
		{ description: "Where the data comes from, by name (letters, digits and _)." },
	),
});

/** Chats and Build sessions (pi-coding-agent). */
export function codingAppsExtension(apps: Apps, where: () => MakeContext, confirmFor: (callId: string, signal: AbortSignal | undefined) => AppConfirm): ExtensionFactory {
	return (pi) => {
		pi.registerTool(
			defineCodingTool({
				name: MAKE_APP,
				label: "Make an app",
				description: DESCRIPTION,
				promptSnippet: `${MAKE_APP}: make an app that reads its data from files and stays current`,
				parameters: PARAMETERS,
				async execute(callId, params, signal) {
					const text = (t: string, isError = false) => ({ content: [{ type: "text" as const, text: t }], details: {}, ...(isError ? { isError: true } : {}) }) as never;
					let plan;
					try {
						plan = apps.plan({ title: params.title, html: params.html, sources: params.sources }, where());
					} catch (error) {
						return text(`Not made: ${(error as Error).message}`, true);
					}
					const answer = await confirmFor(callId, signal)({ tool: MAKE_APP, title: plan.summary, args: { title: params.title, sources: params.sources } });
					if (!answer.approved) return text(`The user didn't make the app${answer.reason ? `: ${answer.reason}` : "."} Nothing was written.`);
					try {
						const view = apps.write(plan);
						const failed = view.sources.filter((s) => s.state === "failed");
						const note = failed.length ? ` Some sources failed: ${failed.map((s) => `${s.name}: ${s.error}`).join("; ")}.` : "";
						return {
							content: [{ type: "text", text: `Made “${plan.title}” at ${plan.path}. It's in the Library; the user opens it from the card or the Library, and it redraws when its files change.${note}` }],
							details: { files: [{ path: plan.path, name: plan.path.split("/").pop(), description: `App: ${plan.title}` }] },
						} as never;
					} catch (error) {
						return text(`It couldn't be written: ${(error as Error).message}`, true);
					}
				},
			}),
		);
	};
}

/** An app's conversation (docs/spec/35 §15): what it's about, read fresh each turn (the page may have changed). */
export function appConversationExtension(apps: Apps, path: string): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			promptSection(event as unknown as PromptEvent, "app", apps.describe(path));
			return undefined;
		});
	};
}
