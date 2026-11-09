/**
 * Agents on Telegram from the Mac (docs/spec/19 S4, CH-T0; 06-agents §5.2). For every local agent whose definition has
 * `channels.telegram`, the engine polls its bot while it runs. A message from a known person (a contact's
 * `channels.telegram` is their chat id) goes to that person's conversation; the answer goes back to Telegram. What the
 * agent sends on its own goes to Telegram when that's the person's preferred channel, and a pending approval is
 * announced there.
 *
 * Connecting: the owner pastes the bot token in the agent's chat. The engine catches it before the model or the
 * transcript sees it, checks it (`getMe`), keeps it in the Keychain, and answers with a link that pairs the owner's
 * Telegram account (`t.me/<bot>?start=<code>`, valid for an hour).
 */
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentDefinition } from "@piopio/runtime";
import { TelegramBot, type TelegramMessage, type TelegramUpdate } from "./telegram.js";

export type ChannelHost = {
	/** Local agents and their definitions. */
	agents(): { id: string; name: string; definition: AgentDefinition }[];
	definition(agentId: string): AgentDefinition | undefined;
	/** Saves a changed definition (validated, committed, the agent reconfigured). */
	save(agentId: string, change: (def: AgentDefinition) => void, message: string): Promise<void>;
	/** Starts a turn in a person's conversation. */
	submit(agentId: string, contactId: string, text: string): Promise<void>;
	/** A note in the owner's conversation (not a message from the agent, not seen by the model). */
	notice(agentId: string, text: string): Promise<void>;
	secrets: { get(name: string, purpose: string): Promise<string | null>; set(name: string, value: string): Promise<void> };
	stateDir: string;
	log(line: string): void;
	fetch?: typeof fetch;
	/** Tests: shorter waits. */
	pollSeconds?: number;
	retryMs?: number;
};

type State = { offset?: number; pairing?: { code: string; until: number }; username?: string };
type Live = { bot: TelegramBot; token: string; abort: AbortController; username?: string };

const PAIRING_MS = 3600_000;

export class TelegramChannels {
	private readonly live = new Map<string, Live>();
	/** Messages that came from Telegram, by agent and person, waiting for their answer. */
	private readonly waiting = new Map<string, { chatId: number; text: string }[]>();
	private stopped = false;

	constructor(private readonly host: ChannelHost) {
		mkdirSync(host.stateDir, { recursive: true });
	}

	static secretName(agentId: string): string {
		return `TELEGRAM_${agentId.replace(/[^A-Za-z0-9]/g, "_").toUpperCase()}`;
	}

	/** Starts polling for agents that have a bot and stops it for those that no longer do. */
	async sync(): Promise<void> {
		if (this.stopped) return;
		const wanted = new Set<string>();
		for (const agent of this.host.agents()) {
			const ref = agent.definition.channels?.telegram?.bot;
			if (!ref) continue;
			wanted.add(agent.id);
			const token = await this.host.secrets.get(ref.slice("secret:".length), `Telegram for ${agent.name}`).catch(() => null);
			const current = this.live.get(agent.id);
			if (current && current.token === token) continue;
			current?.abort.abort();
			this.live.delete(agent.id);
			if (!token) {
				this.host.log(`Telegram for ${agent.name}: no bot token in the Keychain yet.`);
				continue;
			}
			const live: Live = { bot: new TelegramBot(token, this.host.fetch), token, abort: new AbortController() };
			this.live.set(agent.id, live);
			void this.poll(agent.id, live);
		}
		for (const [id, live] of this.live) if (!wanted.has(id)) (live.abort.abort(), this.live.delete(id));
	}

	stop(): void {
		this.stopped = true;
		for (const live of this.live.values()) live.abort.abort();
		this.live.clear();
	}

	/** The owner pasted a bot token in the chat: check it, keep it, add the channel, and give the pairing link. */
	async connect(agentId: string, token: string): Promise<string> {
		const bot = new TelegramBot(token, this.host.fetch);
		let me;
		try {
			me = await bot.getMe();
		} catch (error) {
			return `That doesn't look like a working Telegram bot token (${(error as Error).message}). Make a bot with @BotFather and paste the token it gives you.`;
		}
		const name = TelegramChannels.secretName(agentId);
		await this.host.secrets.set(name, token);
		const code = randomBytes(6).toString("hex");
		this.writeState(agentId, { ...this.readState(agentId), pairing: { code, until: Date.now() + PAIRING_MS }, ...(me.username ? { username: me.username } : {}) });
		await this.host.save(agentId, (def) => void (def.channels = { ...def.channels, telegram: { bot: `secret:${name}` } }), "Connect Telegram");
		await this.sync();
		const link = me.username ? `https://t.me/${me.username}?start=${code}` : undefined;
		return link
			? `Connected to @${me.username}. Open ${link} on your phone and tap Start: from then on I'll answer you there too. The link works for an hour.`
			: `Connected. Send /start ${code} to the bot on Telegram within an hour.`;
	}

	/** A turn in a person's conversation ended: if the message came from Telegram, the answer goes back there. */
	answered(agentId: string, contactId: string, said: string, answer: string): void {
		const key = `${agentId}/${contactId}`;
		const list = this.waiting.get(key) ?? [];
		const i = list.findIndex((w) => w.text === said);
		if (i < 0) return;
		const [origin] = list.splice(i, 1);
		const live = this.live.get(agentId);
		if (!live || !answer.trim()) return;
		void live.bot.send(origin!.chatId, answer).catch((error: unknown) => this.host.log(`Telegram: couldn't answer: ${(error as Error).message}`));
	}

	/** The agent sent a message on its own (send_message, a run): to Telegram when that's the person's channel. */
	outbound(agentId: string, to: string, text: string): void {
		const chatId = this.chatOf(agentId, to);
		const live = this.live.get(agentId);
		if (!chatId || !live) return;
		void live.bot.send(chatId, text).catch((error: unknown) => this.host.log(`Telegram: couldn't send: ${(error as Error).message}`));
	}

	/** An approval is waiting: say so on Telegram (approving from Telegram's buttons comes with the cloud, 13 §5.3). */
	approval(agentId: string, title: string): void {
		const def = this.host.definition(agentId);
		const owner = def?.contacts.find((c) => c.role === "owner");
		if (owner) this.outbound(agentId, owner.id, `I need your OK before I go on: ${title}. Open Piopio to answer.`);
	}

	private chatOf(agentId: string, contactId: string): string | undefined {
		const contact = this.host.definition(agentId)?.contacts.find((c) => c.id === contactId);
		return contact?.channels?.telegram && contact.preferred === "telegram" ? contact.channels.telegram : undefined;
	}

	private async poll(agentId: string, live: Live): Promise<void> {
		const wait = this.host.pollSeconds ?? 25;
		while (!live.abort.signal.aborted) {
			try {
				const offset = this.readState(agentId).offset ?? 0;
				const updates = await live.bot.getUpdates(offset, wait, live.abort.signal);
				for (const update of updates) {
					// Saved before handling, so a crash in the middle can't repeat a message.
					this.writeState(agentId, { ...this.readState(agentId), offset: update.update_id + 1 });
					await this.handle(agentId, live, update).catch((error: unknown) => this.host.log(`Telegram: ${(error as Error).message}`));
				}
			} catch (error) {
				if (live.abort.signal.aborted) return;
				this.host.log(`Telegram for ${this.host.definition(agentId)?.name ?? agentId}: ${(error as Error).message}`);
				await new Promise((r) => setTimeout(r, this.host.retryMs ?? 15_000));
			}
		}
	}

	private async handle(agentId: string, live: Live, update: TelegramUpdate): Promise<void> {
		const message = update.message;
		if (!message || message.chat.type !== "private") return;
		const def = this.host.definition(agentId);
		if (!def) return;
		const chatId = String(message.chat.id);
		const text = (message.text ?? message.caption ?? "").trim();
		const contact = def.contacts.find((c) => c.channels?.telegram === chatId);
		if (!contact) return this.unknown(agentId, def, live, message, text);
		if (!message.text) {
			await live.bot.send(message.chat.id, "I can only read text here for now.");
			return;
		}
		if (text === "/start") return; // already paired
		const key = `${agentId}/${contact.id}`;
		this.waiting.set(key, [...(this.waiting.get(key) ?? []), { chatId: message.chat.id, text }]);
		void live.bot.typing(message.chat.id).catch(() => undefined);
		await this.host.submit(agentId, contact.id, text);
	}

	/** Someone the agent doesn't know: the owner pairing with the link, or a stranger (06 `unknownSenders`). */
	private async unknown(agentId: string, def: AgentDefinition, live: Live, message: TelegramMessage, text: string): Promise<void> {
		const state = this.readState(agentId);
		const code = /^\/start\s+(\S+)/.exec(text)?.[1];
		if (code && state.pairing && code === state.pairing.code && Date.now() < state.pairing.until) {
			const chatId = String(message.chat.id);
			await this.host.save(
				agentId,
				(d) => {
					const owner = d.contacts.find((c) => c.role === "owner");
					if (owner) {
						owner.channels = { ...owner.channels, telegram: chatId };
						owner.preferred = "telegram";
					}
				},
				"Pair the owner's Telegram",
			);
			const { pairing: _p, ...rest } = state;
			this.writeState(agentId, rest);
			const owner = def.contacts.find((c) => c.role === "owner");
			await live.bot.send(message.chat.id, `Hi${owner ? ` ${owner.name}` : ""}! I'm ${def.name}. Write to me here whenever you like; I'll also send you what I do on my own.`);
			await this.host.notice(agentId, "Telegram is paired: you can write to me there, and what I send on my own goes there.");
			return;
		}
		const mode = def.policies?.unknownSenders ?? "ignore";
		if (mode === "reply_canned" || text.startsWith("/start")) {
			await live.bot.send(message.chat.id, `I'm ${def.name}, a personal agent. I only talk with the people my owner adds.`);
		}
		if (mode === "ask_owner") {
			const who = [message.from?.first_name, message.from?.last_name].filter(Boolean).join(" ") || message.from?.username || "Someone";
			await this.host.notice(agentId, `${who} wrote to me on Telegram (chat ${message.chat.id}): “${text.slice(0, 200)}”. Add them as a contact with that chat id if I should talk with them.`);
		}
	}

	private file(agentId: string): string {
		return join(this.host.stateDir, `${agentId}.json`);
	}

	private readState(agentId: string): State {
		try {
			return existsSync(this.file(agentId)) ? (JSON.parse(readFileSync(this.file(agentId), "utf8")) as State) : {};
		} catch {
			return {};
		}
	}

	private writeState(agentId: string, state: State): void {
		writeFileSync(this.file(agentId), JSON.stringify(state), { mode: 0o600 });
	}
}
