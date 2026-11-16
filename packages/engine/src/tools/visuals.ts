/**
 * Visuals (docs/spec/25): the model shows a chart, a diagram, a few UI options or a small explainer as live HTML in
 * the conversation, with `show_visual`. The engine only records it: the HTML stays in the tool call's arguments, so
 * any client draws it again when it opens the conversation, and the Mac app draws it in a sandboxed web view with no
 * network (§5). Defined once, with an extension for pi-coding-agent (chats and Build) and one for pi-durable (agents).
 */
import { Type } from "@earendil-works/pi-ai";
import { defineTool as defineCodingTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";

export const VISUALS_EXTENSION = "piopio-visuals";
export const SHOW_VISUAL = "show_visual";
/** Larger than any reasonable visual; a page this size is data that belongs in a file. */
export const MAX_VISUAL_BYTES = 300 * 1024;

const DESCRIPTION =
	"Show the user a visual in the conversation: a chart, a diagram of how something works, UI or layout options to pick from, or a small interactive explainer. It is drawn right away as live HTML in Piopio's colours, with no network. Not for what text, a list or a table says as well, nor for documents (write a file) or code to copy (a code block).";

const PARAMETERS = Type.Object({
	title: Type.String({ description: "Shown above the visual, 2 to 6 words: 'Usage card: three options'." }),
	html: Type.String({ description: "An HTML fragment (no <html>, <head> or <body>: Piopio wraps it) or a whole document. Inline <style> and <script>; libraries only from piopio-lib:// (see the Visuals section)." }),
});

/** The system prompt section: when to show a visual, and how to make one that fits. */
export const VISUALS_SECTION = `# Visuals
You can show the user a visual with ${SHOW_VISUAL}: live HTML drawn in the conversation, between your paragraphs.
- When: numbers that compare or change over time; how something works (parts and the flow between them); UI or layout options to choose from; a small interactive explainer. Not for what a sentence, a list or a table says as well; not for long documents (write a file); not for code the user will copy (a code block). One visual per idea; say in a sentence what it shows.
- Size: it fills the column's width (about 560 to 900 px); its height follows its content, up to about 900 px. No fixed widths, no page background (it sits on the conversation's), no outer margins.
- Look: use these CSS variables, which follow the app's light and dark mode: --fg, --fg2, --fg3 (text, strong to faint), --line (hairlines), --card and --bubble (raised and quiet surfaces), --chip (hover), --accent, --green, --amber, --red, --c1 to --c8 (chart series, in that order), --radius (8px), --radius-card (12px), --font, --font-mono. Buttons, inputs and tables are already styled like the app's.
- No network: nothing loads from the internet or the user's disk. Put data in the HTML. Libraries are bundled: <script src="piopio-lib://chart.js"></script> (Chart.js 4, global Chart), <script src="piopio-lib://d3.js"></script> (d3 7, global d3), <script src="piopio-lib://katex/katex.js"></script> with <link rel="stylesheet" href="piopio-lib://katex/katex.css"> (KaTeX), and three.js r169 as a module: <script type="module">import * as THREE from "three"; import { OrbitControls } from "three/addons/controls/OrbitControls.js";</script>. For diagrams, write SVG yourself.
- Options to pick from: label them A, B, C, and give each a button that calls piopio.send("Go with B"): when the user clicks it, that text is sent as their message.
- A changed version is a new ${SHOW_VISUAL} call; the old one stays where it was.
- Visuals show only in Piopio's window. When the person reads you in a message channel (Telegram, WhatsApp), say it in words instead.`;

export type VisualArgs = { title: string; html: string };

/** What the tool answers: a short line, or why the visual can't be shown. The HTML isn't repeated back. */
export function showVisual(args: { title?: unknown; html?: unknown }): { text: string; isError?: boolean } {
	const title = typeof args.title === "string" ? args.title.trim() : "";
	const html = typeof args.html === "string" ? args.html : "";
	if (!html.trim()) return { text: "Nothing to show: html is empty.", isError: true };
	const bytes = Buffer.byteLength(html, "utf8");
	if (bytes > MAX_VISUAL_BYTES) return { text: `Not shown: the HTML is ${Math.round(bytes / 1024)} KB, over the ${MAX_VISUAL_BYTES / 1024} KB limit. Make it smaller (less data, no inlined libraries), or write it to a file.`, isError: true };
	if (/\b(?:src|href)\s*=\s*["']?\s*https?:/i.test(html) || /\bfetch\s*\(\s*["'`]https?:/i.test(html))
		return { text: `Shown as "${title || "Visual"}", but it refers to the internet, which a visual can't reach: those parts won't load. Use the bundled libraries and put the data in the HTML.` };
	return { text: `Shown to the user as "${title || "Visual"}".` };
}

/** Chats and Build sessions (pi-coding-agent). */
export function codingVisualsExtension(): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => ({ systemPrompt: `${event.systemPrompt}\n\n${VISUALS_SECTION}` }));
		pi.registerTool(
			defineCodingTool({
				name: SHOW_VISUAL,
				label: "Show a visual",
				description: DESCRIPTION,
				promptSnippet: `${SHOW_VISUAL}: show a chart, diagram or UI options as live HTML in the conversation`,
				parameters: PARAMETERS,
				async execute(_callId, params) {
					const r = showVisual(params);
					return { content: [{ type: "text", text: r.text }], details: {}, ...(r.isError ? { isError: true } : {}) } as never;
				},
			}),
		);
	};
}

/** Agents (pi-durable). */
export function durableVisualsExtension() {
	return defineExtension({
		name: VISUALS_EXTENSION,
		tools: [
			defineTool({
				name: SHOW_VISUAL,
				description: DESCRIPTION,
				parameters: PARAMETERS,
				execute: async (args) => {
					const r = showVisual(args);
					return { output: [{ type: "text", text: r.text }], ...(r.isError ? { isError: true } : {}) };
				},
			}),
		],
		sections: [section("visuals", () => VISUALS_SECTION)],
	});
}
