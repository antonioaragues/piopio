/**
 * The model's clock (docs/research/deepseek-harness.md §1.4). A user message that starts something new (the first one,
 * one after a pause, or the first of a new day) carries a line saying when it was sent, in the user's time zone, and
 * how long it came after the previous message. It's worked out from the messages' own timestamps, so the same history
 * always reads the same way: nothing new to store, and earlier messages never change under the provider's prompt cache.
 */

/** A message as pi and pi-durable keep it; only `role`, `timestamp` and `content` are read. */
export type ClockMessage = { role: string; timestamp?: number; content?: unknown };

/** A pause longer than this gets a new line. */
export const CLOCK_PAUSE_MS = 15 * 60_000;
/** And at least this often in a long stretch of back-and-forth. */
export const CLOCK_REFRESH_MS = 60 * 60_000;

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(tz: string): Intl.DateTimeFormat {
	let f = formatters.get(tz);
	if (!f) {
		f = new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
		formatters.set(tz, f);
	}
	return f;
}

/** The machine's time zone, else UTC. */
export function localZone(): string {
	try {
		return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
	} catch {
		return "UTC";
	}
}

/** "Sun 8 Nov 2026, 14:05". */
export function formatClock(t: number, tz: string): string {
	const p = Object.fromEntries(formatter(tz).formatToParts(new Date(t)).map((x) => [x.type, x.value]));
	return `${p.weekday} ${p.day} ${p.month} ${p.year}, ${p.hour}:${p.minute}`;
}

/** The local calendar date of `t` in `tz`, "2026-11-08": what "today" means to the user. */
export function localDate(t: number, tz: string): string {
	const p = Object.fromEntries(formatter(tz).formatToParts(new Date(t)).map((x) => [x.type, x.value]));
	const month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].indexOf(p.month!) + 1;
	return `${p.year}-${String(month).padStart(2, "0")}-${String(p.day).padStart(2, "0")}`;
}

/** "3 days", "2 hours", "25 minutes"; undefined under a minute. */
export function formatGap(ms: number): string | undefined {
	const minutes = Math.floor(ms / 60_000);
	if (minutes < 1) return undefined;
	const unit = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;
	if (minutes < 60) return unit(minutes, "minute");
	const hours = Math.floor(minutes / 60);
	if (hours < 48) return unit(hours, "hour");
	const days = Math.floor(hours / 24);
	if (days < 60) return unit(days, "day");
	return unit(Math.floor(days / 30), "month");
}

/** "[Sent Sun 8 Nov 2026, 14:05 (Europe/Madrid), 3 days after the previous message]". */
export function clockLine(t: number, tz: string, previous?: number): string {
	const gap = previous !== undefined && t - previous >= CLOCK_PAUSE_MS ? formatGap(t - previous) : undefined;
	return `[Sent ${formatClock(t, tz)} (${tz})${gap ? `, ${gap} after the previous message` : ""}]`;
}

/**
 * The messages with a clock line at the start of each user message that needs one: the first, one after a pause of
 * `CLOCK_PAUSE_MS`, one on a new local day, and otherwise one every `CLOCK_REFRESH_MS`. Returns the same array when
 * nothing changes; messages are copied, never mutated.
 */
export function stampMessages<M extends ClockMessage>(messages: readonly M[], tz: string): M[] {
	let out: M[] | undefined;
	let previous: number | undefined;
	let lastStamp: number | undefined;
	messages.forEach((m, i) => {
		const t = m.timestamp;
		if (m.role === "user" && typeof t === "number" && Number.isFinite(t)) {
			const due = lastStamp === undefined || (previous !== undefined && t - previous >= CLOCK_PAUSE_MS) || t - lastStamp >= CLOCK_REFRESH_MS || localDate(t, tz) !== localDate(lastStamp, tz);
			if (due) {
				out ??= messages.slice();
				out[i] = { ...m, content: prepend(m.content, clockLine(t, tz, previous)) };
				lastStamp = t;
			}
		}
		if (typeof t === "number" && Number.isFinite(t)) previous = t;
	});
	return out ?? (messages as M[]);
}

function prepend(content: unknown, line: string): unknown {
	if (typeof content === "string") return `${line}\n\n${content}`;
	if (Array.isArray(content)) return [{ type: "text", text: line }, ...content];
	return content;
}
