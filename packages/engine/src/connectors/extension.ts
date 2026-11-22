/**
 * Connector tools as extensions: for pi-durable (chats, agents) and for pi-coding-agent (Build).
 * Each runtime passes how it asks before a change (`confirm`).
 */
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import { defineTool as defineCodingTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import type { ConnectorHub } from "./hub.js";
import { connectorsSection, connectorTools, type Confirm } from "./tools.js";
import { promptSection, type PromptEvent } from "../tools/prompt-sections.js";

export const CONNECTORS_EXTENSION = "piopio-connectors";
const TOOL_SEARCH = "tool_search";

/** Where a tool call happens, so the runtime can show its approval in the right conversation. */
export type CallSite = { conversationId: string; callId: string; context: Context };

export function durableConnectorsExtension(hub: ConnectorHub, scope: "chat" | "agent", confirmFor: (site: CallSite) => Confirm, off: (connector: string) => boolean = () => false) {
	const tools = connectorTools(hub, scope, off).map((tool) =>
		defineTool({
			name: tool.name,
			description: tool.description,
			parameters: tool.parameters,
			// An app with many tools: the model finds this one with tool_search (docs/spec/12, tool search).
			...(tool.deferred ? { deferred: true as const } : {}),
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
		sections: [section("connected-apps", () => connectorsSection(hub, scope, off))],
	});
}

/** Build sessions: the same tools, asking through Build's prompts. */
export function codingConnectorsExtension(hub: ConnectorHub, confirmFor: (callId: string, signal: AbortSignal | undefined) => Confirm, off: (connector: string) => boolean = () => false): ExtensionFactory {
	return (pi) => {
		const tools = connectorTools(hub, "chat", off);
		// Deferred tools are reached only through pi's tool_search: turn it on when an app has some (as pi's MCP extension
		// does for its deferred servers). Only a tool_search that can reach tools counts.
		const ensureToolSearch = () => {
			if (!tools.some((t) => t.deferred)) return;
			const search = pi.getAllTools().find((t) => t.name === TOOL_SEARCH && t.reachesTools);
			const active = pi.getActiveTools();
			if (search && !active.includes(TOOL_SEARCH)) pi.setActiveTools([...active, TOOL_SEARCH]);
		};
		pi.on("session_start", () => ensureToolSearch());
		pi.on("before_agent_start", (event) => {
			ensureToolSearch();
			promptSection(event as unknown as PromptEvent, "connected-apps", connectorsSection(hub, "chat", off));
			return undefined;
		});
		for (const tool of tools) {
			const access = tool.access({});
			pi.registerTool(
				defineCodingTool({
					name: tool.name,
					label: tool.label,
					description: tool.description,
					promptSnippet: `${tool.name}: ${tool.label.toLowerCase()}`,
					parameters: tool.parameters as never,
					...(tool.deferred ? { exposure: "deferred" as const } : {}),
					...(tool.namespace ? { namespace: tool.namespace } : {}),
					annotations: { readOnlyHint: access === "read", destructiveHint: access === "destructive" },
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
