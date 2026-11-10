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
	/** Routines (docs/spec/19 T1): what starts the team's work on its own. */
	addRoutine(routine: { on: "time" | "folder" | "email" | "webhook"; prompt: string; when?: string; folder?: string; from?: string; subject?: string }): Promise<string>;
	routines(): string;
	cancelRoutine(id: string): Promise<string>;
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
		if (bridge.kind === "lead") {
			const routine = async (input: Parameters<TeamBridge["addRoutine"]>[0]) => {
				try {
					return text(await bridge.addRoutine(input));
				} catch (error) {
					return text((error as Error).message, true);
				}
			};
			pi.registerTool(
				defineTool({
					name: "schedule",
					label: "Routine",
					description: "Start the team's work at a time, without the user asking: once (a date and time, e.g. 2026-11-16T09:00, local time) or repeating (a 5-field cron, e.g. \"0 9 * * 1\" for Mondays at 9). When it fires you get the prompt as a [Routine] message and plan it like a request.",
					promptSnippet: "schedule: a routine at a time",
					parameters: Type.Object({
						when: Type.String({ description: "A local date-time, or a 5-field cron" }),
						prompt: Type.String({ description: "What the team should do then, e.g. “Write this week's brief on our competitors”" }),
					}),
					async execute(_id, params) {
						return routine({ on: "time", when: params.when, prompt: params.prompt });
					},
				}),
			);
			pi.registerTool(
				defineTool({
					name: "watch",
					label: "Routine",
					description: "Start the team's work when something happens: \"folder\" (a file appears or changes in a folder on this Mac), \"email\" (a new email from someone and/or about something, in the user's connected mail) or \"webhook\" (a URL other apps can call). You get the prompt and what happened as a [Routine] message.",
					promptSnippet: "watch: a routine on an event",
					parameters: Type.Object({
						on: Type.Union([Type.Literal("folder"), Type.Literal("email"), Type.Literal("webhook")]),
						prompt: Type.String({ description: "What the team should do then" }),
						folder: Type.Optional(Type.String({ description: "folder: an absolute path, or one starting with ~/" })),
						from: Type.Optional(Type.String({ description: "email: part of the sender's name or address" })),
						subject: Type.Optional(Type.String({ description: "email: words in the subject" })),
					}),
					async execute(_id, params) {
						return routine(params);
					},
				}),
			);
			pi.registerTool(
				defineTool({
					name: "list_routines",
					label: "Routines",
					description: "The team's routines: what starts its work on its own, and when they fire next.",
					promptSnippet: "list_routines: the team's routines",
					parameters: Type.Object({}),
					async execute() {
						return text(bridge.routines());
					},
				}),
			);
			pi.registerTool(
				defineTool({
					name: "cancel_routine",
					label: "Remove routine",
					description: "Remove one of the team's routines, by id.",
					promptSnippet: "cancel_routine: remove a routine",
					parameters: Type.Object({ id: Type.String() }),
					async execute(_id, params) {
						try {
							return text(await bridge.cancelRoutine(params.id));
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
