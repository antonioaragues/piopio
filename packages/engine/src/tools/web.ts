/**
 * Web tools for chat: `web_search` (OpenRouter's web plugin, with the user's key) and `web_fetch`
 * (download a page as markdown). Fetching refuses private and local addresses, re-checking every
 * redirect, so a page or prompt can't make the agent probe the user's network.
 */
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { request as httpRequest, type RequestOptions } from "node:http";
import { request as httpsRequest } from "node:https";
import { Readable } from "node:stream";
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
	/** Root container whose search requests are billed. */
	scope?: string;
};

export function createWebExtension(hub: ModelHub, options: WebOptions = {}) {
	const fetchImpl = options.fetchImpl ?? fetch;

	const webSearch = defineTool({
		name: "web_search",
		description: "Search the web for current information. Returns a short summary and the sources (title, URL, snippet). Use it for recent events, facts you are unsure about, or anything that may have changed.",
		parameters: Type.Object({ query: Type.String({ description: "What to search for" }), max_results: Type.Optional(Type.Number({ minimum: 1, maximum: 10 })) }),
		execute: async (args) => {
			const r = await runWebSearch(hub, args, { ...options, fetchImpl });
			return { output: [{ type: "text", text: r.text }], ...(r.isError ? { isError: true } : {}), ...(r.details ? { details: r.details as never } : {}) };
		},
	});

	const webFetch = defineTool({
		name: "web_fetch",
		description: "Read a web page (http/https) and return its main content as markdown. Use it to read sources found with web_search or links the user shares.",
		parameters: Type.Object({ url: Type.String({ description: "The page URL" }) }),
		execute: async (args) => {
			const r = await runWebFetch(args.url, { ...options, fetchImpl });
			return { output: [{ type: "text", text: r.text }], ...(r.isError ? { isError: true } : {}), ...(r.details ? { details: r.details as never } : {}) };
		},
	});

	return defineExtension({
		name: WEB_EXTENSION,
		tools: [webSearch, webFetch],
		sections: [section("web", webSection)],
	});
}

/** System prompt note for the web tools. */
export const webSection = () =>
	`You can search the web with web_search and read pages with web_fetch. Use them when the answer depends on current or specific information, and link the sources you used. Today is ${new Date().toISOString().slice(0, 10)}.`;

export type WebResult = { text: string; isError?: boolean; details?: Record<string, unknown> };

/** web_search, shared by the pi-durable (threads) and pi SDK (Chat-lens projects) tools. */
export async function runWebSearch(hub: ModelHub, args: { query: string; max_results?: number }, options: WebOptions = {}): Promise<WebResult> {
	const fetchImpl = options.fetchImpl ?? fetch;
	// Search runs through OpenRouter's web plugin, whatever model the conversation uses (docs/spec/10 §10.7).
	const credential = await hub.credentials.read("openrouter").catch(() => undefined);
	const key = credential?.type === "api_key" ? credential.key : undefined;
	if (!key) return { text: "Web search needs OpenRouter connected (Settings › Models). Tell the user, and answer from what you know.", isError: true };
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
	if (!response.ok) return { text: `Web search failed (${response.status}): ${body.slice(0, 300)}`, isError: true };
	const json = JSON.parse(body) as { usage?: { cost?: number } };
	hub.extraCosts.record("web_search", options.searchModel ?? process.env.PIOPIO_SEARCH_MODEL ?? "deepseek/deepseek-v4.1-flash", json.usage?.cost, options.scope);
	const { summary, sources } = parseSearchResponse(json);
	return { text: formatSearch(args.query, summary, sources), details: { type: "web", results: sources } };
}

/** web_fetch, shared like runWebSearch. */
export async function runWebFetch(url: string, options: WebOptions = {}): Promise<WebResult> {
	const page = await fetchPage(url, { allowPrivate: options.allowPrivate ?? false, fetchImpl: options.fetchImpl ?? fetch });
	if ("error" in page) return { text: page.error, isError: true };
	let text = page.markdown;
	if (text.length > MAX_OUTPUT_CHARS) text = `${text.slice(0, MAX_OUTPUT_CHARS)}\n\n[… truncated: the page has ${page.markdown.length} characters]`;
	return { text: `# ${page.title || page.url}\nSource: ${page.url}\n\n${text}`, details: { type: "page", url: page.url, title: page.title } };
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
		const fetchImpl = !options.allowPrivate && options.fetchImpl === fetch ? publicFetch : options.fetchImpl;
		const response = await fetchImpl(url, { redirect: "manual", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Piopio/0.1", accept: "text/html,text/plain,application/json;q=0.9,*/*;q=0.5" }, signal: AbortSignal.timeout(30_000) });
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
	return addresses.length === 0 || addresses.some(isPrivateAddress);
}

export function isPrivateAddress(address: string): boolean {
	if (isIP(address) === 4) {
		const [a, b, c] = address.split(".").map(Number) as [number, number, number];
		return a >= 224 || (a === 192 && (b === 0 || b === 2)) || (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) || (a === 203 && b === 0 && c === 113) || a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
	}
	if (isIP(address) !== 6) return true;
	// URL canonicalization turns dotted IPv4 mappings into hexadecimal IPv6 groups.
	const normalized = new URL(`http://[${address}]/`).hostname.slice(1, -1);
	if (normalized.startsWith("::ffff:")) {
		const tail = normalized.slice(7).split(":");
		const value = parseInt(tail[0]!, 16) * 65536 + parseInt(tail[1]!, 16);
		return isPrivateAddress([value >>> 24, (value >>> 16) & 255, (value >>> 8) & 255, value & 255].join("."));
	}
	// Accept global unicast only. This also excludes unspecified, link-local, multicast,
	// unique-local, IPv4-compatible and transition ranges.
	return !/^[23][0-9a-f]{3}:/.test(normalized) || normalized.startsWith("2001:db8:") || normalized.startsWith("2002:") || normalized.startsWith("2001:0:") || normalized.startsWith("2001::");
}


/** Resolve once and pin the checked address to the actual connection, retaining hostname/TLS checks.
 * Redirects return to fetchPage and go through the same validation. No connection pool can reuse an
 * unchecked DNS result. Tests can inject fetchImpl; production always uses this transport.
 */
const publicFetch: typeof fetch = async (input, init) => {
	const url = new URL(String(input));
	const host = url.hostname.replace(/^\[|\]$/g, "");
	const addresses = isIP(host) ? [{ address: host, family: isIP(host) }] : await lookup(host, { all: true });
	if (!addresses.length || addresses.some(a => isPrivateAddress(a.address))) throw new Error("Refusing a local or private network address.");
	const address = addresses[0]!;
	return new Promise<Response>((resolve, reject) => {
		const requestOptions: RequestOptions & { autoSelectFamily: boolean } = {
			method: "GET", agent: false, autoSelectFamily: false,
			headers: Object.fromEntries(new Headers(init?.headers)),
			...(init?.signal ? { signal: init.signal } : {}),
			lookup: (_hostname, _options, callback) => callback(null, address.address, address.family),
		};
		const request = (url.protocol === "https:" ? httpsRequest : httpRequest)(url, requestOptions, response => {
			const headers = new Headers();
			for (const [key, value] of Object.entries(response.headers)) if (value !== undefined) headers.set(key, Array.isArray(value) ? value.join(", ") : value);
			const status = response.statusCode ?? 502;
			resolve(new Response([101, 204, 205, 304].includes(status) ? null : Readable.toWeb(response) as ReadableStream<Uint8Array>, { status, headers }));
		});
		request.on("error", reject);
		request.end();
	});
};
