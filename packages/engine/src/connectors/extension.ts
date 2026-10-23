/**
 * Connector tools as extensions: for pi-durable (chats, notebooks, agents) and for pi-coding-agent (Build).
 * Each runtime passes how it asks before a change (`confirm`).
 */
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import { defineTool as defineCodingTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import type { ConnectorHub } from "./hub.js";
import { connectorsSection, connectorTools, type Confirm } from "./tools.js";

export const CONNECTORS_EXTENSION = "piopio-connectors";

/** Where a tool call happens, so the runtime can show its approval in the right conversation. */
export type CallSite = { conversationId: string; callId: string; context: Context };

export function durableConnectorsExtension(hub: ConnectorHub, scope: "chat" | "agent", confirmFor: (site: CallSite) => Confirm) {
	const tools = connectorTools(hub, scope).map((tool) =>
		defineTool({
			name: tool.name,
			description: tool.description,
			parameters: tool.parameters,
			execute: async (args, api, context) => {
				try {
					const confirm = confirmFor({ conversationId: String(api.conversationId), callId: api.callId, context });
					const r = await tool.run(args as Record<string, unknown>, confirm);
					return { output: [{ type: "text", text: r.text }], ...(r.isError ? { isError: true } : {}) };
				} catch (error) {
					return { output: [{ type: "text", text: (error as Error).message }], isError: true };
				}
			},
		}),
	);
	return defineExtension({
		name: CONNECTORS_EXTENSION,
		tools,
		sections: [section("connected-apps", () => connectorsSection(hub, scope))],
	});
}

/** Build sessions: the same tools, asking through Build's prompts. */
export function codingConnectorsExtension(hub: ConnectorHub, confirmFor: (callId: string, signal: AbortSignal | undefined) => Confirm): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			const text = connectorsSection(hub, "chat");
			return text ? { systemPrompt: `${event.systemPrompt}\n\n# Connected apps\n${text}` } : undefined;
		});
		for (const tool of connectorTools(hub, "chat")) {
			pi.registerTool(
				defineCodingTool({
					name: tool.name,
					label: tool.label,
					description: tool.description,
					promptSnippet: `${tool.name}: ${tool.label.toLowerCase()}`,
					parameters: tool.parameters as never,
					async execute(callId, params, signal) {
						try {
							const r = await tool.run(params as Record<string, unknown>, confirmFor(callId, signal));
							return { content: [{ type: "text", text: r.text }], details: {}, ...(r.isError ? { isError: true } : {}) };
						} catch (error) {
							return { content: [{ type: "text", text: (error as Error).message }], details: {}, isError: true };
						}
					},
				}),
			);
		}
	};
}

/** Waits for a decision, giving up when the turn is stopped. */
export function waitFor<T>(promise: Promise<T>, context: Context): Promise<T> {
	return awaitWithContext(promise, context);
}
