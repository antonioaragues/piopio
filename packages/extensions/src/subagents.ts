/**
 * piopio-subagents: a `task` tool that hands self-contained work to a subagent with its own context window
 * (docs/spec/05-build §4). Piopio runs each one as a child Build session you can open, with the parent's
 * approval mode, and counts its cost toward the parent. Without a bridge (pi CLI) it isn't registered.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type TaskResult = { text: string; sessionId: string; costUsd: number; status: "done" | "error" | "stopped" };

export interface SubagentBridge {
	/** Runs the task to completion. `onStart` gives the child session id early; `onProgress`, a line of what it's doing. */
	run(
		task: { callId: string; description: string; prompt: string },
		signal: AbortSignal | undefined,
		onStart: (sessionId: string) => void,
		onProgress: (line: string) => void,
	): Promise<TaskResult>;
}

export function subagentsExtension(bridge?: SubagentBridge): ExtensionFactory {
	return (pi) => {
		if (!bridge) return;
		pi.registerTool(
			defineTool({
				name: "task",
				label: "Subagent",
				description:
					"Hand a self-contained task to a subagent with its own fresh context window: exploring part of the codebase, researching an API, or an isolated change. It works in the same project with the same tools and permissions, and returns its final answer. It can't see this conversation, so put everything it needs in `prompt`. Several tasks can run in parallel (at most 3 at a time).",
				promptSnippet: "task: delegate self-contained work to a subagent with its own context",
				parameters: Type.Object({
					description: Type.String({ description: "A short title (3–6 words)." }),
					prompt: Type.String({ description: "The full task: goal, relevant files, constraints, and what to report back." }),
				}),
				async execute(toolCallId, params, signal, onUpdate) {
					let sessionId = "";
					const update = (line: string) => onUpdate?.({ content: [{ type: "text", text: line }], details: { sessionId } });
					const result = await bridge.run(
						{ callId: toolCallId, description: params.description, prompt: params.prompt },
						signal,
						(id) => {
							sessionId = id;
							update("Starting…");
						},
						update,
					);
					const text = result.status === "done" ? result.text : `The subagent ${result.status === "stopped" ? "was stopped" : "failed"}${result.text ? `: ${result.text}` : "."}`;
					return { content: [{ type: "text", text }], details: { sessionId: result.sessionId, costUsd: result.costUsd, status: result.status }, ...(result.status === "error" ? { isError: true } : {}) };
				},
			}),
		);
	};
}
