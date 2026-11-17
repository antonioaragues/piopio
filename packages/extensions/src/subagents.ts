/**
 * piopio-subagents: a `task` tool that hands self-contained work to a subagent with its own context window
 * (docs/spec/05-build §4). Piopio runs each one as a child Build session you can open, with the parent's
 * approval mode, and counts its cost toward the parent. Without a bridge (pi CLI) it isn't registered.
 *
 * Non-blocking (docs/spec/17 §3, 26 §7.1): with a bridge that can `start` one, `task` returns at once and the result
 * comes back later as a `[Task]` message, the way a side conversation's report does; `task_wait` waits for some when
 * the parent can't go on without them, and `task_stop` stops one. `wait: true` keeps the old behaviour.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type TaskResult = { text: string; sessionId: string; costUsd: number; status: "done" | "error" | "stopped" };

export interface SubagentBridge {
	/** Runs the task to completion. `onStart` gives the child session id early; `onProgress`, a line of what it's doing. */
	run(
		task: { callId: string; description: string; prompt: string; agent?: string },
		signal: AbortSignal | undefined,
		onStart: (sessionId: string) => void,
		onProgress: (line: string) => void,
	): Promise<TaskResult>;
	/** Starts one and returns at once; its result comes back to the parent later. Absent: `task` always waits. */
	start?(task: { callId: string; description: string; prompt: string }): Promise<{ sessionId: string; queued: boolean }>;
	/** Waits for these (by session id) to finish, and their results. */
	wait?(ids: readonly string[], signal: AbortSignal | undefined): Promise<TaskResult[]>;
	/** Stops one's running turn (or its start, when queued). */
	stop?(id: string): Promise<string>;
	/** Other agents a task can go to, by CLI name ("claude", "codex"), when installed. */
	agents?: readonly string[];
}

const AGENT_LABELS: Record<string, string> = { claude: "Claude Code", codex: "OpenAI Codex" };

const resultText = (r: TaskResult) => (r.status === "done" ? r.text : `The subagent ${r.status === "stopped" ? "was stopped" : "failed"}${r.text ? `: ${r.text}` : "."}`);

export function subagentsExtension(bridge?: SubagentBridge): ExtensionFactory {
	return (pi) => {
		if (!bridge) return;
		const later = !!bridge.start;
		pi.registerTool(
			defineTool({
				name: "task",
				label: "Subagent",
				description: later
					? "Hand a self-contained task to a subagent with its own fresh context window: exploring part of the codebase, researching an API, or an isolated change. It works in the same project with the same tools and permissions. It can't see this conversation, so put everything it needs in `prompt`. It returns at once with its id; its result comes back later as a message that starts with [Task], and you may end your turn meanwhile. Use task_wait when you can't go on without a result, or `wait: true` for one you need right away. Use it when the work would fill this conversation's context or really can run in parallel, not for every step (at most 3 run at a time; more wait their turn)."
					: "Hand a self-contained task to a subagent with its own fresh context window: exploring part of the codebase, researching an API, or an isolated change. It works in the same project with the same tools and permissions, and returns its final answer. It can't see this conversation, so put everything it needs in `prompt`. Several tasks can run in parallel (at most 3 at a time).",
				promptSnippet: "task: delegate self-contained work to a subagent with its own context",
				parameters: Type.Object({
					description: Type.String({ description: "A short title (3–6 words)." }),
					prompt: Type.String({ description: "The full task: goal, relevant files, constraints, and what to report back." }),
					...(later ? { wait: Type.Optional(Type.Boolean({ description: "Wait here for its answer (default false: it comes back later as a [Task] message)" })) } : {}),
					...(bridge.agents?.length
						? {
								agent: Type.Optional(
									Type.Union([Type.Literal("piopio"), ...bridge.agents.map((a) => Type.Literal(a))], {
										description: `Who does it. "piopio" (the default): a Piopio subagent you can follow. ${bridge.agents.map((a) => `"${a}": ${AGENT_LABELS[a] ?? a} on the user's own account, unattended in this folder (it always waits)`).join("; ")}. Use another agent only when the user asks for it or a second opinion helps.`,
									}),
								),
							}
						: {}),
				}),
				async execute(toolCallId, params, signal, onUpdate) {
					const agent = (params as { agent?: string }).agent;
					const external = !!agent && agent !== "piopio";
					// Started now, answered later: the result comes back as a [Task] message (docs/spec/17 §3).
					if (later && !external && (params as { wait?: boolean }).wait !== true) {
						const { sessionId, queued } = await bridge.start!({ callId: toolCallId, description: params.description, prompt: params.prompt });
						return {
							content: [{ type: "text", text: `Started ${sessionId}${queued ? " (queued: 3 are running)" : ""}. Its result comes back as a [Task] message; task_wait waits for it.` }],
							details: { sessionId, status: queued ? "queued" : "started" },
						};
					}
					let sessionId = "";
					const update = (line: string) => onUpdate?.({ content: [{ type: "text", text: line }], details: { sessionId } });
					const result = await bridge.run(
						{ callId: toolCallId, description: params.description, prompt: params.prompt, ...(external ? { agent } : {}) },
						signal,
						(id) => {
							sessionId = id;
							update("Starting…");
						},
						update,
					);
					return { content: [{ type: "text", text: resultText(result) }], details: { sessionId: result.sessionId, costUsd: result.costUsd, status: result.status }, ...(result.status === "error" ? { isError: true } : {}) };
				},
			}),
		);
		if (!later) return;
		pi.registerTool(
			defineTool({
				name: "task_wait",
				label: "Wait for subagents",
				description: "Wait for subagents you started (by their ids) to finish, and get their results here. Their [Task] messages then don't come.",
				promptSnippet: "task_wait: wait for subagents' results",
				parameters: Type.Object({ ids: Type.Array(Type.String(), { minItems: 1 }) }),
				async execute(_id, params, signal) {
					try {
						const results = await bridge.wait!(params.ids, signal);
						const text = results.map((r) => `${r.sessionId}: ${resultText(r)}`).join("\n\n---\n\n");
						return { content: [{ type: "text", text }], details: { results: results.map((r) => ({ sessionId: r.sessionId, status: r.status, costUsd: r.costUsd })) } };
					} catch (error) {
						return { content: [{ type: "text", text: (error as Error).message }], details: { results: [] }, isError: true };
					}
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "task_stop",
				label: "Stop a subagent",
				description: "Stop a subagent you started, by its id.",
				promptSnippet: "task_stop: stop a subagent",
				parameters: Type.Object({ id: Type.String() }),
				async execute(_id, params) {
					try {
						return { content: [{ type: "text", text: await bridge.stop!(params.id) }], details: {} };
					} catch (error) {
						return { content: [{ type: "text", text: (error as Error).message }], details: {}, isError: true };
					}
				},
			}),
		);
	};
}
