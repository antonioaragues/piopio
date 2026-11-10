/**
 * The board's tools in a team's Build sessions (docs/spec/19 §4): the lead puts tasks on the board, reads it and writes
 * to a task's member; a reviewer gives its verdict. The lead also gets its team's brief in every turn's system prompt.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { RoleKind } from "./templates.js";

export type TeamBridge = {
	kind: RoleKind;
	/** The lead's standing brief: its team, roles and way of working. */
	brief(): string;
	createTask(task: { title: string; brief: string; done?: string; role?: string }): Promise<string>;
	board(): string;
	message(taskId: string, text: string): Promise<void>;
	verdict(pass: boolean, notes: string): string;
};

const text = (t: string, isError = false) => ({ content: [{ type: "text" as const, text: t }], details: {}, ...(isError ? { isError: true } : {}) });

export function teamExtension(bridge: TeamBridge): ExtensionFactory {
	return (pi) => {
		if (bridge.kind === "lead") {
			pi.on("before_agent_start", (event) => ({ systemPrompt: `${event.systemPrompt}\n\n<team>\n${bridge.brief()}\n</team>` }));
			pi.registerTool(
				defineTool({
					name: "create_task",
					label: "New task",
					description: "Put a task on the team's board for a member to do. It starts as soon as there's room; you hear back on the board when it's done, sent back or blocked. Write a brief another person could do without asking: what, where, constraints.",
					promptSnippet: "create_task: put a task on the team's board",
					parameters: Type.Object({
						title: Type.String({ description: "A few words" }),
						brief: Type.String({ description: "What to do, where, and any constraints" }),
						done: Type.Optional(Type.String({ description: "What done means for this task" })),
						role: Type.Optional(Type.String({ description: "The role id that does it; default the first that does tasks" })),
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
					description: "The team's board: every task, its state and owner, and the reports of finished ones.",
					promptSnippet: "list_tasks: read the team's board",
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
					description: "Write to the member working on a task: an answer, a correction, more context. A done or blocked task starts again.",
					promptSnippet: "message_task: write to a task's member",
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
