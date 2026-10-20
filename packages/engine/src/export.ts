/** Exports a session's visible transcript (the active branch) as Markdown, HTML or JSONL. */
import { marked } from "marked";
import type { TimelineItem } from "@piopio/protocol";

export type ExportFormat = "markdown" | "html" | "jsonl";

export function exportTranscript(title: string, items: readonly TimelineItem[], format: ExportFormat): { filename: string; mimeType: string; content: string } {
	const base = safeFilename(title);
	if (format === "jsonl") {
		return { filename: `${base}.jsonl`, mimeType: "application/x-ndjson", content: items.map((i) => JSON.stringify(i)).join("\n") + "\n" };
	}
	const markdown = toMarkdown(title, items);
	if (format === "markdown") return { filename: `${base}.md`, mimeType: "text/markdown", content: markdown };
	const body = marked.parse(markdown, { async: false, gfm: true }) as string;
	return { filename: `${base}.html`, mimeType: "text/html", content: htmlPage(title, body) };
}

export function toMarkdown(title: string, items: readonly TimelineItem[]): string {
	const out: string[] = [`# ${title}`, ""];
	for (const item of items) {
		switch (item.kind) {
			case "user": {
				out.push("## You", "");
				if (item.attachments?.length) out.push(`*Attached: ${item.attachments.map((a) => a.name).join(", ")}*`, "");
				out.push(item.text, "");
				break;
			}
			case "assistant": {
				out.push(`## Assistant${item.model ? ` (${item.model})` : ""}`, "");
				const thinking = item.parts.filter((p) => p.type === "thinking").map((p) => p.text).join("").trim();
				if (thinking) out.push("<details><summary>Thinking</summary>", "", thinking, "", "</details>", "");
				const text = item.parts.filter((p) => p.type === "text").map((p) => p.text).join("").trim();
				if (text) out.push(text, "");
				if (item.status === "error") out.push(`> **Error:** ${item.error ?? "the request failed"}`, "");
				break;
			}
			case "tool": {
				const args = JSON.stringify(item.args);
				out.push(`> **${item.tool}** ${args.length > 200 ? `${args.slice(0, 200)}…` : args} — ${item.status}`, "");
				break;
			}
			case "system":
				out.push(`> ${item.text}`, "");
				break;
			case "compaction":
				out.push(`> *Context compacted:* ${item.summary}`, "");
				break;
			case "routing":
				out.push(`> ↳ ${item.decision === "create" ? "New topic" : "Routed to"} **${item.topicTitle}**${item.reason ? ` (${item.reason})` : ""}`, "");
				break;
		}
	}
	return out.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
}

function htmlPage(title: string, body: string): string {
	const esc = title.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc}</title>
<style>
:root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #fff; --code: #f2f2f4; }
@media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #1d1d1f; --code: #2c2c2e; } }
body { font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg); max-width: 760px; margin: 40px auto; padding: 0 16px; }
h1 { font-size: 24px; } h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin-top: 32px; }
pre { background: var(--code); padding: 12px; border-radius: 8px; overflow-x: auto; } code { font: 13px ui-monospace, Menlo, monospace; }
:not(pre) > code { background: var(--code); padding: 1px 4px; border-radius: 4px; }
blockquote { border-left: 3px solid var(--muted); margin-left: 0; padding-left: 12px; color: var(--muted); }
table { border-collapse: collapse; } td, th { border: 1px solid var(--code); padding: 4px 8px; }
</style>
</head>
<body>
${body}
<footer><p style="color: var(--muted); font-size: 12px">Exported from Piopio</p></footer>
</body>
</html>
`;
}

function safeFilename(title: string): string {
	return (title.replace(/[/\\?%*:|"<>]/g, "-").replace(/\s+/g, " ").trim().slice(0, 80) || "Thread").replace(/^\.+/, "");
}
