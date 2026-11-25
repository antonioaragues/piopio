/**
 * Spike S7 (docs/spec/13-cloud-engine.md): Piopio's agent runtime (`AgentCore` from `@piopio/runtime`) inside the
 * AgentDO. pi-durable is opened by the Agents SDK `PiHarness` (S4); `AgentCore` goes on top of that harness, with the
 * built-in memory provider on this object's SQLite.
 *
 * Waking is pi's own (docs/spec/13 §S7): schedules, reminders and the outbox sleep in pi-durable tasks, pi reports its
 * next sleep through `onWake`, and PiHarness's one Lifecycle job is due then. With `onWake` pi arms no timer for a
 * sleeping task, so nothing pins the object between wakes and it can be evicted with pi open. (Until 2026-11-25 a
 * job of ours, `AgentWake`, was due at a next wake we computed ourselves, and closed pi in between.)
 */
import type { Context } from "@earendil-works/chord/context";
import type { Harness } from "@earendil-works/pi-durable";
import { AgentCore, BuiltinMemory, newDefinition, type AgentDefinition, type Sql } from "@piopio/runtime";

/** The agent's definition, kept in the object's storage; a default one until the app deploys a real one. */
export type StoredAgent = { definition: AgentDefinition; instructions: string };

export function defaultAgent(id: string, model: string): StoredAgent {
	// The personal assistant: memory, reminders and messages on.
	return newDefinition({ id, slug: id, name: id, owner: "owner", model, template: "personal-assistant" });
}

/** `Sql` (synchronous, as the built-in memory provider wants) over a Durable Object's `ctx.storage.sql`. */
export function durableSql(storage: DurableObjectStorage): Sql {
	return {
		exec: (sql) => void storage.sql.exec(sql),
		run: (sql, ...params) => void storage.sql.exec(sql, ...(params as SqlStorageValue[])).toArray(),
		all: <T>(sql: string, ...params: unknown[]) => storage.sql.exec(sql, ...(params as SqlStorageValue[])).toArray() as T[],
	};
}

/** The agent on an open pi harness. */
export class AgentHost {
	readonly core: AgentCore;
	readonly memory: BuiltinMemory;

	constructor(
		readonly pi: Harness,
		private readonly agent: () => StoredAgent,
		storage: DurableObjectStorage,
		context: Context,
		/** The agent sent someone a message on its own (a channel may deliver it). */
		onOutbound?: (to: string, text: string) => void,
	) {
		this.memory = new BuiltinMemory(durableSql(storage), () => crypto.randomUUID());
		this.core = new AgentCore({
			harness: pi,
			definition: () => this.agent().definition,
			instructions: () => this.agent().instructions,
			memory: () => this.memory,
			extensions: () => [],
			context,
			...(onOutbound ? { onOutbound: (to: string, text: string) => onOutbound(to, text) } : {}),
		});
	}
}
