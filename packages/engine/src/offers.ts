/**
 * Piopio offers, it doesn't decide (docs/spec/26 CL9, 21 design 5d-3). In a project conversation with Piopio:
 * work that divides into parts that could run at once, in a project without parallel work: `offer_parallel`, and
 * you choose "Do it here, one by one" or "Work in parallel" (parallel work goes on, and this conversation plans it).
 * It only shows a card; the model stops and waits for your answer. Something to repeat on its own isn't an offer any
 * more: Piopio makes the automation when you ask, with a card and Undo (docs/spec/27 AU4).
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type OffersBridge = {
	/** Parallel work could be offered here: it's off in this project. Read on every turn. */
	canOfferParallel(): boolean;
};

const text = (t: string, isError = false) => ({ content: [{ type: "text" as const, text: t }], details: {}, ...(isError ? { isError: true } : {}) });

export function offersExtension(bridge: OffersBridge): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			if (!bridge.canOfferParallel()) return undefined;
			return { systemPrompt: `${event.systemPrompt}\n\n<offers>\n- When the user asks for work that splits into three or more independent parts that could be done at the same time (several screens, features or documents), don't start: call offer_parallel with why and the parts, then stop. They choose to do it here, one by one, or to work in parallel, with helpers doing the parts at once. Small or single changes you just do.\n</offers>` };
		});
		pi.registerTool(
			defineTool({
				name: "offer_parallel",
				label: "Offer parallel work",
				description: "Offer the user to do work that splits into independent parts in parallel, with helpers. Shows a card with their two choices; stop after calling it.",
				promptSnippet: "offer_parallel: offer parallel work for divisible work",
				parameters: Type.Object({
					why: Type.String({ description: "One sentence: why working in parallel would help here" }),
					parts: Type.Array(Type.String({ description: "A part of the work, a few words" }), { minItems: 2, maxItems: 8 }),
				}),
				async execute() {
					if (!bridge.canOfferParallel()) return text("Parallel work is already on in this project: put the parts on the board, or do the work yourself.", true);
					return text("Offered. Stop here and wait for their choice.");
				},
			}),
		);
	};
}
