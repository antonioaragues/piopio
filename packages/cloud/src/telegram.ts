/**
 * An agent on Telegram from the cloud (docs/spec/13 §5.3): its bot is read by webhook, so it answers with the Mac off.
 * The same steps as the Mac's long polling (engine/src/channels/manager.ts):
 *
 * - **Connect:** the owner pastes the @BotFather token in their conversation with the agent. It's caught before the
 *   model or the transcript sees it, checked (`getMe`) and kept in the object's storage. The webhook is set to this
 *   Worker with a random secret, and the owner gets a pairing link (`t.me/<bot>?start=<code>`, an hour).
 * - **Messages:** Telegram's POST carries the secret in a header, checked before anything else. Each update is handled
 *   once (by its id). A known person (a contact's `channels.telegram` is their chat id) writes in their own
 *   conversation, and the answer goes back to their chat; the answers still owed survive an eviction.
 * - **On its own:** what the agent sends (a reminder, a run) goes to Telegram when that's the person's channel.
 */
import { BOT_TOKEN, TelegramBot, type AgentDefinition, type TelegramMessage, type TelegramUpdate } from "@piopio/runtime";
import { sameSecret } from "./auth.js";

/** The secret header Telegram sends with every update (`setWebhook`'s `secret_token`). */
export const SECRET_HEADER = "X-Telegram-Bot-Api-Secret-Token";

/** An answer owed to a chat: the turn's operation, so it's sent even after an eviction. */
export type Owed = { operationId: string; session: string; chatId: number };
type State = { token: string; secret: string; username?: string; pairing?: { code: string; until: number }; seen: number[]; owed: Owed[] };

export type TelegramHost = {
	agentId: string;
	storage: DurableObjectStorage;
	definition(): AgentDefinition;
	/** Saves a changed definition and reconfigures the agent's conversations. */
	save(change: (def: AgentDefinition) => void): Promise<void>;
	/** The Worker's public origin (https://piopio-cloud.<subdomain>.workers.dev), once a client has connected. */
	origin(): Promise<string | undefined>;
	/** A person's message, as from the socket; the operation when a turn started. */
	say(contactId: string, text: string): Promise<{ operationId: string; session: string } | undefined>;
	/** Waits for an operation's answer (its text, if any). */
	answer(owed: Owed): Promise<string | undefined>;
	/** A note in the owner's conversation (not from the agent, not seen by the model). */
	notice(text: string): Promise<void>;
	/** Keeps the object alive for work that outlives the request. */
	waitUntil(work: Promise<unknown>): void;
	/** Telegram's API base (tests point it at a fake). */
	api?: string;
};

const KEY = "piopio:telegram";
const PAIRING_MS = 3600_000;

const randomHex = (bytes: number) => [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");

export class CloudTelegram {
	constructor(private readonly host: TelegramHost) {}

	private state(): Promise<State | undefined> {
		return this.host.storage.get<State>(KEY);
	}

	private async update(change: (s: State) => void): Promise<void> {
		const s = await this.state();
		if (!s) return;
		change(s);
		await this.host.storage.put(KEY, s);
	}

	private bot(token: string): TelegramBot {
		return new TelegramBot(token, undefined, this.host.api ?? "https://api.telegram.org");
	}

	/** The owner's message, if it's a bot token: connects instead of reaching the model. The note to show, or undefined. */
	async intercept(contactId: string, text: string): Promise<string | undefined> {
		const token = BOT_TOKEN.exec(text)?.[1];
		if (!token || this.host.definition().contacts.find((c) => c.id === contactId)?.role !== "owner") return undefined;
		return this.connect(token);
	}

	async connect(token: string): Promise<string> {
		const bot = this.bot(token);
		let me;
		try {
			me = await bot.getMe();
		} catch (error) {
			return `That doesn't look like a working Telegram bot token (${(error as Error).message}). Make a bot with @BotFather and paste the token it gives you.`;
		}
		const origin = await this.host.origin();
		if (!origin) return "I don't know this Worker's address yet. Connect to it once, then paste the token again.";
		const secret = randomHex(32);
		try {
			await bot.setWebhook(`${origin}/v1/channels/telegram/${this.host.agentId}`, secret);
		} catch (error) {
			return `Telegram didn't take the webhook (${(error as Error).message}).`;
		}
		const code = randomHex(6);
		const before = await this.state();
		await this.host.storage.put(KEY, { token, secret, ...(me.username ? { username: me.username } : {}), pairing: { code, until: Date.now() + PAIRING_MS }, seen: before?.seen ?? [], owed: [] } satisfies State);
		await this.host.save((def) => void (def.channels = { ...def.channels, telegram: { bot: "secret:TELEGRAM_BOT" } }));
		const link = me.username ? `https://t.me/${me.username}?start=${code}` : undefined;
		return link
			? `Connected to @${me.username}, from the cloud. Open ${link} on your phone and tap Start: from then on I'll answer you there, even with your Mac off. The link works for an hour.`
			: `Connected, from the cloud. Send /start ${code} to the bot on Telegram within an hour.`;
	}

	/** Telegram's POST. Checked by its secret header, answered at once; the turn goes on after. */
	async webhook(request: Request): Promise<Response> {
		const state = await this.state();
		const given = request.headers.get(SECRET_HEADER);
		if (!state || !given || !(await sameSecret(given, state.secret))) return new Response("Unauthorized", { status: 401 });
		let update: TelegramUpdate;
		try {
			update = (await request.json()) as TelegramUpdate;
		} catch {
			return new Response("Bad update", { status: 400 });
		}
		// Telegram retries what it doesn't get a 200 for: each update is handled once.
		if (state.seen.includes(update.update_id)) return new Response("ok");
		await this.update((s) => void (s.seen = [...s.seen, update.update_id].slice(-200)));
		this.host.waitUntil(this.handle(state, update).catch((error: unknown) => console.error(`Telegram: ${(error as Error).message}`)));
		return new Response("ok");
	}

	private async handle(state: State, update: TelegramUpdate): Promise<void> {
		const message = update.message;
		if (!message || message.chat.type !== "private") return;
		const bot = this.bot(state.token);
		const def = this.host.definition();
		const chatId = String(message.chat.id);
		const text = (message.text ?? message.caption ?? "").trim();
		const contact = def.contacts.find((c) => c.channels?.telegram === chatId);
		if (!contact) return this.unknown(state, bot, message, text);
		if (!message.text) return void (await bot.send(message.chat.id, "I can only read text here for now."));
		if (text === "/start") return;
		void bot.typing(message.chat.id).catch(() => undefined);
		const turn = await this.host.say(contact.id, text);
		if (!turn) return;
		const owed: Owed = { ...turn, chatId: message.chat.id };
		await this.update((s) => void (s.owed = [...s.owed, owed]));
		await this.deliver(owed);
	}

	/** Sends an owed answer once its turn is done, then forgets it. */
	private async deliver(owed: Owed): Promise<void> {
		const text = await this.host.answer(owed);
		const state = await this.state();
		if (state && text?.trim()) await this.bot(state.token).send(owed.chatId, text);
		await this.update((s) => void (s.owed = s.owed.filter((o) => o.operationId !== owed.operationId)));
	}

	/** After a wake: the answers still owed (their turns finished from the alarm) go out now. */
	resume(): void {
		this.host.waitUntil(
			(async () => {
				for (const owed of (await this.state())?.owed ?? []) await this.deliver(owed).catch((error: unknown) => console.error(`Telegram: ${(error as Error).message}`));
			})(),
		);
	}

	/** The agent sent a message on its own: to Telegram when that's the person's channel. */
	outbound(to: string, text: string): void {
		const contact = this.host.definition().contacts.find((c) => c.id === to);
		if (!contact?.channels?.telegram || contact.preferred !== "telegram") return;
		this.host.waitUntil(
			(async () => {
				const state = await this.state();
				if (state) await this.bot(state.token).send(contact.channels!.telegram!, text);
			})().catch((error: unknown) => console.error(`Telegram: couldn't send: ${(error as Error).message}`)),
		);
	}

	/** Someone the agent doesn't know: the owner pairing with the link, or a stranger (06 `unknownSenders`). */
	private async unknown(state: State, bot: TelegramBot, message: TelegramMessage, text: string): Promise<void> {
		const def = this.host.definition();
		const code = /^\/start\s+(\S+)/.exec(text)?.[1];
		if (code && state.pairing && code === state.pairing.code && Date.now() < state.pairing.until) {
			const chatId = String(message.chat.id);
			await this.host.save((d) => {
				const owner = d.contacts.find((c) => c.role === "owner");
				if (owner) {
					owner.channels = { ...owner.channels, telegram: chatId };
					owner.preferred = "telegram";
				}
			});
			await this.update((s) => void delete s.pairing);
			const owner = def.contacts.find((c) => c.role === "owner");
			const name = owner && owner.name !== "owner" ? ` ${owner.name}` : "";
			await bot.send(message.chat.id, `Hi${name}! I'm ${def.name}, running in the cloud. Write to me here whenever you like; I'll also send you what I do on my own.`);
			await this.host.notice("Telegram is paired: you can write to me there, and what I send on my own goes there.");
			return;
		}
		const mode = def.policies?.unknownSenders ?? "ignore";
		if (mode === "reply_canned" || text.startsWith("/start")) await bot.send(message.chat.id, `I'm ${def.name}, a personal agent. I only talk with the people my owner adds.`);
		if (mode === "ask_owner") {
			const who = [message.from?.first_name, message.from?.last_name].filter(Boolean).join(" ") || message.from?.username || "Someone";
			await this.host.notice(`${who} wrote to me on Telegram (chat ${message.chat.id}): “${text.slice(0, 200)}”. Add them as a contact with that chat id if I should talk with them.`);
		}
	}
}
