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

test("an export says what it is and names who answered; agents' items come out too", () => {
	const at = new Date("2026-11-20T09:00:00Z");
	const agentItems = [
		{ kind: "assistant", id: "a1", status: "done", model: "sonnet-5.5", parts: [{ type: "text", text: "Good morning." }] },
		{ kind: "steps", id: "s1", thinking: "check the calendar", tools: [{ kind: "tool", id: "t1", callId: "c1", tool: "calendar_list", status: "done", args: { from: "2026-11-20" } }] },
		{ kind: "agent_msg", id: "m1", fromAgent: { id: "r", name: "Rita" }, toAgent: { id: "b", name: "Briefing" }, text: "The dentist moved.", direction: "in", mode: "tell" },
		{ kind: "agent_msg", id: "m2", fromAgent: { id: "b", name: "Briefing" }, toAgent: { id: "r", name: "Rita" }, text: "When?", direction: "out", mode: "ask", status: "replied", reply: "10:00" },
		{ kind: "approval", id: "p1", approvalId: "x", tool: "calendar_add", title: "Add an event to your calendar?", args: {}, status: "approved", expiresAt: "", always: "" },
		{ kind: "result", id: "r1", callId: "c2", card: { kind: "reminder", title: "Dentist", detail: "Thu 27 Nov, 10:00" }, undo: { id: "u", status: "undone", until: "" } },
		{ kind: "checkpoint", id: "k1", checkpointId: "k", label: "Before turn 3", files: 2 },
	] as unknown as TimelineItem[];
	const md = exportTranscript("Briefing › Run", agentItems, "markdown", { what: "Agent run", speaker: "Briefing", exportedAt: at }).content;
	expect(md).toContain("# Briefing › Run\n\n*Agent run · sonnet-5.5 · Exported from Piopio on 2026-11-20*");
	expect(md).toContain("## Briefing\n\nGood morning.");
	expect(md).not.toContain("## Assistant");
	expect(md).toContain("<details><summary>Thinking</summary>\n\ncheck the calendar");
	expect(md).toContain('> **calendar_list** {"from":"2026-11-20"} — done');
	expect(md).toContain("## Rita → Briefing\n\nThe dentist moved.");
	expect(md).toContain("## Briefing → Rita\n\nWhen?\n\n**Rita:** 10:00");
	expect(md).toContain("> **Asked you:** Add an event to your calendar?\n> You allowed it.");
	expect(md).toContain("> **Reminder:** Dentist — Thu 27 Nov, 10:00 (undone)");
	expect(md).toContain("> *Checkpoint: Before turn 3 · 2 files changed*");
	// Without a speaker it's the assistant, with its model, as before; an empty title still makes a filename.
	expect(exportTranscript("", items, "markdown").filename).toBe("Conversation.md");
	expect(exportTranscript("T", [agentItems[0]!], "markdown", { exportedAt: at }).content).toContain("## Assistant (sonnet-5.5)");
});

test("the export lists the visuals it shows, an agent's steps included, so the app can draw them without the chat open", () => {
	const v = (id: string, title: string, html: string) => ({ kind: "tool", id, callId: `call-${id}`, tool: "show_visual", status: "done", args: { title, html } });
	const list = [v("t1", "Spending", "<p>1</p>"), { kind: "steps", id: "s", tools: [v("t2", "Spending", "<p>2</p>"), v("t3", "Map", "<p>3</p>")] }] as unknown as TimelineItem[];
	const out = exportTranscript("T", list, "html");
	expect(out.visuals).toEqual([
		{ callId: "call-t2", title: "Spending", html: "<p>2</p>" },
		{ callId: "call-t3", title: "Map", html: "<p>3</p>" },
	]);
	expect(out.content.match(/data-piopio-visual/g)).toHaveLength(2);
	expect(exportTranscript("T", list, "jsonl").visuals).toEqual([]);
});
