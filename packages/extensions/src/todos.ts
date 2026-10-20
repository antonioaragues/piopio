/**
 * piopio-todos: a checklist the agent keeps for multi-step work (docs/spec/05-build §4). The list lives in the
 * tool call's arguments, so it follows the session's branches; Piopio shows the latest one in the inspector.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type TodoStatus = "pending" | "in_progress" | "done";
export type Todo = { text: string; status: TodoStatus };

export function todosExtension(): ExtensionFactory {
	return (pi) => {
		pi.registerTool(
			defineTool({
				name: "todo",
				label: "Todo list",
				description:
					"Keep a short checklist for work with several steps. Send the whole list every time (it replaces the previous one): when you start, and whenever an item starts or is done. Keep exactly one item in_progress while working. Skip it for one-step tasks.",
				promptSnippet: "todo: keep a checklist for multi-step work",
				parameters: Type.Object({
					items: Type.Array(
						Type.Object({
							text: Type.String({ description: "What to do, in a few words." }),
							status: Type.Union([Type.Literal("pending"), Type.Literal("in_progress"), Type.Literal("done")]),
						}),
					),
				}),
				async execute(_toolCallId, params) {
					const done = params.items.filter((t) => t.status === "done").length;
					const current = params.items.find((t) => t.status === "in_progress");
					const text = `${done} of ${params.items.length} done${current ? `. In progress: ${current.text}` : ""}.`;
					return { content: [{ type: "text", text }], details: { todos: params.items } };
				},
			}),
		);
	};
}
