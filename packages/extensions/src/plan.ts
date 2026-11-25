/**
 * piopio-plan: plan mode (docs/spec/05-build §4). While it's on, the agent explores with read-only tools and
 * ends with `propose_plan`; edits, writes and commands that change things are refused. Approving the plan
 * turns plan mode off, and the agent builds it. Off by default; `/plan` toggles it (also in the pi CLI).
 *
 * Whether it's on is kept in the session, as an entry of its own (pi's way to keep an extension's state): it survives
 * closing the session, follows the branch you're on in the session tree, and pi's CLI sees what Piopio set.
 */
import { defineTool, type ExtensionContext, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readOnlyCommand } from "./policy.js";

/** The answer to a plan: approved (as proposed, or as the user edited it) or sent back with a note. */
export type PlanAnswer = { approved: boolean; note?: string; summary?: string; steps?: string[] };

/** The session entry that says plan mode went on or off. */
export const PLAN_ENTRY = "piopio.plan";

/** Whether plan mode is on at the end of a branch's entries; undefined when no entry says. */
export function planFrom(entries: readonly { type: string; customType?: string; data?: unknown }[]): boolean | undefined {
	for (let i = entries.length - 1; i >= 0; i--) {
		const e = entries[i]!;
		if (e.type === "custom" && e.customType === PLAN_ENTRY) return (e.data as { on?: unknown } | undefined)?.on === true;
	}
	return undefined;
}

export interface PlanBridge {
	/** What a branch without an entry starts as: a conversation made in plan mode, or one from before the entry existed. */
	initial?(): boolean;
	/** It went on or off, or the session moved to a branch where it's different (the app shows it). */
	changed?(on: boolean): void;
	/** Shows the plan and waits; undefined when the run was stopped. */
	propose(plan: { callId: string; summary: string; steps: string[] }, signal: AbortSignal | undefined): Promise<PlanAnswer | undefined>;
}

const PLAN_PROMPT = `
# Plan mode
The user turned on plan mode: explore and plan, don't change anything yet.
- Read files and run read-only commands (ls, grep, git log/diff…) to understand the code.
- Don't edit or write files, and don't run commands that change things; those calls are refused.
- When you know what to do, call propose_plan with a short summary and concrete, ordered steps. Steps may use inline Markdown (\`code\`, **bold**) and should fit in one or two lines. Add the files you expect to change and any risks or open questions when you know them.
- Make the plan complete enough that someone else could build it without design decisions of their own.
- Only the user's answer to propose_plan approves it. Agreeing in chat ("sounds good", an answer to your question) approves nothing: fold what they said into the plan and propose it again.
- The user approves the plan, edits it first, or asks for changes. When they edited it, build their version.`;

/** Sets one of pi's named prompt sections (or removes it): pi sends only what changed (docs/spec/38 §8 R1). */
function section(event: unknown, name: string, text: string | undefined): void {
	const sections = (event as { systemPromptOptions: { sections: Record<string, string> } }).systemPromptOptions.sections;
	if (text?.trim()) sections[name] = text.trim();
	else delete sections[name];
}

/** What the host holds to read and set plan mode from outside the conversation (the app's switch). */
export type PlanHandle = { active(): boolean; setActive(on: boolean): void };

export function planExtension(bridge?: PlanBridge, handle?: (plan: PlanHandle) => void): ExtensionFactory {
	return (pi) => {
		const start = () => bridge?.initial?.() ?? process.env.PIOPIO_PLAN === "1";
		let on = start();
		const active = () => on;
		const setActive = (next: boolean) => {
			if (next === on) return;
			on = next;
			pi.appendEntry(PLAN_ENTRY, { on });
			bridge?.changed?.(on);
		};
		const restore = (ctx: ExtensionContext) => {
			const before = on;
			on = planFrom(ctx.sessionManager.getBranch() as never) ?? start();
			if (on !== before) bridge?.changed?.(on);
		};
		pi.on("session_start", (_e, ctx) => restore(ctx));
		pi.on("session_tree", (_e, ctx) => restore(ctx));
		handle?.({ active, setActive });
		pi.registerCommand("plan", {
			description: "Turn plan mode on or off (explore and propose a plan before changing anything)",
			handler: async (_args, ctx) => {
				setActive(!active());
				if (ctx.hasUI) ctx.ui.notify(active() ? "Plan mode is on" : "Plan mode is off", "info");
			},
		});
		pi.on("before_agent_start", (event) => {
			section(event, "plan", active() ? PLAN_PROMPT : undefined);
			return undefined;
		});
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
					steps: Type.Array(Type.String({ description: "A concrete step; inline Markdown is fine." }), { minItems: 1 }),
					files: Type.Optional(Type.Array(Type.String({ description: "A file you expect to change, relative to the project." }))),
					risks: Type.Optional(Type.Array(Type.String({ description: "A risk or an open question the user should know about." }))),
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
						const steps = answer.steps?.length ? answer.steps : params.steps;
						const summary = answer.summary?.trim() || params.summary;
						const edited = steps.join("\n") !== params.steps.join("\n") || summary !== params.summary;
						const text = edited
							? `The user edited the plan and approved their version. Plan mode is off: build this plan, not the one you proposed, tracking the steps with the todo tool.\n\n${summary}\n${steps.map((s, i) => `${i + 1}. ${s}`).join("\n")}`
							: `The user approved the plan${answer.note ? ` (${answer.note})` : ""}. Plan mode is off: build it now, tracking the steps with the todo tool.`;
						return { content: [{ type: "text", text }], details: { approved: true, summary, steps, edited } };
					}
					return { content: [{ type: "text", text: `The user wants changes to the plan before building${answer.note ? `: ${answer.note}` : "."} Keep exploring if needed and propose a new plan.` }], details: { approved: false, ...(answer.note ? { note: answer.note } : {}) } };
				},
			}),
		);
	};
}
