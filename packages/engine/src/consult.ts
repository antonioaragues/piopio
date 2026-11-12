/**
 * Your agents in a conversation (docs/spec/21 AD4, D6, design 5c-2). They're never assigned to a project: a
 * conversation asks one with `ask_agent`, on its own or because you wrote `@Name`, which brings that agent in for that
 * message. The agent answers in its own conversation with Piopio (its instructions, model and memory), and its answer
 * shows here: "Rita · joined for this message", or "Asked Rita" when the model chose to.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type ConsultAgent = { id: string; name: string; description?: string };
export type ConsultBridge = {
	agents(): ConsultAgent[];
	/** Asks the agent and waits for its answer; undefined when it hasn't answered in time. */
	ask(agentId: string, message: string, from: string): Promise<string | undefined>;
};

/** The agents a message brings in with `@Name` (longest names first, so "@Code reviewer" isn't "@Code"). */
export function mentioned(text: string, agents: ConsultAgent[]): ConsultAgent[] {
	const lower = text.toLowerCase();
	const found: ConsultAgent[] = [];
	let rest = lower;
	for (const a of [...agents].sort((x, y) => y.name.length - x.name.length)) {
		const tag = `@${a.name.toLowerCase()}`;
		const at = rest.indexOf(tag);
		if (at < 0) continue;
		const after = rest[at + tag.length];
		if (after && /[\p{L}\p{N}_]/u.test(after)) continue;
		found.push(a);
		rest = rest.slice(0, at) + " ".repeat(tag.length) + rest.slice(at + tag.length);
	}
	return found;
}

function resolve(ref: string, agents: ConsultAgent[]): ConsultAgent | undefined {
	const r = ref.trim().replace(/^@/, "").toLowerCase();
	return agents.find((a) => a.id.toLowerCase() === r) ?? agents.find((a) => a.name.toLowerCase() === r);
}

export function consultExtension(bridge: ConsultBridge, from: () => string): ExtensionFactory {
	return (pi) => {
		/** Who this message brought in: their calls say "joined for this message". */
		let joined = new Set<string>();
		pi.on("before_agent_start", (event) => {
			const agents = bridge.agents();
			if (!agents.length) return undefined;
			if (event.messageType === "user") joined = new Set(mentioned(event.prompt, agents).map((a) => a.id));
			const list = agents.map((a) => `- ${a.name}${a.description ? `: ${a.description}` : ""}`).join("\n");
			const now = agents.filter((a) => joined.has(a.id)).map((a) => a.name);
			const mention = now.length
				? `\n\nIn this message the user brought in ${now.join(" and ")} with @. Before you answer, call ask_agent for ${now.length === 1 ? "it" : "each"} with what they ask of it and the context it needs. The user sees its answer, so don't repeat it; build on it.`
				: "";
			return { systemPrompt: `${event.systemPrompt}\n\n<your-agents>\nThe user's own agents. Ask one with ask_agent when its job fits what's needed; the user can bring one in by writing @Name.\n${list}${mention}\n</your-agents>` };
		});
		// Every message you write, follow-ups included, says who it brings in.
		pi.on("message_start", (event) => {
			const m = event.message as { role?: string; content?: unknown };
			if (m.role !== "user") return;
			const text = typeof m.content === "string" ? m.content : Array.isArray(m.content) ? (m.content as { type: string; text?: string }[]).filter((b) => b.type === "text").map((b) => b.text ?? "").join("") : "";
			joined = new Set(mentioned(text, bridge.agents()).map((a) => a.id));
		});
		pi.registerTool(
			defineTool({
				name: "ask_agent",
				label: "Ask an agent",
				description: "Ask one of the user's agents something and wait for its answer. It answers with its own instructions, model and memory; give it the context it needs, since it doesn't see this conversation.",
				promptSnippet: "ask_agent: ask one of the user's agents",
				parameters: Type.Object({ agent: Type.String({ description: "The agent's name" }), message: Type.String() }),
				async execute(_id, params) {
					const agents = bridge.agents();
					const to = resolve(params.agent, agents);
					if (!to) return { content: [{ type: "text" as const, text: `No agent called “${params.agent}”. The user's agents: ${agents.map((a) => a.name).join(", ") || "none"}.` }], details: {}, isError: true };
					const details = { agent: { id: to.id, name: to.name }, ...(joined.has(to.id) ? { joined: true } : {}) };
					try {
						const reply = await bridge.ask(to.id, params.message, from());
						if (reply === undefined) return { content: [{ type: "text" as const, text: `${to.name} hasn't answered yet.` }], details: { ...details, status: "no_reply" } };
						return { content: [{ type: "text" as const, text: reply }], details: { ...details, status: "replied" } };
					} catch (error) {
						return { content: [{ type: "text" as const, text: (error as Error).message }], details: { ...details, status: "failed" }, isError: true };
					}
				},
			}),
		);
	};
}
