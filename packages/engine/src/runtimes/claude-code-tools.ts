/**
 * Piopio's own tools for a conversation on Claude Code (docs/spec/31 CA8): earlier conversations, About me, connected
 * apps, the browser and visuals, served to Claude Code as an in-process MCP server named "piopio" (its tools are
 * `mcp__piopio__<name>`). They come from the same pi extensions Build sessions load: each is run once against a small
 * stand-in for pi's extension API that keeps what it registers (tools, and the sections it adds to the system prompt).
 * The tools ask the user themselves where they need to (a connector's change, acting on a site), as in Build.
 */
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

export const PIOPIO_MCP = "piopio";
export const PIOPIO_MCP_PREFIX = `mcp__${PIOPIO_MCP}__`;

type Content = { type: string; text?: string; data?: string; mimeType?: string };
type ToolResult = { content?: Content[]; isError?: boolean };
/** A tool as an extension registers it (pi's `ToolDefinition`, the parts Piopio's tools use). */
export type CapturedTool = {
	name: string;
	description: string;
	parameters: unknown;
	execute: (callId: string, params: unknown, signal: AbortSignal | undefined, onUpdate: (() => void) | undefined, ctx: unknown) => Promise<ToolResult>;
};
type PromptHandler = (event: { systemPrompt: string }) => unknown;

/** Runs the extensions against a stand-in for pi's API: their tools, and what they add to the system prompt. */
export function collectTools(factories: readonly ExtensionFactory[]): { tools: CapturedTool[]; prompt: () => Promise<string> } {
	const tools: CapturedTool[] = [];
	const prompts: PromptHandler[] = [];
	const api = new Proxy(
		{
			registerTool: (tool: CapturedTool) => {
				tools.push(tool);
			},
			on: (event: string, handler: PromptHandler) => {
				if (event === "before_agent_start") prompts.push(handler);
			},
		} as Record<string, unknown>,
		// Commands, shortcuts, flags and the rest have no place in Claude Code.
		{ get: (target, key) => (key in target ? target[key as string] : () => undefined) },
	);
	for (const factory of factories) void (factory as unknown as (pi: unknown) => unknown)(api);
	const prompt = async () => {
		const parts: string[] = [];
		for (const handler of prompts) {
			const result = (await Promise.resolve(handler({ systemPrompt: "" })).catch(() => undefined)) as { systemPrompt?: string } | undefined;
			const text = result?.systemPrompt?.trim();
			if (text) parts.push(text);
		}
		return parts.join("\n\n");
	};
	return { tools, prompt };
}

/**
 * An MCP server with the tools, in-process (the Agent SDK's `{ type: "sdk", instance }`). `callIdFor` finds the tool
 * call Claude Code made (its id keys the transcript's card, and the approvals the tool asks for).
 */
export function piopioServer(tools: readonly CapturedTool[], callIdFor: (name: string, args: Record<string, unknown>) => string, signal: () => AbortSignal | undefined) {
	const mcp = new McpServer({ name: PIOPIO_MCP, version: "1.0.0" }, { capabilities: { tools: {} } });
	mcp.server.setRequestHandler(ListToolsRequestSchema, async () => ({
		tools: tools.map((t) => ({ name: t.name, description: t.description, inputSchema: { type: "object", ...(t.parameters as object) } as { type: "object" } })),
	}));
	mcp.server.setRequestHandler(CallToolRequestSchema, async (request) => {
		const tool = tools.find((t) => t.name === request.params.name);
		if (!tool) return { content: [{ type: "text", text: `No tool ${request.params.name}.` }], isError: true };
		const args = (request.params.arguments ?? {}) as Record<string, unknown>;
		try {
			const r = await tool.execute(callIdFor(tool.name, args), args, signal(), undefined, {});
			type Out = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
			const content = (r.content ?? []).flatMap((c): Out[] =>
				c.type === "image" && c.data ? [{ type: "image", data: c.data, mimeType: c.mimeType ?? "image/png" }] : c.type === "text" ? [{ type: "text", text: c.text ?? "" }] : [],
			);
			return { content: content.length ? content : [{ type: "text" as const, text: "Done." }], ...(r.isError ? { isError: true } : {}) };
		} catch (error) {
			return { content: [{ type: "text" as const, text: (error as Error).message }], isError: true };
		}
	});
	return { type: "sdk" as const, name: PIOPIO_MCP, instance: mcp };
}
