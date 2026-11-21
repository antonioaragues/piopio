import { getCurrentSystemMessage } from "@earendil-works/pi-ai";
import { estimateTokens, type AgentSession } from "@earendil-works/pi-coding-agent";
import type { SessionState } from "@piopio/protocol";
import { groupOf } from "../connectors/permissions.js";
import { sdkSplit } from "../input.js";

type Message = AgentSession["messages"][number];
type Breakdown = NonNullable<NonNullable<SessionState["context"]>["breakdown"]>;
type Kind = Breakdown["groups"][number]["kind"];
const kinds: Kind[] = ["instructions", "tools", "conversation", "toolUse", "attachments", "summaries"];

// Match only complete, recognized prompt sections. Extensions can supply the rest as free text.
const promptSections = /^(<(piopio|project_context|skills|mcp_servers)>\n[\s\S]*?\n<\/\2>)$/gm;
const promptLabels: Record<string, string> = {
	piopio: "Piopio guidelines",
	project_context: "Project instructions (AGENTS.md)",
	skills: "Skill listings",
	mcp_servers: "MCP server instructions",
};

const textTokens = (text: string) => Math.ceil(text.length / 4);
const clockPrefix = /^\[Sent [^\]\n]+\](?:\n+|$)/;

function userContent(content: Extract<Message, { role: "user" }>["content"]) {
	// The request clock prefixes the text, while sdkSplit expects attachment tags at the start.
	const first = typeof content === "string" ? content : content[0]?.type === "text" ? content[0].text : "";
	const clock = clockPrefix.exec(first)?.[0] ?? "";
	if (!clock) return { ...sdkSplit(content), clock };
	const remaining = first.slice(clock.length);
	const unprefixed = typeof content === "string" ? remaining : content.slice(1);
	if (Array.isArray(unprefixed) && remaining) unprefixed.unshift({ type: "text", text: remaining });
	return { ...sdkSplit(unprefixed), clock };
}

function toolGroup(name: string): string {
	if (["read", "ls", "find", "grep", "edit", "write"].includes(name)) return "Files";
	if (name === "bash" || name === "powershell") return "Terminal";
	if (name.startsWith("web_") || name.startsWith("browser_")) return "Web and browser";
	if (name.startsWith("mcp__") || groupOf(name)) return "Apps and MCP";
	return "Other tools";
}

function estimate(messages: Message[], base: Breakdown["groups"] = []): Breakdown["groups"] {
	const bins = new Map<Kind, Map<string, number>>(base.map((group) => [group.kind, new Map(group.parts.map((part) => [part.label, part.tokens]))]));
	const add = (kind: Kind, label: string, tokens: number) => {
		if (!tokens) return;
		const parts = bins.get(kind) ?? new Map<string, number>();
		parts.set(label, (parts.get(label) ?? 0) + tokens);
		bins.set(kind, parts);
	};
	const system = getCurrentSystemMessage(messages);
	if (system) {
		const prompt = typeof system.content === "string" ? system.content : system.content.map((part) => part.text).join("\n");
		let other = prompt.replace(promptSections, (section: string, _match: string, key: string) => {
			add("instructions", promptLabels[key]!, textTokens(section));
			return "";
		}).trim().length;
		for (const [key, section] of Object.entries(system.sections ?? {})) {
			if (!section) continue;
			if (Object.hasOwn(promptLabels, key)) add("instructions", promptLabels[key]!, textTokens(section));
			else other += section.length;
		}
		add("instructions", "Other instructions", Math.ceil(other / 4));
		for (const tool of system.toolsAdded ?? []) {
			add("tools", tool.name.startsWith("mcp__") || groupOf(tool.name) ? "Apps and MCP" : "Agent tools", textTokens(JSON.stringify(tool)));
		}
	}
	for (const message of messages) {
		switch (message.role) {
			case "user": {
				const { words, hints, files, images, clock } = userContent(message.content);
				add("conversation", "Your messages", textTokens(words) + textTokens(clock));
				add("attachments", "Images", textTokens(hints));
				add("attachments", "Text and documents", textTokens(files));
				add("attachments", "Images", estimateTokens({ ...message, content: images }));
				break;
			}
			case "assistant": {
				if (message.stopReason === "aborted" || message.stopReason === "error") break;
				const calls = message.content.filter((part) => part.type === "toolCall");
				for (const call of calls) add("toolUse", toolGroup(call.name), estimateTokens({ ...message, content: [call] }));
				add("conversation", "Thinking", estimateTokens({ ...message, content: message.content.filter((part) => part.type === "thinking") }));
				add("conversation", "Assistant messages", estimateTokens({ ...message, content: message.content.filter((part) => part.type !== "toolCall" && part.type !== "thinking") }));
				break;
			}
			case "toolResult": add("toolUse", toolGroup(message.toolName), estimateTokens(message)); break;
			case "bashExecution":
				if (!message.excludeFromContext) add("toolUse", "Terminal", estimateTokens(message));
				break;
			case "custom": add("conversation", "Added background", estimateTokens(message)); break;
			case "compactionSummary": add("summaries", "Compacted conversation", estimateTokens(message)); break;
			case "branchSummary": add("summaries", "Earlier branch", estimateTokens(message)); break;
		}
	}
	return kinds.flatMap((kind) => {
		const values = bins.get(kind);
		if (!values?.size) return [];
		const parts = Array.from(values, ([label, tokens]) => ({ label, tokens })).sort((a, b) => b.tokens - a.tokens);
		return [{ kind, tokens: parts.reduce((sum, part) => sum + part.tokens, 0), parts }];
	});
}

/**
 * Spread pi's total over the categories by their estimated shares. The estimates count characters (about 4 per token)
 * and every earlier turn's thinking, while pi's total comes from the provider's usage, so they rarely add up on their own.
 */
export function scaleTo(groups: Breakdown["groups"], total: number): Breakdown["groups"] {
	const sum = groups.reduce((n, group) => n + group.tokens, 0);
	if (sum <= 0 || total <= 0) return groups;
	const factor = total / sum;
	return groups.map((group) => {
		const parts = group.parts.map((part) => ({ label: part.label, tokens: Math.round(part.tokens * factor) }));
		return { kind: group.kind, tokens: parts.reduce((n, part) => n + part.tokens, 0), parts };
	});
}

/** Keep only estimates from Pi's prepared request. After a reopen or a context rewrite, use the active projection. */
export class ContextBreakdown {
	private request?: { leaf: string; boundary?: string; groups: Breakdown["groups"] };

	constructor(private readonly session: AgentSession) {}

	observeRequests(): void {
		const agent = this.session.agent;
		const transform = agent.transformContext;
		agent.transformContext = async (messages, signal) => {
			const prepared = transform ? await transform(messages, signal) : messages;
			const entries = this.session.sessionManager.getBranch();
			const leaf = entries.at(-1)?.id;
			if (leaf) this.request = { leaf, boundary: this.boundary(entries), groups: estimate(prepared) };
			return prepared;
		};
	}

	/** The breakdown of `total`, pi's count of the tokens in context. */
	read(total: number): Breakdown {
		const manager = this.session.sessionManager;
		const projection = manager.buildSessionProjection();
		const entries = manager.getBranch();
		const positions = new Map(entries.map((entry, i) => [entry.id, i]));
		const request = this.request;
		const index = request && positions.get(request.leaf);
		if (request && index !== undefined && request.boundary === this.boundary(entries)) {
			const tail = projection.entries.filter((entry) => (positions.get(entry.sourceEntry.id) ?? -1) > index).flatMap((entry) => entry.messages);
			if (!tail.some((message) => message.role === "system")) {
				return { source: "request", groups: scaleTo(estimate(tail, request.groups), total) };
			}
		}
		return { source: "session", groups: scaleTo(estimate(projection.messages), total) };
	}

	private boundary(entries: ReturnType<AgentSession["sessionManager"]["getBranch"]>): string | undefined {
		return entries.findLast((entry) => entry.type === "compaction" || entry.type === "context_edit")?.id;
	}
}
