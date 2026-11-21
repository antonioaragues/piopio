/**
 * A stop for a tool that keeps failing the same way (docs/spec/27 §13: an agent called `automate` twenty times in one
 * turn, each time without a time, and got the same error each time). The repeated-call nudge (repeats.ts) only sees
 * calls with identical arguments; these had different ones and the same error.
 *
 * Since the turn's last user message (or a run's prompt): the third failure of a tool with the same error gets a note
 * telling the model to stop and tell the person; after that, the tool is blocked for the rest of the turn, and once
 * blocked calls keep coming the round ends the run. Kept in memory per conversation: a restart starts the counts again.
 */
import type { ToolExecutionResult } from "@earendil-works/pi-durable";

export const FAILS_BEFORE_STOP = 3;
/** Blocked calls after the stop before the run ends. */
export const BLOCKED_BEFORE_END = 2;

type Turn = { key: string; fails: Map<string, number>; stopped: Map<string, string>; blocked: number; ours: Set<string> };
type Message = { role: string; timestamp?: number; content?: unknown };

const textOf = (result: ToolExecutionResult): string =>
	(result.output ?? [])
		.filter((c) => c.type === "text")
		.map((c) => (c as { text: string }).text)
		.join("")
		.trim();

export function stopNote(tool: string, error: string): string {
	return `[Piopio: ${tool} failed ${FAILS_BEFORE_STOP} times this turn with this same error. It won't run again until the next message. Don't retry: tell the person in a line what failed (“${error.slice(0, 160)}”) and what they could do.]`;
}

export class FailureGuard {
	private readonly turns = new Map<string, Turn>();

	/** Before each model request: a new last user message starts a new turn's counts. */
	request(conversation: string, messages: readonly Message[]): void {
		let last: Message | undefined;
		for (let i = messages.length - 1; i >= 0; i--) {
			if (messages[i]!.role === "user") {
				last = messages[i];
				break;
			}
		}
		const key = last ? `${last.timestamp ?? ""}|${JSON.stringify(last.content ?? "").slice(0, 200)}` : "";
		if (this.turns.get(conversation)?.key !== key) this.turns.set(conversation, { key, fails: new Map(), stopped: new Map(), blocked: 0, ours: new Set() });
	}

	/** Before a call: the block, when this tool was stopped this turn. */
	before(conversation: string, call: { id: string; name: string }): string | undefined {
		const turn = this.turns.get(conversation);
		const error = turn?.stopped.get(call.name);
		if (!turn || error === undefined) return undefined;
		turn.ours.add(call.id);
		return `Not run: ${call.name} already failed ${FAILS_BEFORE_STOP} times this turn (“${error.slice(0, 160)}”). Stop calling it and tell the person what failed.`;
	}

	/** After a call: the result with the stop note, or one that ends the run; undefined to leave it as it is. */
	after(conversation: string, call: { id: string; name: string }, result: ToolExecutionResult): ToolExecutionResult | undefined {
		const turn = this.turns.get(conversation);
		if (!turn) return undefined;
		if (turn.ours.delete(call.id)) {
			turn.blocked += 1;
			return turn.blocked >= BLOCKED_BEFORE_END ? { ...result, control: { ...result.control, terminate: true } } : undefined;
		}
		if (!result.isError || turn.stopped.has(call.name)) return undefined;
		const error = textOf(result);
		const key = `${call.name}\u0000${error}`;
		const n = (turn.fails.get(key) ?? 0) + 1;
		turn.fails.set(key, n);
		if (n < FAILS_BEFORE_STOP) return undefined;
		turn.stopped.set(call.name, error);
		return { ...result, output: [...(result.output ?? []), { type: "text", text: `\n\n${stopNote(call.name, error)}` }] };
	}
}
