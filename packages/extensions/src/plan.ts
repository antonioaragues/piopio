/**
 * piopio-plan: plan mode (docs/spec/05-build §4). While it's on, the agent explores with read-only tools and
 * ends with `propose_plan`; edits, writes and commands that change things are refused. Approving the plan
 * turns plan mode off, and the agent builds it. Off by default; `/plan` toggles it (also in the pi CLI).
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readOnlyCommand } from "./policy.js";

export type PlanAnswer = { approved: boolean; note?: string };

export interface PlanBridge {
	active(): boolean;
	setActive(on: boolean): void;
	/** Shows the plan and waits; undefined when the run was stopped. */
	propose(plan: { callId: string; summary: string; steps: string[] }, signal: AbortSignal | undefined): Promise<PlanAnswer | undefined>;
}

const PLAN_PROMPT = `
# Plan mode
The user turned on plan mode: explore and plan, don't change anything yet.
- Read files and run read-only commands (ls, grep, git log/diff…) to understand the code.
- Don't edit or write files, and don't run commands that change things; those calls are refused.
- When you know what to do, call propose_plan with a short summary and concrete, ordered steps. The user approves it or asks for changes.`;

export function planExtension(bridge?: PlanBridge): ExtensionFactory {
	let cliActive = process.env.PIOPIO_PLAN === "1";
	const active = () => bridge?.active() ?? cliActive;
	const setActive = (on: boolean) => (bridge ? bridge.setActive(on) : (cliActive = on));
	return (pi) => {
		pi.registerCommand("plan", {
			description: "Turn plan mode on or off (explore and propose a plan before changing anything)",
			handler: async (_args, ctx) => {
				setActive(!active());
				if (ctx.hasUI) ctx.ui.notify(active() ? "Plan mode is on" : "Plan mode is off", "info");
			},
		});
		pi.on("before_agent_start", (event) => (active() ? { systemPrompt: `${event.systemPrompt}\n${PLAN_PROMPT}` } : undefined));
		pi.on("tool_call", (event) => {
			if (!active()) return undefined;
			if (event.toolName === "edit" || event.toolName === "write") {
				return { block: true, reason: "Plan mode is on: don't change files yet. Finish exploring, then call propose_plan." };
			}
			if (event.toolName === "bash" && !readOnlyCommand(String((event.input as { command?: unknown }).command ?? ""))) {
				return { block: true, reason: "Plan mode is on: only read-only commands run. Finish exploring, then call propose_plan." };
			}
			return undefined;
		});
		pi.registerTool(
			defineTool({
				name: "propose_plan",
				label: "Propose a plan",
				description: "In plan mode, present your plan for approval: a short summary and the ordered steps you'll take. Wait for the answer before changing anything.",
				promptSnippet: "propose_plan: present a plan for approval (plan mode)",
				parameters: Type.Object({
					summary: Type.String({ description: "One or two sentences: what you'll do and why." }),
					steps: Type.Array(Type.String({ description: "A concrete step." }), { minItems: 1 }),
				}),
				async execute(toolCallId, params, signal, _onUpdate, ctx) {
					if (!active()) return { content: [{ type: "text", text: "Plan mode is off; go ahead with the work." }], details: { approved: true } };
					let answer: PlanAnswer | undefined;
					if (bridge) answer = await bridge.propose({ callId: toolCallId, summary: params.summary, steps: params.steps }, signal);
					else if (ctx.hasUI) {
						const choice = await ctx.ui.select(`${params.summary}\n${params.steps.map((s, i) => `${i + 1}. ${s}`).join("\n")}`, ["Approve and build", "Keep planning"]);
						answer = choice === "Approve and build" ? { approved: true } : choice ? { approved: false } : undefined;
					}
					if (!answer) return { content: [{ type: "text", text: "The plan wasn't answered." }], details: { approved: false } };
					if (answer.approved) {
						setActive(false);
						return {
							content: [{ type: "text", text: `The user approved the plan${answer.note ? ` (${answer.note})` : ""}. Plan mode is off: build it now, tracking the steps with the todo tool.` }],
							details: { approved: true, steps: params.steps },
						};
					}
					return { content: [{ type: "text", text: `The user wants changes to the plan before building${answer.note ? `: ${answer.note}` : "."} Keep exploring if needed and propose a new plan.` }], details: { approved: false } };
				},
			}),
		);
	};
}
