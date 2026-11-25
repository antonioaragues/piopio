/**
 * Submits an input to a conversation and reports how it settled, durably: a pi-durable task that admits the
 * submission with `notify` pointing at itself, sleeps on the `SubmissionSettled` signal, and calls back once it comes.
 *
 * It holds no process while the conversation works, and a restart leaves it asleep: the answer of a run (or of a
 * message from another agent) cut by a restart is still reported, with its real outcome. This is pi-durable's own way
 * to wait for a conversation (its README, "Signals" and "Abort and Subagents").
 *
 * The task belongs to the conversation it submits to, as background work, so stopping the conversation settles the
 * submission and the task reports that too.
 */
import { defineTask, SubmissionSettled, type JsonObject } from "@earendil-works/pi-durable";

export type WatchKind = "run" | "peer";
/** `ref`: what the reporter is told (a run's id, a message's id). `draft`: the submission, without `notify`. */
export type WatchInput = { kind: WatchKind; ref: string; draft: JsonObject };
type State = { phase: "submit" } | { phase: "settled" };

const KEY = "settled";

/** `report` gets the submission's status ("done", or why it went unanswered); it may run again after a crash. */
export function defineSettledTask(report: (kind: WatchKind, ref: string, status: string) => Promise<void>, log: (line: string) => void = () => {}) {
	return defineTask<WatchInput, State, null>({
		name: "piopio.settled",
		version: 1,
		initial: () => ({ phase: "submit" }),
		phases: {
			// The admission and the sleep are one commit: the submission never exists without its watcher.
			submit: async (task, runtime, context) => {
				const conversation = await runtime.conversation(runtime.conversationId, context);
				if (!conversation) return runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), context);
				await runtime.commit(async (tx) => {
					await conversation.submit(tx, { ...task.input.draft, notify: { taskId: runtime.taskId, key: KEY } } as never);
					return { status: "sleeping", signals: [SubmissionSettled.key(KEY)], checkpoint: { phase: "settled" } };
				}, context);
			},
			settled: async (task, runtime, context) => {
				const state = await runtime.readSignal(SubmissionSettled, KEY, context);
				const status = state !== undefined && "value" in state ? state.value.status : "unanswered";
				await report(task.input.kind, task.input.ref, status).catch((error: unknown) => log(`${task.input.kind} ${task.input.ref}: ${(error as Error).message}`));
				await runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), context);
			},
		},
		abort: async (_task, runtime, context) => runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
	});
}
