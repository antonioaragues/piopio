/**
 * piopio-goal: a session that keeps going until something is done (docs/research/deepseek-harness.md §2.1).
 *
 * - `/goal <what done looks like>` sets the goal and starts. When the agent finishes a turn without saying the goal is
 *   done, it gets another turn ("round") toward it, up to `MAX_ROUNDS`.
 * - The agent ends it with `update_goal`: "done" (with what it did) or "blocked" (with what it needs from you).
 * - Pressing Stop pauses it; `/goal` alone says where it stands, `/goal continue` resumes, `/goal off` clears it.
 * - The goal is kept in the session file, so it survives closing the session or quitting.
 */
import { defineTool, type ExtensionAPI, type ExtensionContext, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export const GOAL_ENTRY = "piopio.goal";
export const MAX_ROUNDS = 25;

export type GoalStatus = "active" | "done" | "blocked" | "paused" | "off";
export type Goal = { objective: string; status: GoalStatus; rounds: number; maxRounds: number; note?: string };

/** The latest goal in a branch's entries, if any. */
export function goalFrom(entries: readonly { type: string; customType?: string; data?: unknown }[]): Goal | undefined {
	for (let i = entries.length - 1; i >= 0; i--) {
		const e = entries[i]!;
		if (e.type === "custom" && e.customType === GOAL_ENTRY) return e.data as Goal;
	}
	return undefined;
}

export function goalPrompt(goal: Goal): string {
	return `You're working toward a goal the user set: ${goal.objective}\nWork through it step by step on your own; you'll get more turns until it's done (round ${goal.rounds} of ${goal.maxRounds} so far). Check your work (run the tests, open the result). When the goal is met, call update_goal with status "done" and one line on what you did. If you can't go on without the user (a decision, an access, the same failure again and again), call update_goal with status "blocked" and say what you need. Don't stop to ask whether to continue.`;
}

const continuation = (goal: Goal) => `Keep going toward the goal: ${goal.objective}\n(Round ${goal.rounds} of ${goal.maxRounds}. When it's met, call update_goal with status "done"; if you're stuck, status "blocked".)`;

export function goalExtension(): ExtensionFactory {
	return (pi: ExtensionAPI) => {
		let goal: Goal | undefined;

		const save = (next: Goal) => {
			goal = next;
			pi.appendEntry(GOAL_ENTRY, next);
		};
		const note = (summary: string) => pi.sendMessage({ customType: GOAL_ENTRY, content: summary, display: true, details: { summary } }, { triggerTurn: false });
		const restore = (ctx: ExtensionContext) => {
			goal = goalFrom(ctx.sessionManager.getBranch() as never);
		};
		pi.on("session_start", (_e, ctx) => restore(ctx));
		pi.on("session_tree", (_e, ctx) => restore(ctx));

		pi.on("before_agent_start", (event) => (goal?.status === "active" ? { systemPrompt: `${event.systemPrompt}\n\n${goalPrompt(goal)}` } : undefined));

		// Each round is a new run, started once the session has fully settled, so it shows like any other message.
		let outcome: "completed" | "aborted" | "error" = "completed";
		pi.on("agent_before_settle", (event) => {
			outcome = event.outcome;
			return undefined;
		});
		pi.on("agent_settled", (event) => {
			if (goal?.status !== "active") return;
			if (event.aborted || outcome !== "completed") {
				save({ ...goal, status: "paused", note: event.aborted ? "You stopped it" : "The run failed" });
				note(`Goal paused (${goal.note!.toLowerCase()}). /goal continue picks it up again.`);
				return;
			}
			if (goal.rounds >= goal.maxRounds) {
				save({ ...goal, status: "blocked", note: `It reached ${goal.maxRounds} rounds` });
				note(`Goal stopped after ${goal.maxRounds} rounds without being done. /goal continue gives it more.`);
				return;
			}
			save({ ...goal, rounds: goal.rounds + 1 });
			pi.sendMessage({ customType: GOAL_ENTRY, content: continuation(goal), display: true, details: { summary: `Goal · round ${goal.rounds} of ${goal.maxRounds}` } }, { triggerTurn: true });
		});

		pi.registerTool(
			defineTool({
				name: "update_goal",
				label: "Goal",
				description: "End the goal the user set with /goal: \"done\" once it's met (and checked), or \"blocked\" when you can't go on without the user. Only while a goal is active.",
				parameters: Type.Object({
					status: Type.Union([Type.Literal("done"), Type.Literal("blocked")]),
					note: Type.String({ description: "Done: what you did, in one line. Blocked: what you need from the user." }),
				}),
				async execute(_id, params) {
					if (goal?.status !== "active") return { content: [{ type: "text", text: "There's no active goal." }], details: {}, isError: true } as never;
					save({ ...goal, status: params.status, note: params.note });
					return { content: [{ type: "text", text: params.status === "done" ? "Goal marked done." : "Goal marked blocked; the user will see what you need." }], details: { goal } };
				},
			}),
		);

		pi.registerCommand("goal", {
			description: "Keep working on its own until something is done: /goal <what done looks like>. /goal off stops; /goal continue resumes.",
			handler: async (args, ctx) => {
				const text = args.trim();
				if (!text) {
					ctx.ui.notify(goal && goal.status !== "off" ? `Goal (${goal.status}${goal.note ? `: ${goal.note}` : ""}, round ${goal.rounds} of ${goal.maxRounds}): ${goal.objective}` : "No goal. Set one with /goal <what done looks like>.", "info");
					return;
				}
				if (text === "off" || text === "stop" || text === "clear") {
					if (goal) save({ ...goal, status: "off" });
					note("Goal cleared.");
					return;
				}
				if (text === "continue" || text === "resume") {
					if (!goal || goal.status === "off" || goal.status === "done") {
						ctx.ui.notify("There's no goal to continue. Set one with /goal <what done looks like>.", "warning");
						return;
					}
					// More rounds when it ran out.
					save({ ...goal, status: "active", note: undefined, maxRounds: goal.rounds >= goal.maxRounds ? goal.rounds + MAX_ROUNDS : goal.maxRounds });
					note(`Goal resumed: ${goal.objective}`);
					pi.sendUserMessage(continuation(goal));
					return;
				}
				save({ objective: text, status: "active", rounds: 1, maxRounds: MAX_ROUNDS });
				note(`Goal set: ${text.replace(/[.!\s]+$/, "")}. Piopio keeps it going for up to ${MAX_ROUNDS} rounds, until it's done or needs you.`);
				pi.sendUserMessage(`My goal for this session: ${text}`);
			},
		});
	};
}
