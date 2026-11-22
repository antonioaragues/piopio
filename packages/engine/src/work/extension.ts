/**
 * The board's tools (docs/spec/26 CL3): in a project with parallel work on, Piopio puts tasks on the board, reads it
 * and writes to a task's helper, and gets the board's brief (the playbook, the helpers, the way of working) in every
 * turn's system prompt. A reviewer helper gives its verdict.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { promptSection, type PromptEvent } from "../tools/prompt-sections.js";

export type BoardBridge = {
	/** Piopio in a project conversation, or a task's reviewer. */
	kind: "piopio" | "review";
	/** The board's standing brief, read each turn; empty when parallel work went off. */
	brief(): string;
	createTask(task: { title: string; brief: string; done?: string; helper?: string }): Promise<string>;
	board(): string;
	message(taskId: string, text: string): Promise<void>;
	verdict(pass: boolean, notes: string): string;
};

const text = (t: string, isError = false) => ({ content: [{ type: "text" as const, text: t }], details: {}, ...(isError ? { isError: true } : {}) });

/** Piopio's board tools: declared to the model only while parallel work is on in the project. */
export const BOARD_TOOLS = ["create_task", "list_tasks", "message_task"];

export function boardExtension(bridge: BoardBridge): ExtensionFactory {
	return (pi) => {
		if (bridge.kind === "piopio") {
			// Read each turn, so switching parallel work on or off reaches an open conversation without reopening it.
			pi.on("before_agent_start", (event) => {
				const brief = bridge.brief();
				const active = new Set(pi.getActiveTools());
				for (const name of BOARD_TOOLS) {
					if (brief) active.add(name);
					else active.delete(name);
				}
				pi.setActiveTools([...active]);
				promptSection(event as unknown as PromptEvent, "board", brief || undefined);
				return undefined;
			});
			pi.registerTool(
				defineTool({
					name: "create_task",
					label: "New task",
					description: "Put a task on the project's board; a helper is made for it and starts as soon as there's room. You hear back here when it's done, sent back or blocked. Write a brief another person could do without asking: what, where, constraints.",
					promptSnippet: "create_task: put a task on the project's board for a helper",
					parameters: Type.Object({
						title: Type.String({ description: "A few words" }),
						brief: Type.String({ description: "What to do, where, and any constraints" }),
						done: Type.Optional(Type.String({ description: "What done means for this task" })),
						helper: Type.Optional(Type.String({ description: "What the helper is called on the board, when the playbook names another (\"Editor\"); default the playbook's" })),
					}),
					async execute(_id, params) {
						try {
							return text(await bridge.createTask(params));
						} catch (error) {
							return text((error as Error).message, true);
						}
					},
				}),
			);
			pi.registerTool(
				defineTool({
					name: "list_tasks",
					label: "Board",
					description: "The project's board: every task, its state and helper, and the reports of finished ones.",
					promptSnippet: "list_tasks: read the project's board",
					parameters: Type.Object({}),
					async execute() {
						return text(bridge.board());
					},
				}),
			);
			pi.registerTool(
				defineTool({
					name: "message_task",
					label: "Message a task",
					description: "Write to the helper working on a task: an answer, a correction, more context. A done or blocked task starts again.",
					promptSnippet: "message_task: write to a task's helper",
					parameters: Type.Object({ task_id: Type.String(), text: Type.String() }),
					async execute(_id, params) {
						try {
							await bridge.message(params.task_id, params.text);
							return text(`Sent to ${params.task_id}.`);
						} catch (error) {
							return text((error as Error).message, true);
						}
					},
				}),
			);
		}
		if (bridge.kind === "review") {
			pi.registerTool(
				defineTool({
					name: "verdict",
					label: "Verdict",
					description: "Your verdict on the task you reviewed: pass true when it's done as asked; false with exactly what to change.",
					promptSnippet: "verdict: approve the task or send it back",
					parameters: Type.Object({ pass: Type.Boolean(), notes: Type.Optional(Type.String()) }),
					async execute(_id, params) {
						return text(bridge.verdict(params.pass, params.notes ?? ""));
					},
				}),
			);
		}
	};
}
