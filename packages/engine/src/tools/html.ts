/** Readable markdown from an HTML page: the main content, without navigation, scripts or chrome. */
import { HTMLElement, NodeType, parse, type Node } from "node-html-parser";

const DROP = new Set(["script", "style", "noscript", "nav", "header", "footer", "aside", "form", "svg", "iframe", "template", "button", "select", "input", "dialog"]);

export function htmlToMarkdown(html: string, baseUrl: string): { title: string; markdown: string } {
	const root = parse(html, { comment: false, blockTextElements: { script: false, style: false, pre: true, noscript: false } });
	const title = (root.querySelector("title")?.text ?? "").trim().replace(/\s+/g, " ");
	const main = root.querySelector("article") ?? root.querySelector("main") ?? root.querySelector("[role=main]") ?? root.querySelector("body") ?? root;
	const out = render(main, baseUrl).replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
	return { title, markdown: out };
}

function render(node: Node, base: string): string {
	if (node.nodeType === NodeType.TEXT_NODE) return node.text.replace(/\s+/g, " ");
	if (!(node instanceof HTMLElement)) return "";
	const tag = node.rawTagName?.toLowerCase() ?? "";
	if (DROP.has(tag) || node.getAttribute("aria-hidden") === "true" || node.getAttribute("hidden") !== undefined) return "";
	const inner = () => node.childNodes.map((c) => render(c, base)).join("");
	switch (tag) {
		case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
			return `\n\n${"#".repeat(Number(tag[1]))} ${inner().trim()}\n\n`;
		case "p": case "div": case "section": case "article": case "main": case "figure": case "table":
			return `\n\n${inner().trim()}\n\n`;
		case "br":
			return "\n";
		case "li":
			return `\n- ${inner().trim()}`;
		case "ul": case "ol":
			return `\n${inner()}\n`;
		case "tr":
			return `\n| ${node.childNodes.filter((c) => c instanceof HTMLElement).map((c) => render(c, base).trim().replace(/\|/g, "\\|")).join(" | ")} |`;
		case "pre":
			return `\n\n\`\`\`\n${node.text.trim()}\n\`\`\`\n\n`;
		case "code":
			return `\`${node.text}\``;
		case "strong": case "b":
			return `**${inner().trim()}**`;
		case "em": case "i":
			return `*${inner().trim()}*`;
		case "blockquote":
			return `\n\n> ${inner().trim().replace(/\n/g, "\n> ")}\n\n`;
		case "a": {
			const text = inner().trim();
			const href = node.getAttribute("href");
			if (!href || !text || href.startsWith("#") || href.startsWith("javascript:")) return text;
			try {
				return `[${text}](${new URL(href, base).toString()})`;
			} catch {
				return text;
			}
		}
		case "img": {
			const alt = node.getAttribute("alt")?.trim();
			return alt ? `[image: ${alt}]` : "";
		}
		default:
			return inner();
	}
}
