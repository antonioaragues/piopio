/**
 * Telegram's Bot API client and text formatting, shared by both engines: the Mac reads a bot by long polling
 * (`getUpdates`, docs/spec/19 S4; engine/src/channels/manager.ts), the cloud by webhook (`setWebhook`, docs/spec/13
 * §5.3; cloud/src/telegram.ts). Only `fetch`, so it runs in Node and in workerd.
 */

export type TelegramUser = { id: number; first_name?: string; last_name?: string; username?: string };
export type TelegramMessage = { message_id: number; chat: { id: number; type: string }; from?: TelegramUser; text?: string; caption?: string };
export type TelegramUpdate = { update_id: number; message?: TelegramMessage };

/** What a bot token looks like: "123456789:AA…" (the id, a colon, 35 or so characters). */
export const BOT_TOKEN = /\b(\d{6,12}:[A-Za-z0-9_-]{30,})\b/;

export class TelegramError extends Error {
	constructor(
		message: string,
		readonly status?: number,
	) {
		super(message);
	}
}

export class TelegramBot {
	constructor(
		private readonly token: string,
		// Called through a wrapper: workerd refuses `fetch` invoked as another object's method ("Illegal invocation").
		private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
		private readonly base = "https://api.telegram.org",
	) {}

	/**
	 * One request, given up on after `timeoutMs`: without a deadline, a connection that died half-open (across a sleep, a
	 * network change) left the long poll waiting forever, and the bot silent.
	 */
	private async call<T>(method: string, body: Record<string, unknown> | FormData, signal?: AbortSignal, timeoutMs = 30_000): Promise<T> {
		const form = body instanceof FormData;
		const deadline = new AbortController();
		const timer = setTimeout(() => deadline.abort(new TelegramError(`Telegram didn't answer ${method} in ${Math.round(timeoutMs / 1000)} s`, 0)), timeoutMs);
		const stop = () => deadline.abort(signal?.reason);
		signal?.addEventListener("abort", stop, { once: true });
		try {
			const response = await this.fetcher(`${this.base}/bot${this.token}/${method}`, {
				method: "POST",
				...(form ? {} : { headers: { "content-type": "application/json" } }),
				body: form ? body : JSON.stringify(body),
				signal: deadline.signal,
			});
			const json = (await response.json().catch(() => ({}))) as { ok?: boolean; result?: T; description?: string };
			if (!json.ok) throw new TelegramError(json.description ?? `Telegram answered ${response.status}`, response.status);
			return json.result as T;
		} catch (error) {
			if (deadline.signal.aborted && !signal?.aborted && deadline.signal.reason instanceof TelegramError) throw deadline.signal.reason;
			throw error;
		} finally {
			clearTimeout(timer);
			signal?.removeEventListener("abort", stop);
		}
	}

	getMe(): Promise<TelegramUser> {
		return this.call("getMe", {});
	}

	/**
	 * Telegram POSTs each update to `url`, with `secret` in the `X-Telegram-Bot-Api-Secret-Token` header. While a
	 * webhook is set, `getUpdates` doesn't work: a bot is read one way or the other.
	 */
	setWebhook(url: string, secret: string): Promise<boolean> {
		return this.call("setWebhook", { url, secret_token: secret, allowed_updates: ["message"], drop_pending_updates: true });
	}

	deleteWebhook(): Promise<boolean> {
		return this.call("deleteWebhook", { drop_pending_updates: false });
	}

	/** Waits up to `timeout` seconds for messages after `offset` (long polling). */
	getUpdates(offset: number, timeout: number, signal?: AbortSignal): Promise<TelegramUpdate[]> {
		// Telegram holds the request up to `timeout` seconds: the deadline is that, and some.
		return this.call("getUpdates", { offset, timeout, allowed_updates: ["message"] }, signal, (timeout + 15) * 1000);
	}

	/** Sends Markdown as Telegram's HTML, split to fit; falls back to plain text if Telegram can't parse it. */
	async send(chatId: number | string, markdown: string): Promise<void> {
		for (const part of splitMessage(markdown)) {
			try {
				await this.call("sendMessage", { chat_id: chatId, text: toTelegramHtml(part), parse_mode: "HTML", link_preview_options: { is_disabled: true } });
			} catch (error) {
				if (!(error instanceof TelegramError) || error.status !== 400) throw error;
				await this.call("sendMessage", { chat_id: chatId, text: part });
			}
		}
	}

	/** A picture (a visual, docs/spec/25 §8), uploaded, with a caption. */
	async sendPhoto(chatId: number | string, jpeg: Uint8Array, caption?: string): Promise<void> {
		const form = new FormData();
		form.append("chat_id", String(chatId));
		form.append("photo", new Blob([new Uint8Array(jpeg)], { type: "image/jpeg" }), "visual.jpg");
		if (caption) form.append("caption", caption.slice(0, 1000));
		await this.call("sendPhoto", form);
	}

	/** "typing…" for about five seconds. */
	typing(chatId: number | string): Promise<void> {
		return this.call<unknown>("sendChatAction", { chat_id: chatId, action: "typing" }).then(() => undefined);
	}
}

const escape = (s: string) => s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/**
 * The Markdown models write, as the small HTML Telegram reads: code blocks, inline code, bold, italics, links and
 * headings (as bold). Anything else stays as text.
 */
export function toTelegramHtml(markdown: string): string {
	const blocks: string[] = [];
	// Code blocks first, so nothing inside them is touched.
	let text = markdown.replace(/```[a-zA-Z0-9_+-]*\n?([\s\S]*?)```/g, (_m, code: string) => {
		blocks.push(`<pre>${escape(code.replace(/\n$/, ""))}</pre>`);
		return `\u0000${blocks.length - 1}\u0000`;
	});
	const inline: string[] = [];
	text = text.replace(/`([^`\n]+)`/g, (_m, code: string) => {
		inline.push(`<code>${escape(code)}</code>`);
		return `\u0001${inline.length - 1}\u0001`;
	});
	text = escape(text)
		.replace(/^#{1,6}\s+(.+)$/gm, "<b>$1</b>")
		.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
		.replace(/(^|[^*\w])\*(?!\s)([^*\n]+?)\*(?!\w)/g, "$1<i>$2</i>")
		.replace(/(^|[^\w])_(?!\s)([^_\n]+?)_(?!\w)/g, "$1<i>$2</i>")
		.replace(/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g, (_m, label: string, url: string) => `<a href="${url.replaceAll('"', "&quot;")}">${label}</a>`);
	return text.replace(/\u0001(\d+)\u0001/g, (_m, i: string) => inline[Number(i)]!).replace(/\u0000(\d+)\u0000/g, (_m, i: string) => blocks[Number(i)]!);
}

/** Telegram's limit is 4,096 characters; split at a paragraph, then a line, then anywhere. */
export function splitMessage(text: string, max = 3800): string[] {
	const out: string[] = [];
	let rest = text.trim();
	while (rest.length > max) {
		let cut = rest.lastIndexOf("\n\n", max);
		if (cut < max / 2) cut = rest.lastIndexOf("\n", max);
		if (cut < max / 2) cut = max;
		out.push(rest.slice(0, cut).trimEnd());
		rest = rest.slice(cut).trimStart();
	}
	if (rest) out.push(rest);
	return out;
}
