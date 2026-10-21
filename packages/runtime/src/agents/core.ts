/**
 * An agent's conversations and memory on pi-durable (docs/spec/06-agents §3, §8), shared by the local engine and
 * the Cloud Engine. One agent is one pi-durable session; each person has one conversation (`person:<contactId>`),
 * whatever channel they write from. Memory partitions are banks of a memory provider, so a contact can't see
 * another's memory (AS2): the owner's conversation reads `owner` and `shared`; a contact's reads `shared` and its
 * own `contacts/<id>`.
 */
import type { Context } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import { configure, defineDoc, defineExtension, defineTool, section, type ConversationId, type Extension, type Harness } from "@earendil-works/pi-durable";
import type { MemoryProvider, MemoryRecord } from "../memory/provider.js";
import type { AgentDefinition, Contact } from "./definition.js";
import { Proactivity, type ProactiveState, type RunRecord } from "./proactive.js";

type AgentState = ProactiveState & {
	/** contact id → conversation id. */
	people: Record<string, string>;
	/** conversation id → the memory recalled for its current turn (the system section shows it). */
	recalled: Record<string, string>;
};

export const AgentStateDoc = defineDoc<AgentState>({ kind: "piopio.agent-state", version: 1, scope: "session", initial: () => ({ people: {}, recalled: {} }) });

export type Partition = "owner" | "shared" | `contacts/${string}`;

/** The banks a person's conversation reads, and where its memory writes go. */
export function partitionsFor(contact: Pick<Contact, "id" | "role">): { read: Partition[]; write: Partition[]; home: Partition } {
	if (contact.role === "owner") return { read: ["owner", "shared"], write: ["owner", "shared"], home: "owner" };
	const own = `contacts/${contact.id}` as const;
	return { read: ["shared", own], write: [own], home: own };
}

export const bankOf = (agentId: string, partition: Partition) => `${agentId}/${partition}`;

/** "openrouter" ids look like "anthropic/claude-…"; other providers are written "provider:model". */
export function modelOf(id: string): { provider: string; modelId: string } {
	const colon = id.indexOf(":");
	return colon > 0 ? { provider: id.slice(0, colon), modelId: id.slice(colon + 1) } : { provider: "openrouter", modelId: id };
}

export type AgentCoreOptions = {
	harness: Harness;
	definition: () => AgentDefinition;
	instructions: () => string;
	memory: () => MemoryProvider;
	/** Extensions every person's conversation runs with besides the agent's own (web tools…), by name. */
	extensions: () => Extension[];
	context: Context;
	now?: () => Date;
	/** Someone was sent a message, or a run started or settled (the app shows them). */
	onOutbound?: (to: string, text: string, from: string) => void;
	onRun?: (run: RunRecord) => void;
};

export class AgentCore {
	readonly extension: Extension;
	readonly proactive: Proactivity;
	private memoryTools: { name: string }[] = [];

	constructor(private readonly options: AgentCoreOptions) {
		const { harness, context } = options;
		this.proactive = new Proactivity({
			harness,
			context,
			definition: () => this.def,
			now: () => (options.now?.() ?? new Date()).getTime(),
			read: async () => ({ people: {}, recalled: {}, ...((await harness.snapshot(AgentStateDoc, context)) ?? {}) }) as never,
			write: (change) => harness.commit(async (tx) => change((await tx.doc(AgentStateDoc)) as never), context),
			person: (id) => this.conversation(id) as never,
			newConversation: () => this.newConversation(),
			recallForRun: (conversationId, prompt) => this.recallInto(conversationId, ["owner", "shared"], prompt),
			onOutbound: (to, text, from) => {
				// What the agent sent on its own goes to that person's memory too, so later turns know about it.
				const contact = this.contact(to);
				if (contact && this.usesMemory) {
					void this.options
						.memory()
						.retain(bankOf(this.def.id, partitionsFor(contact).home), { content: `${this.def.name} (on its own): ${text}`, kind: "message", createdBy: "agent", source: { ref: from, title: this.def.name } })
						.catch(() => undefined);
				}
				options.onOutbound?.(to, text, from);
			},
			...(options.onRun ? { onRun: options.onRun } : {}),
		});
		this.extension = this.makeExtension();
	}

	/** Schedules running, runs a previous engine left followed again, held messages flushed. */
	async start(): Promise<void> {
		await this.proactive.reconcile();
		await this.proactive.resumeRuns();
		await this.proactive.flush().catch(() => 0);
	}

	/** A conversation with no person (a run, the scheduler), with the agent's model and tools. */
	private async newConversation(): Promise<ConversationId> {
		const record = await this.options.harness.commit((tx) => tx.createConversation({ ownership: { kind: "ownerless" } }), this.options.context);
		await this.configure(record.id);
		return record.id;
	}

	private get def(): AgentDefinition {
		return this.options.definition();
	}

	contact(id: string): Contact | undefined {
		return this.def.contacts.find((c) => c.id === id);
	}

	/** The person whose conversation this is. */
	async contactOf(conversationId: ConversationId | string, context = this.options.context): Promise<Contact | undefined> {
		const state = await this.options.harness.snapshot(AgentStateDoc, context);
		const id = Object.entries(state?.people ?? {}).find(([, c]) => c === String(conversationId))?.[0];
		return id ? this.contact(id) : undefined;
	}

	/** The person's conversation, made on first contact. */
	async conversation(contactId: string) {
		const { harness, context } = this.options;
		if (!this.contact(contactId)) throw new Error(`No contact ${contactId}`);
		const id = await harness.commit(async (tx) => {
			const doc = await tx.doc(AgentStateDoc);
			if (doc.people[contactId]) return doc.people[contactId]!;
			const record = await tx.createConversation({ ownership: { kind: "ownerless" } });
			doc.people[contactId] = String(record.id);
			return String(record.id);
		}, context);
		const conversation = await harness.conversation(Number(id) as never, context);
		if (!conversation) throw new Error(`Lost the conversation of ${contactId}`);
		await this.configure(conversation.id);
		return conversation;
	}

	/** Every person's conversation gets the definition's model and tools (after an edit too). */
	async configure(conversationId: ConversationId): Promise<void> {
		const { harness, context } = this.options;
		// Tools the definition doesn't turn on are left out of what the model is offered.
		const builtin = this.def.tools.builtin;
		const p = this.proactive.tools;
		const off = [
			...(builtin.includes("memory") ? [] : this.memoryTools),
			...(builtin.includes("send_message") ? [] : [p.send]),
			...(builtin.includes("schedule") ? [] : [p.schedule, p.list, p.cancel]),
		];
		await harness.commit(async (tx) => {
			await configure(tx, conversationId, {
				model: modelOf(this.def.models.default),
				thinkingLevel: this.def.thinking && this.def.thinking !== "off" ? this.def.thinking : null,
				extensions: [this.extension, ...this.options.extensions()],
				tools: off.length ? { remove: off } : null,
			} as never);
		}, context);
	}

	async configureAll(): Promise<void> {
		const state = await this.options.harness.snapshot(AgentStateDoc, this.options.context);
		for (const id of Object.values(state?.people ?? {})) await this.configure(Number(id) as never);
		await this.proactive.reconcile();
	}

	people(): Promise<Record<string, string>> {
		return this.options.harness.snapshot(AgentStateDoc, this.options.context).then((s) => ({ ...(s?.people ?? {}) }));
	}

	/** Before a turn: the memory relevant to `text`, for the system section (ME2). */
	async beforeTurn(contactId: string, conversationId: ConversationId, text: string): Promise<void> {
		const contact = this.contact(contactId);
		if (!contact || !this.usesMemory) return;
		await this.recallInto(conversationId, partitionsFor(contact).read, text);
	}

	/** Recalls what's relevant to `text` from `partitions` into the conversation's notes. */
	private async recallInto(conversationId: ConversationId, partitions: readonly Partition[], text: string): Promise<void> {
		if (!this.usesMemory) return;
		const banks = partitions.map((p) => bankOf(this.def.id, p));
		const provider = this.options.memory();
		const [hits, standing] = await Promise.all([
			provider.recall(banks, text, { budgetTokens: 1200 }).catch(() => []),
			Promise.all(banks.map((b) => provider.standing?.(b).catch(() => []) ?? Promise.resolve([] as MemoryRecord[]))).then((r) => r.flat()),
		]);
		const seen = new Set<string>();
		const lines = [...standing, ...hits].filter((r) => !seen.has(r.id) && seen.add(r.id)).map((r) => `- ${r.at ? `[${r.at.slice(0, 10)}] ` : ""}${r.text}`);
		await this.options.harness.commit(async (tx) => {
			(await tx.doc(AgentStateDoc)).recalled[String(conversationId)] = lines.join("\n");
		}, this.options.context);
	}

	/** After a turn: the message and the answer go to the person's partition (ME2a). Never delays the reply. */
	async afterTurn(contactId: string, said: string, answer: string, source: { ref: string; itemId?: string }): Promise<void> {
		const contact = this.contact(contactId);
		if (!contact || !this.usesMemory) return;
		const bank = bankOf(this.def.id, partitionsFor(contact).home);
		const provider = this.options.memory();
		const at = (this.options.now?.() ?? new Date()).toISOString();
		await provider.retain(bank, { content: `${contact.name}: ${said}`, kind: "message", createdBy: "user", at, source: { ...source, title: contact.name } });
		if (answer.trim()) await provider.retain(bank, { content: `${this.def.name}: ${answer}`, kind: "message", createdBy: "agent", at, source: { ...source, title: this.def.name } });
	}

	private get usesMemory(): boolean {
		return this.def.tools.builtin.includes("memory");
	}

	private makeExtension(): Extension {
		const core = this;
		// Automatic runs act for the owner.
		const scope = async (conversationId: ConversationId, context: Context) => {
			const contact = (await core.contactOf(conversationId, context)) ?? ((await core.proactive.runOf(conversationId)) ? core.def.contacts.find((c) => c.role === "owner") : undefined);
			if (!contact) throw new Error("This conversation has no person.");
			return { contact, ...partitionsFor(contact) };
		};

		const remember = defineTool({
			name: "remember",
			description: "Save a fact worth keeping (a preference, a plan, a decision, something about a person). It goes to this person's memory unless you say otherwise; the owner can see and delete every fact.",
			parameters: Type.Object({
				fact: Type.String({ description: "One self-contained sentence" }),
				partition: Type.Optional(Type.String({ description: "owner, shared, or contacts/<id>. Default: this person's" })),
			}),
			execute: async (args, api, context) => {
				const s = await scope(api.conversationId, context);
				const partition = (args.partition ?? s.home) as Partition;
				if (!s.write.includes(partition) && !(s.contact.role === "owner" && partition.startsWith("contacts/"))) {
					return { output: [{ type: "text", text: `Can't write to ${partition} from ${s.contact.name}'s conversation.` }], isError: true };
				}
				const [record] = await core.options.memory().retain(bankOf(core.def.id, partition), { content: args.fact, kind: "fact", createdBy: "agent", source: { ref: `person:${s.contact.id}`, title: s.contact.name } });
				return { output: [{ type: "text", text: `Remembered (${partition}): ${args.fact}` }], details: { partition, ...(record ? { id: record.id } : {}) } as never };
			},
		});

		const recall = defineTool({
			name: "recall",
			description: "Search memory (facts and past messages) for something not already in your notes.",
			parameters: Type.Object({ query: Type.String() }),
			execute: async (args, api, context) => {
				const s = await scope(api.conversationId, context);
				const hits = await core.options.memory().recall(s.read.map((p) => bankOf(core.def.id, p)), args.query, { budgetTokens: 1500 });
				return { output: [{ type: "text", text: hits.length ? hits.map((h) => `- [${h.id}] ${h.text}`).join("\n") : "Nothing found." }] };
			},
		});

		const forget = defineTool({
			name: "forget",
			description: "Delete a fact from memory by its id (from recall), when it's wrong or the person asks.",
			parameters: Type.Object({ id: Type.String() }),
			execute: async (args, api, context) => {
				const s = await scope(api.conversationId, context);
				const provider = core.options.memory();
				if (!provider.forget) return { output: [{ type: "text", text: "This memory can't forget from here." }], isError: true };
				for (const p of s.write) {
					try {
						await provider.forget(bankOf(core.def.id, p), args.id, "agent");
						return { output: [{ type: "text", text: "Forgotten." }] };
					} catch {
						// not in this partition
					}
				}
				return { output: [{ type: "text", text: `No fact ${args.id} you can delete here.` }], isError: true };
			},
		});

		this.memoryTools = [remember, recall, forget];
		const p = this.proactive.tools;
		return defineExtension({
			name: "piopio-agent",
			tools: [remember, recall, forget, p.send, p.schedule, p.list, p.cancel],
			tasks: [this.proactive.scheduleTask, this.proactive.outboxTask],
			sections: [
				section("agent", async (input, context) => {
					const contact = await core.contactOf(input.conversationId, context);
					const owner = core.def.contacts.find((c) => c.role === "owner");
					const run = contact ? undefined : await core.proactive.runOf(input.conversationId);
					const who = run
						? `\n\n${core.proactive.runPrompt(run)}`
						: !contact
						? ""
						: contact.role === "owner"
							? `\n\nYou are talking with ${contact.name}, your owner.`
							: `\n\nYou are talking with ${contact.name}, one of ${owner?.name ?? "your owner"}'s contacts — not your owner. Don't share ${owner?.name ?? "the owner"}'s private information or other people's details with them.${contact.notes ? ` About ${contact.name}: ${contact.notes}` : ""}`;
					return `${core.options.instructions().trim()}${who}\n\nToday is ${(core.options.now?.() ?? new Date()).toISOString().slice(0, 10)}.`;
				}),
				section("agent-memory", async (input, context) => {
					if (!core.usesMemory) return undefined;
					const state = await input.read.snapshot(AgentStateDoc, context);
					const recalled = state?.recalled[String(input.conversationId)];
					return `From your memory (use remember to keep new facts, recall to search for more):\n${recalled || "(nothing relevant yet)"}`;
				}),
			],
		}) as unknown as Extension;
	}
}
