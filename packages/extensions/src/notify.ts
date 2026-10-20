/**
 * piopio-notify: lets the agent ask you something and wait (`ask_user`), or tell you something without
 * waiting (`notify_user`). In Piopio a question puts the session in "waiting for you"; in the pi CLI they
 * use pi's own dialogs.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type Question = { callId: string; question: string; options?: string[] };

export interface NotifyBridge {
	/** Waits for the answer; undefined when the run was stopped. */
	ask(question: Question, signal: AbortSignal | undefined): Promise<string | undefined>;
	notify(message: string): void;
}

export function notifyExtension(bridge?: NotifyBridge): ExtensionFactory {
	return (pi) => {
		pi.registerTool(
			defineTool({
				name: "ask_user",
				label: "Ask the user",
				description:
					"Ask the user a question and wait for the answer. Use it when you need a decision or information only they have (a choice between approaches, a missing requirement). Don't use it for routine confirmations. Offer `options` when the answer is one of a few choices.",
				promptSnippet: "ask_user: ask the user a question and wait for the answer",
				parameters: Type.Object({
					question: Type.String({ description: "The question, in one or two sentences." }),
					options: Type.Optional(Type.Array(Type.String(), { description: "Short choices; the user can still answer in their own words." })),
				}),
				async execute(toolCallId, params, signal, _onUpdate, ctx) {
					let answer: string | undefined;
					if (bridge) answer = await bridge.ask({ callId: toolCallId, question: params.question, ...(params.options?.length ? { options: params.options } : {}) }, signal);
					else if (ctx.hasUI) answer = params.options?.length ? await ctx.ui.select(params.question, params.options) : await ctx.ui.input(params.question);
					const text = answer === undefined ? "The user didn't answer." : `The user answered: ${answer}`;
					return { content: [{ type: "text", text }], details: { answer: answer ?? null } };
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "notify_user",
				label: "Notify the user",
				description: "Tell the user something important without waiting for an answer, such as a long task finishing or a problem they should know about.",
				promptSnippet: "notify_user: tell the user something without waiting",
				parameters: Type.Object({ message: Type.String({ description: "One or two sentences." }) }),
				async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
					if (bridge) bridge.notify(params.message);
					else if (ctx.hasUI) ctx.ui.notify(params.message, "info");
					return { content: [{ type: "text", text: "The user was notified." }], details: {} };
				},
			}),
		);
	};
}
