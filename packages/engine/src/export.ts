/** Exports a session's visible transcript (the active branch) as Markdown, HTML or JSONL. */
import { Marked, type Tokens } from "marked";
import type { TimelineItem } from "@piopio/protocol";

export type ExportFormat = "markdown" | "html" | "jsonl";

export function exportTranscript(title: string, items: readonly TimelineItem[], format: ExportFormat): { filename: string; mimeType: string; content: string } {
	const base = safeFilename(title);
	if (format === "jsonl") {
		return { filename: `${base}.jsonl`, mimeType: "application/x-ndjson", content: items.map((i) => JSON.stringify(i)).join("\n") + "\n" };
	}
	const markdown = toMarkdown(title, items, format === "html" ? "html" : "markdown");
	if (format === "markdown") return { filename: `${base}.md`, mimeType: "text/markdown", content: markdown };
	const body = safeMarked.parse(markdown, { async: false }) as string;
	return { filename: `${base}.html`, mimeType: "text/html", content: htmlPage(title, body, items.some(isVisual)) };
}

/**
 * Visuals (docs/spec/25 §8): the engine can't draw them, so an export carries the title and a marker with the tool
 * call's id, and the Mac app puts the visual in its place: a sandboxed frame in HTML, a picture in Markdown. Without
 * the app the marker is an HTML comment in Markdown and an empty div in HTML, and the title stays.
 */
const isVisual = (item: TimelineItem): boolean =>
	item.kind === "tool" && item.tool === "show_visual" && item.status !== "error" && typeof (item.args as { html?: unknown } | undefined)?.html === "string";
export const visualMarkerId = (callId: string) => Buffer.from(callId, "utf8").toString("base64url");
export const visualMarker = (callId: string, format: "markdown" | "html") =>
	format === "html" ? `<div data-piopio-visual="${visualMarkerId(callId)}"></div>` : `<!-- piopio-visual:${visualMarkerId(callId)} -->`;

/**
 * The HTML export is opened in a browser and shared, and the transcript holds text from models, pages and files:
 * raw HTML is shown as text (only the export's own Thinking <details> stays), links and images keep safe URLs
 * only, and the page's Content-Security-Policy blocks scripts in any case.
 */
const OWN_HTML = /^(<details><summary>Thinking<\/summary>|<\/details>|<div data-piopio-visual="[A-Za-z0-9_-]+"><\/div>)$/;
const escapeHtml = (text: string) => text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const scheme = (url: string) => /^([a-z][a-z0-9+.-]*):/i.exec(url.replace(/[\u0000-\u0020\u007f]/g, ""))?.[1]?.toLowerCase();
const safeLink = (url: string) => [undefined, "http", "https", "mailto"].includes(scheme(url));
const safeImage = (url: string) => ["http", "https"].includes(scheme(url) ?? "") || /^data:image\/(png|jpe?g|gif|webp);/i.test(url.trim());
const safeMarked = new Marked({
	gfm: true,
	renderer: {
		html(token: Tokens.HTML | Tokens.Tag) {
			const text = token.text.trim();
			return OWN_HTML.test(text) ? text + (token.block ? "\n" : "") : escapeHtml(token.text);
		},
		link(token: Tokens.Link) {
			return safeLink(token.href) ? false : this.parser.parseInline(token.tokens);
		},
		image(token: Tokens.Image) {
			return safeImage(token.href) ? false : escapeHtml(token.text);
		},
	},
});

export function toMarkdown(title: string, items: readonly TimelineItem[], visuals: "markdown" | "html" = "markdown"): string {
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
				if (isVisual(item)) {
					const name = (item.args as { title?: unknown }).title;
					out.push(`**Visual: ${typeof name === "string" && name.trim() ? name.trim() : "untitled"}**`, "", visualMarker(item.callId, visuals), "");
					break;
				}
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
		}
	}
	return out.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
}

/**
 * With visuals, scripts may run, but only inside the visuals' sandboxed frames (the transcript's own HTML is escaped
 * above, so nothing else on the page is a script), and nothing reaches the network: the frames inherit this policy.
 */
function htmlPage(title: string, body: string, visuals = false): string {
	const esc = title.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src https: http: data:${visuals ? "; script-src 'unsafe-inline' data:; font-src data:; connect-src 'none'" : ""}">
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
