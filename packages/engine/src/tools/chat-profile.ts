/**
 * Read only for project sessions (docs/spec/18 §4, before that the Chat lens of 04-chat §2): a knowledge assistant
 * over the folder's files, with web search and page reading, and no bash, edit or write. Every Build session has the
 * extension; `active` says whether the session is in Read only now (the runtime switches the tools to match).
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { ModelHub } from "../models.js";
import { runWebFetch, runWebSearch, webSection, type WebOptions } from "./web.js";

/** What Read only takes away from a Build session, and what it adds. */
export const READ_ONLY_OFF = ["bash", "edit", "write"];
export const READ_ONLY_ON = ["grep", "find", "ls", "web_search", "web_fetch"];

const KNOWLEDGE_PROMPT = `
# Knowledge assistant
You're working in a folder of documents rather than a code base: notes, papers, plans, spreadsheets as text, images.
- Answer from the folder's files first: find them with ls, find and grep, read them, and cite the files you used (path and the relevant lines).
- Use web_search and web_fetch for current or outside information, and link the sources.
- You can't change files or run commands in this conversation (it's Read only). When the user asks for a change, say what you would change and that they can switch the conversation to Ask or Auto-edit.`;

export function chatProfileExtension(hub: ModelHub, options: WebOptions = {}, active: () => boolean = () => true): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => (active() ? { systemPrompt: `${event.systemPrompt}\n${KNOWLEDGE_PROMPT}\n\n${webSection()}` } : undefined));
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
