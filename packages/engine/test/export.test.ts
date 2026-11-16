import { expect, test } from "vitest";
import type { TimelineItem } from "@piopio/protocol";
import { exportTranscript } from "../src/export.js";

const items = [
	{ kind: "user", id: "u1", text: 'Look <script>alert("u")</script> <img src=x onerror=alert(1)> [click](javascript:alert(2)) [doc](https://example.com/a) and **bold**' },
	{
		kind: "assistant",
		id: "a1",
		status: "done",
		parts: [
			{ type: "thinking", text: "hmm" },
			{ type: "text", text: '<iframe src="https://evil.example"></iframe>\n\n![pic](javascript:alert(3)) ![ok](https://example.com/p.png) [x](JaVa\nScRiPt:alert(4)) [rel](notes/a.md)' },
		],
	},
] as unknown as TimelineItem[];

test("the HTML export shows raw HTML as text, keeps safe links only and blocks scripts", () => {
	const { content } = exportTranscript("<b>Title</b>", items, "html");
	const body = content.slice(content.indexOf("<body>"));
	expect(body).not.toMatch(/<script|<iframe|href="\s*javascript|src="\s*javascript/i);
	expect(body.match(/<img [^>]*>/g)).toEqual(['<img src="https://example.com/p.png" alt="ok">']);
	expect(body).toContain("&lt;script&gt;");
	expect(body).toContain("&lt;iframe");
	expect(body).toContain('<a href="https://example.com/a">doc</a>');
	expect(body).toContain('<a href="notes/a.md">rel</a>');
	expect(body).toContain('<img src="https://example.com/p.png" alt="ok">');
	expect(body).toContain("<strong>bold</strong>");
	expect(body).toContain("<details><summary>Thinking</summary>");
	expect(content).toContain(`Content-Security-Policy" content="default-src 'none'`);
	expect(content).toContain("<title>&lt;b&gt;Title&lt;/b&gt;</title>");
});

test("visuals export as their title and a marker the app fills in; only then may scripts run, and only offline", () => {
	const visual = { kind: "tool", id: "t1", callId: "call|7", tool: "show_visual", status: "done", args: { title: "Spending", html: "<canvas></canvas>" } };
	const refused = { kind: "tool", id: "t2", callId: "c2", tool: "show_visual", status: "error", args: { title: "Big", html: "x" } };
	const withVisual = [...items, visual, refused] as unknown as TimelineItem[];
	const md = exportTranscript("T", withVisual, "markdown").content;
	expect(md).toContain("**Visual: Spending**\n\n<!-- piopio-visual:Y2FsbHw3 -->");
	expect(md).not.toContain("Visual: Big");
	const html = exportTranscript("T", withVisual, "html").content;
	expect(html).toContain('<div data-piopio-visual="Y2FsbHw3"></div>');
	expect(html).toContain("script-src 'unsafe-inline' data:; font-src data:; connect-src 'none'");
	const body = html.slice(html.indexOf("<body>"));
	expect(body).not.toMatch(/<script|<iframe/i);
	expect(body).toContain("&lt;script&gt;");
	expect(exportTranscript("T", items, "html").content).not.toContain("script-src");
});
