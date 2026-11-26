/**
 * A conversation run by a coding agent (docs/spec/31), whichever runs it: Claude Code through its SDK (claude-code.ts),
 * or an ACP agent, Codex or Antigravity (acp.ts). What they have in common is here, once: Piopio's copy of the
 * transcript, the timeline and the composer tray's prompts, the user's message going in, follow-ups waiting for the
 * turn, the turn's end, Stop, changing the model, thinking or approval mode, and matching a run of Piopio's tools to
 * the agent's tool call. What differs (starting the agent, handing it the message, reading what it sends back,
 * applying a setting) is each runtime's, through the abstract members below.
 */
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { ApprovalMode, Attachment, AttachmentInfo, ContainerRef, ModelRef, PromptResponse, SessionEvent, Snapshot } from "@piopio/protocol";
import { TimelineBuilder, type PiMessage, type ToolImageKeeper } from "@piopio/runtime";
import { readJsonFile, writeFileAtomic } from "../atomic.js";
import { EngineError } from "../models.js";
import { PromptBroker } from "./prompts.js";
import { agentIdleMs, Emitter, IdleTimer, type Runtime, type SubmitOptions } from "./runtime.js";

/** Piopio's copy of the conversation: pi-shaped messages, as `TimelineBuilder` reads them, and the agent's session id. */
export type Stored = { version: 1; sessionId?: string; messages: PiMessage[] };
/** A message from the user, with its attachments and where Piopio keeps each. */
export type Input = { text: string; attachments: (Attachment & { stored?: string })[] };

/** What every coding agent's conversation opens with. */
export type CodingAgentOptions = {
	ref: ContainerRef;
	model: ModelRef;
	thinking?: string;
	/** Piopio's copy of the transcript (JSON). */
	file: string;
	/** The conversation's approval mode, read when a session starts and when it changes (CA4). */
	approvalMode: () => ApprovalMode;
	/** A chat (no project): runs in its own folder, in Auto-edit, with no approval mode to show. */
	chat?: boolean;
	keepImages?: ToolImageKeeper;
	/** How long the agent's process may sit idle before it's ended (AGENT_IDLE_MS). */
	idleMs?: number;
};

export abstract class CodingAgentRuntime implements Runtime {
	readonly ref: ContainerRef;
	protected readonly builder: TimelineBuilder;
	protected readonly emitter = new Emitter();
	protected readonly broker = new PromptBroker();
	protected stored: Stored;
	protected model: ModelRef;
	protected thinking?: string;
	protected busy = false;
	/** Stopped by the user: the turn's end isn't an error. */
	protected stopping = false;
	protected followUps: Input[] = [];
	/** Calls to Piopio's tools the agent made and Piopio hasn't run yet: their ids key the transcript's cards. */
	protected piopioCalls: { id: string; name: string; input: string }[] = [];
	/** Aborted by Stop: Piopio's tools running for this turn end with it. */
	protected turnAbort = new AbortController();
	/** Ends the agent's process when the conversation has been idle a while (`endIdle`). */
	protected readonly idle: IdleTimer;

	/** Who runs it, in what the user reads ("Claude Code", "Codex"). */
	protected abstract get agentName(): string;
	/** The provider its models are listed under: another provider's model can't take this conversation over. */
	protected abstract get provider(): string;
	/** Hands the user's message (already in the transcript) to the agent. The turn ends in `finishTurn` or `fail`. */
	protected abstract send(input: Input): Promise<void>;
	/** Closes the answer being streamed, if any, before the turn ends. */
	protected abstract endAssistant(): void;
	/** Arms the idle timer when the agent's process may end on its own (it can pick the conversation up again). */
	protected abstract armIdle(): void;
	/** The conversation has been idle long enough, with nothing running or waiting on you: end the agent's process. */
	protected abstract endIdle(): void;
	/** Stop: tells the agent to stop its turn. */
	protected abstract interrupt(): Promise<void>;
	/** Applies a setting the user changed to the agent's session, if it has one now. */
	protected abstract setAgentModel(id: string): Promise<void>;
	protected abstract setAgentThinking(): Promise<void>;
	protected abstract setAgentMode(mode: ApprovalMode): Promise<void>;
	/** Ends the agent's process and anything this runtime started for it. */
	protected abstract closeAgent(): Promise<void>;

	protected constructor(private readonly common: CodingAgentOptions) {
		this.ref = common.ref;
		this.model = common.model;
		if (common.thinking) this.thinking = common.thinking;
		this.builder = new TimelineBuilder(common.ref);
		if (common.keepImages) this.builder.keepImages = common.keepImages;
		this.stored = CodingAgentRuntime.load(common.file);
		this.builder.reset(this.stored.messages, (i) => `m${i}`, false);
		this.builder.setState({ status: "idle", model: this.model, prompts: [], ...(this.thinking ? { thinking: this.thinking } : {}), ...(common.chat ? {} : { approvalMode: common.approvalMode() }) });
		this.idle = new IdleTimer(common.idleMs ?? agentIdleMs(), () => {
			if (this.busy || this.broker.list().length) return this.idle.arm();
			this.endIdle();
		});
		this.builder.flush();
		this.broker.onChange = (prompts, changed, added) => {
			if (changed.callId) this.builder.toolStatus(changed.callId, added ? "pending_approval" : "running");
			this.builder.setState({ prompts, status: prompts.length ? "waiting_approval" : this.busy ? "running" : "idle" });
			this.emit();
		};
	}

	private static load(file: string): Stored {
		const s = readJsonFile<Partial<Stored>>(file, () => ({}));
		return { version: 1, ...(s.sessionId ? { sessionId: s.sessionId } : {}), messages: Array.isArray(s.messages) ? s.messages : [] };
	}

	protected save(): void {
		mkdirSync(dirname(this.common.file), { recursive: true });
		writeFileAtomic(this.common.file, JSON.stringify(this.stored), { mode: 0o600 });
	}

	snapshot(): Snapshot {
		return this.builder.snapshot();
	}

	onEvents(listener: (events: SessionEvent[]) => void): () => void {
		return this.emitter.on(listener);
	}

	protected emit(): void {
		this.emitter.emit(this.builder.flush());
	}

	respond(promptId: string, response: PromptResponse): void {
		this.broker.respond(promptId, response);
	}

	/** A message while the agent works waits for the turn to end (steering too: A1), unless it should be refused. */
	async submit(text: string, options: SubmitOptions): Promise<{ disposition: "started" | "queued" }> {
		const input: Input = { text, attachments: options.attachments ?? [] };
		if (this.busy) {
			if (options.whenBusy === "reject") throw new EngineError("BUSY", `${this.agentName} is still working.`);
			this.followUps.push(input);
			this.showQueue();
			this.emit();
			return { disposition: "queued" };
		}
		await this.start(input);
		return { disposition: "started" };
	}

	/** The user's message into the transcript, then to the agent. */
	private async start(input: Input): Promise<void> {
		this.idle.disarm();
		this.busy = true;
		const index = this.stored.messages.length;
		const attachments: AttachmentInfo[] = input.attachments.map((a) => ({ name: a.name, kind: a.kind, ...(a.mimeType ? { mimeType: a.mimeType } : {}), ...(a.stored ? { stored: a.stored } : {}) }));
		const now = Date.now();
		this.stored.messages.push({ role: "user", content: input.text, timestamp: now, ...(attachments.length ? { attachments } : {}) } as PiMessage);
		this.save();
		this.builder.user(`m${index}`, input.text, now, attachments);
		this.builder.setState({ status: "running" });
		this.emit();
		try {
			await this.send(input);
		} catch (error) {
			this.fail((error as Error).message);
		}
	}

	private showQueue(): void {
		this.builder.setState({ queue: this.followUps.map((f, i) => ({ id: `q${i}`, mode: "followUp" as const, text: f.text })) });
	}

	/** The turn ended (however it went: say so first): the next message that waited goes, or the agent may rest. */
	protected finishTurn(): void {
		this.busy = false;
		this.stopping = false;
		this.piopioCalls = [];
		this.builder.setState({ status: this.broker.list().length ? "waiting_approval" : "idle" });
		this.emit();
		const next = this.followUps.shift();
		if (next) {
			this.showQueue();
			void this.start(next);
		} else this.armIdle();
	}

	/** The turn couldn't go on: why, as an error line; the messages that waited are dropped with it. */
	protected fail(message: string): void {
		this.endAssistant();
		this.builder.system(`e${Date.now()}`, "error", `${this.agentName}: ${message}`);
		this.busy = false;
		this.stopping = false;
		this.followUps = [];
		this.builder.setState({ status: "idle", queue: [] });
		this.emit();
		this.armIdle();
	}

	/** The agent's tool call for this run of one of Piopio's tools (same name and arguments, else same name). */
	protected callIdFor(name: string, args: Record<string, unknown>): string {
		const json = JSON.stringify(args);
		const i = this.piopioCalls.findIndex((c) => c.name === name && c.input === json);
		const at = i >= 0 ? i : this.piopioCalls.findIndex((c) => c.name === name);
		if (at < 0) return `piopio-${Date.now()}`;
		return this.piopioCalls.splice(at, 1)[0]!.id;
	}

	async abort(): Promise<void> {
		this.turnAbort.abort();
		this.turnAbort = new AbortController();
		if (this.busy) this.stopping = true;
		this.followUps = [];
		this.broker.cancelAll();
		this.builder.setState({ queue: [] });
		this.emit();
		await this.interrupt();
	}

	async configure(change: { model?: ModelRef; thinking?: string; approvalMode?: ApprovalMode }): Promise<void> {
		if (change.model) {
			if (change.model.provider !== this.provider) throw new EngineError("INVALID", `This conversation runs in ${this.agentName}. Start a new conversation to use another model.`);
			this.model = change.model;
			await this.setAgentModel(change.model.id);
			this.builder.setState({ model: this.model });
		}
		if (change.thinking) {
			if (change.thinking === "default") delete this.thinking;
			else this.thinking = change.thinking;
			await this.setAgentThinking();
			this.builder.setState(this.thinking ? { thinking: this.thinking } : {});
		}
		if (change.approvalMode && !this.common.chat) {
			await this.setAgentMode(change.approvalMode);
			this.builder.setState({ approvalMode: change.approvalMode });
		}
		this.emit();
	}

	async close(): Promise<void> {
		this.idle.disarm();
		this.broker.cancelAll();
		await this.closeAgent();
	}
}
