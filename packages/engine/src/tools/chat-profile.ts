/**
 * The Chat lens profile for project sessions (docs/spec/04-chat §2): a knowledge assistant over the
 * folder's documents, with web search and page reading, and no bash (the session drops it).
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { ModelHub } from "../models.js";
import { runWebFetch, runWebSearch, webSection, type WebOptions } from "./web.js";

/** pi's tool selection for the chat profile: the default tools minus bash, plus the read-only finders. */
export const CHAT_TOOLS = ["-bash", "+grep", "+find", "+ls"];

const KNOWLEDGE_PROMPT = `
# Knowledge assistant
You're working in a folder of documents rather than a code base: notes, papers, plans, spreadsheets as text, images.
- Answer from the folder's files first: find them with ls, find and grep, read them, and cite the files you used (path and the relevant lines).
- Use web_search and web_fetch for current or outside information, and link the sources.
- Write or edit files only when the user asks for a document or a change; keep their formatting.`;

export function chatProfileExtension(hub: ModelHub, options: WebOptions = {}): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => ({ systemPrompt: `${event.systemPrompt}\n${KNOWLEDGE_PROMPT}\n\n${webSection()}` }));
		pi.registerTool(
			defineTool({
				name: "web_search",
				label: "Search the web",
				description: "Search the web for current information. Returns a short summary and the sources (title, URL, snippet). Use it for recent events, facts you are unsure about, or anything that may have changed.",
				promptSnippet: "web_search: search the web",
				parameters: Type.Object({ query: Type.String({ description: "What to search for" }), max_results: Type.Optional(Type.Number({ minimum: 1, maximum: 10 })) }),
				async execute(_id, params) {
					const r = await runWebSearch(hub, params, options);
					return { content: [{ type: "text", text: r.text }], details: r.details ?? {}, ...(r.isError ? { isError: true } : {}) };
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "web_fetch",
				label: "Read a web page",
				description: "Read a web page (http/https) and return its main content as markdown. Use it to read sources found with web_search or links the user shares.",
				promptSnippet: "web_fetch: read a web page",
				parameters: Type.Object({ url: Type.String({ description: "The page URL" }) }),
				async execute(_id, params) {
					const r = await runWebFetch(params.url, options);
					return { content: [{ type: "text", text: r.text }], details: r.details ?? {}, ...(r.isError ? { isError: true } : {}) };
				},
			}),
		);
	};
}
