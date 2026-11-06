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
