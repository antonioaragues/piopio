/**
 * Web tools for chat: `web_search` (OpenRouter's web plugin, with the user's key) and `web_fetch`
 * (download a page as markdown). Fetching refuses private and local addresses, re-checking every
 * redirect, so a page or prompt can't make the agent probe the user's network.
 */
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import type { ModelHub } from "../models.js";
import { htmlToMarkdown } from "./html.js";

export const WEB_EXTENSION = "piopio-web";
const MAX_PAGE_BYTES = 3 * 1024 * 1024;
const MAX_OUTPUT_CHARS = 25_000;

export type WebOptions = {
	/** Allow fetching localhost/private addresses (tests only). */
	allowPrivate?: boolean;
	/** Model that runs OpenRouter's web plugin (cheap and fast is fine: the results are what matter). */
	searchModel?: string;
	fetchImpl?: typeof fetch;
};

export function createWebExtension(hub: ModelHub, options: WebOptions = {}) {
	const fetchImpl = options.fetchImpl ?? fetch;

	const webSearch = defineTool({
		name: "web_search",
		description: "Search the web for current information. Returns a short summary and the sources (title, URL, snippet). Use it for recent events, facts you are unsure about, or anything that may have changed.",
		parameters: Type.Object({ query: Type.String({ description: "What to search for" }), max_results: Type.Optional(Type.Number({ minimum: 1, maximum: 10 })) }),
		execute: async (args) => {
			await hub.ensureCredential("openrouter");
			const credential = await hub.credentials.read("openrouter");
			const key = credential?.type === "api_key" ? credential.key : undefined;
			if (!key) return { output: [{ type: "text", text: "Web search needs an OpenRouter key." }], isError: true };
			const response = await fetchImpl("https://openrouter.ai/api/v1/chat/completions", {
				method: "POST",
				headers: { authorization: `Bearer ${key}`, "content-type": "application/json", "x-title": "Piopio" },
				body: JSON.stringify({
					model: options.searchModel ?? process.env.PIOPIO_SEARCH_MODEL ?? "deepseek/deepseek-v4.1-flash",
					plugins: [{ id: "web", max_results: Math.round(args.max_results ?? 5) }],
					messages: [{ role: "user", content: `Search the web and summarize what you find, briefly and factually, citing sources.\n\nQuery: ${args.query}` }],
				}),
				signal: AbortSignal.timeout(60_000),
			});
			const body = await response.text();
			if (!response.ok) return { output: [{ type: "text", text: `Web search failed (${response.status}): ${body.slice(0, 300)}` }], isError: true };
			const { summary, sources } = parseSearchResponse(JSON.parse(body));
			return { output: [{ type: "text", text: formatSearch(args.query, summary, sources) }], details: { type: "web", results: sources } };
		},
	});

	const webFetch = defineTool({
		name: "web_fetch",
		description: "Read a web page (http/https) and return its main content as markdown. Use it to read sources found with web_search or links the user shares.",
		parameters: Type.Object({ url: Type.String({ description: "The page URL" }) }),
		execute: async (args) => {
			const page = await fetchPage(args.url, { allowPrivate: options.allowPrivate ?? false, fetchImpl });
			if ("error" in page) return { output: [{ type: "text", text: page.error }], isError: true };
			let text = page.markdown;
			if (text.length > MAX_OUTPUT_CHARS) text = `${text.slice(0, MAX_OUTPUT_CHARS)}\n\n[… truncated: the page has ${page.markdown.length} characters]`;
			return { output: [{ type: "text", text: `# ${page.title || page.url}\nSource: ${page.url}\n\n${text}` }], details: { type: "page", url: page.url, title: page.title } };
		},
	});

	return defineExtension({
		name: WEB_EXTENSION,
		tools: [webSearch, webFetch],
		sections: [
			section("web", () => `You can search the web with web_search and read pages with web_fetch. Use them when the answer depends on current or specific information, and link the sources you used. Today is ${new Date().toISOString().slice(0, 10)}.`),
		],
	});
}

// MARK: Search

export type SearchSource = { title: string; url: string; snippet: string };

/** OpenRouter returns the plugin's results as `url_citation` annotations on the message. */
export function parseSearchResponse(json: unknown): { summary: string; sources: SearchSource[] } {
	const message = (json as { choices?: { message?: { content?: string; annotations?: unknown[] } }[] }).choices?.[0]?.message;
	const sources: SearchSource[] = [];
	const seen = new Set<string>();
	for (const a of message?.annotations ?? []) {
		const c = (a as { type?: string; url_citation?: { url?: string; title?: string; content?: string } }).url_citation;
		if ((a as { type?: string }).type !== "url_citation" || !c?.url || seen.has(c.url)) continue;
		seen.add(c.url);
		sources.push({ title: c.title?.trim() || c.url, url: c.url, snippet: (c.content ?? "").replace(/\s+/g, " ").trim().slice(0, 400) });
	}
	return { summary: (message?.content ?? "").trim(), sources };
}

function formatSearch(query: string, summary: string, sources: SearchSource[]): string {
	const list = sources.map((s, i) => `${i + 1}. ${s.title}\n   ${s.url}${s.snippet ? `\n   ${s.snippet}` : ""}`).join("\n");
	return `Results for "${query}"\n\n${summary}\n\nSources:\n${list || "(none returned)"}`;
}

// MARK: Fetch

export async function fetchPage(rawUrl: string, options: { allowPrivate: boolean; fetchImpl: typeof fetch }): Promise<{ url: string; title: string; markdown: string } | { error: string }> {
	let url: URL;
	try {
		url = new URL(rawUrl);
	} catch {
		return { error: `Not a valid URL: ${rawUrl}` };
	}
	for (let hop = 0; hop <= 5; hop++) {
		if (url.protocol !== "http:" && url.protocol !== "https:") return { error: "Only http and https pages can be read." };
		if (!options.allowPrivate && (await isPrivateHost(url.hostname))) return { error: `Refusing to read ${url.hostname}: it is a local or private network address.` };
		const response = await options.fetchImpl(url, { redirect: "manual", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Piopio/0.1", accept: "text/html,text/plain,application/json;q=0.9,*/*;q=0.5" }, signal: AbortSignal.timeout(30_000) });
		if (response.status >= 300 && response.status < 400 && response.headers.get("location")) {
			url = new URL(response.headers.get("location")!, url);
			continue;
		}
		if (!response.ok) return { error: `The page returned HTTP ${response.status}.` };
		const type = response.headers.get("content-type") ?? "";
		const body = await readCapped(response, MAX_PAGE_BYTES);
		if (/html/i.test(type) || /^\s*</.test(body)) {
			const { title, markdown } = htmlToMarkdown(body, url.toString());
			return { url: url.toString(), title, markdown };
		}
		if (/^text\/|json|xml|javascript/i.test(type)) return { url: url.toString(), title: "", markdown: body };
		return { error: `Can't read this kind of content (${type || "unknown type"}).` };
	}
	return { error: "Too many redirects." };
}

async function readCapped(response: Response, max: number): Promise<string> {
	if (!response.body) return "";
	const reader = response.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	while (total < max) {
		const { done, value } = await reader.read();
		if (done) break;
		chunks.push(value);
		total += value.byteLength;
	}
	await reader.cancel().catch(() => undefined);
	return new TextDecoder().decode(Buffer.concat(chunks).subarray(0, max));
}

export async function isPrivateHost(hostname: string): Promise<boolean> {
	const host = hostname.replace(/^\[|\]$/g, "").toLowerCase();
	if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) return true;
	const addresses = isIP(host) ? [host] : await lookup(host, { all: true }).then((r) => r.map((a) => a.address)).catch(() => []);
	return addresses.some(isPrivateAddress);
}

export function isPrivateAddress(address: string): boolean {
	if (isIP(address) === 4) {
		const [a, b] = address.split(".").map(Number) as [number, number];
		return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
	}
	const v6 = address.toLowerCase();
	if (v6.startsWith("::ffff:")) return isPrivateAddress(v6.slice(7));
	return v6 === "::1" || v6 === "::" || v6.startsWith("fc") || v6.startsWith("fd") || v6.startsWith("fe80");
}
