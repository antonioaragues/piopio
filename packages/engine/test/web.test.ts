import { describe, expect, test } from "vitest";
import { buildInput, withText } from "../src/input.js";
import { htmlToMarkdown } from "../src/tools/html.js";
import { fetchPage, isPrivateHost, isPrivateAddress, parseSearchResponse } from "../src/tools/web.js";

describe("htmlToMarkdown", () => {
	test("keeps the main content as markdown and drops page chrome", () => {
		const html = `<html><head><title>Doc  Title</title><style>x{}</style></head><body>
			<nav><a href="/">Home</a></nav>
			<main><h1>Hello</h1><p>Some <strong>bold</strong> and <a href="/rel">a link</a>.</p>
			<ul><li>one</li><li>two</li></ul><pre>code  here</pre><script>evil()</script></main>
			<footer>footer</footer></body></html>`;
		const { title, markdown } = htmlToMarkdown(html, "https://example.com/a/");
		expect(title).toBe("Doc Title");
		expect(markdown).toContain("# Hello");
		expect(markdown).toContain("Some **bold** and [a link](https://example.com/rel).");
		expect(markdown).toContain("- one\n- two");
		expect(markdown).toContain("```\ncode  here\n```");
		expect(markdown).not.toMatch(/Home|footer|evil/);
	});
});

test("parses OpenRouter web plugin citations", () => {
	const json = {
		choices: [{ message: { content: "Summary text.", annotations: [
			{ type: "url_citation", url_citation: { url: "https://a.example", title: "A", content: "first   snippet" } },
			{ type: "url_citation", url_citation: { url: "https://a.example", title: "A again" } },
			{ type: "other" },
			{ type: "url_citation", url_citation: { url: "https://b.example" } },
		] } }],
	};
	expect(parseSearchResponse(json)).toEqual({
		summary: "Summary text.",
		sources: [{ title: "A", url: "https://a.example", snippet: "first snippet" }, { title: "https://b.example", url: "https://b.example", snippet: "" }],
	});
});

test("private and local addresses are recognized", () => {
	for (const a of ["127.0.0.1", "10.1.2.3", "192.168.1.1", "172.20.0.1", "169.254.169.254", "100.64.0.1", "::1", "fd00::1", "fe80::1", "::ffff:127.0.0.1", "198.18.0.1", "224.0.0.1", "255.255.255.255", "2001::1"]) expect(isPrivateAddress(a), a).toBe(true);
	for (const a of ["8.8.8.8", "172.32.0.1", "2001:4860:4860::8888"]) expect(isPrivateAddress(a), a).toBe(false);
});

test("fetching refuses local addresses, including through redirects", async () => {
	const fetchImpl = (async () => new Response(null, { status: 302, headers: { location: "http://127.0.0.1:8080/admin" } })) as typeof fetch;
	expect(await fetchPage("http://localhost:3000", { allowPrivate: false, fetchImpl })).toEqual({ error: expect.stringContaining("private network") });
	expect(await fetchPage("http://93.184.215.14/", { allowPrivate: false, fetchImpl })).toEqual({ error: expect.stringContaining("127.0.0.1") });
	expect(await fetchPage("file:///etc/passwd", { allowPrivate: false, fetchImpl })).toEqual({ error: expect.stringContaining("http") });
});

test("attachments become content blocks with the words last; edits keep them", () => {
	const input = buildInput("What's in these?", [
		{ kind: "text", name: "notes.txt", text: "hello" },
		{ kind: "image", name: "a.png", mimeType: "image/png", data: "AAAA" },
	]);
	expect(input.content).toEqual([
		{ type: "text", text: '<attachment name="notes.txt">\nhello\n</attachment>' },
		{ type: "image", data: "AAAA", mimeType: "image/png" },
		{ type: "text", text: "What's in these?" },
	]);
	expect(input.entry).toEqual({ kind: "piopio.user", data: { text: "What's in these?", attachments: [{ name: "notes.txt", kind: "text", size: 5 }, { name: "a.png", kind: "image", mimeType: "image/png", size: 3 }] } });
	const edited = withText(input.content, input.entry!, "Only the notes");
	expect((edited.content as { type: string; text?: string }[]).at(-1)).toEqual({ type: "text", text: "Only the notes" });
	expect(edited.entry?.data.attachments).toHaveLength(2);
	expect(buildInput("plain")).toEqual({ content: "plain" });
});

test("provider keys are verified against OpenRouter's key endpoint", async () => {
	const { verifyProviderKey } = await import("../src/models.js");
	const ok = (async () => new Response(JSON.stringify({ data: { label: "sk-or-v1-abc...", usage: 18.4, limit: null } }), { status: 200 })) as typeof fetch;
	const bad = (async () => new Response("{}", { status: 401 })) as typeof fetch;
	expect(await verifyProviderKey("openrouter", "sk-or-v1-x", ok)).toEqual({ ok: true, label: "sk-or-v1-abc...", usageUsd: 18.4, limitUsd: null });
	expect(await verifyProviderKey("openrouter", "nope", bad)).toEqual({ ok: false, message: "OpenRouter didn't accept this key." });
	expect((await verifyProviderKey("openrouter", "  ", ok)).ok).toBe(false);
});


test("canonical IPv4-mapped IPv6 cannot bypass local network protection", async () => {
	for (const url of ["http://[::ffff:127.0.0.1]/", "http://[::ffff:192.168.1.1]/", "http://[::ffff:7f00:1]/", "http://2130706433/", "http://0x7f000001/"]) {
		expect(await isPrivateHost(new URL(url).hostname), url).toBe(true);
		let called = false;
		const result = await fetchPage(url, { allowPrivate: false, fetchImpl: (async () => { called = true; return new Response("bad"); }) as typeof fetch });
		expect(result).toHaveProperty("error"); expect(called).toBe(false);
	}
	expect(isPrivateAddress("::ffff:808:808")).toBe(false);
	expect(await isPrivateHost("does-not-exist.invalid")).toBe(true);
	const redirect = (async () => new Response(null, { status: 302, headers: { location: "http://[::ffff:7f00:1]/" } })) as typeof fetch;
	expect(await fetchPage("http://8.8.8.8/", { allowPrivate: false, fetchImpl: redirect })).toHaveProperty("error");
});
