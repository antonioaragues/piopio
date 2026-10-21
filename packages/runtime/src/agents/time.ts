/**
 * Time for proactivity (docs/spec/06-agents §6): cron's next fire in a time zone, intervals within active hours,
 * and quiet-hour windows ("22:30-07:30", which may cross midnight). Plain Intl, so it runs on Workers too.
 */

type Local = { year: number; month: number; day: number; weekday: number; hour: number; minute: number };

const formatters = new Map<string, Intl.DateTimeFormat>();
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** The wall-clock time of `t` in `tz`. */
export function local(t: number, tz: string): Local {
	let f = formatters.get(tz);
	if (!f) {
		f = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", weekday: "short", hour: "numeric", minute: "numeric" });
		formatters.set(tz, f);
	}
	const parts = Object.fromEntries(f.formatToParts(new Date(t)).map((p) => [p.type, p.value]));
	return { year: Number(parts.year), month: Number(parts.month), day: Number(parts.day), weekday: WEEKDAYS.indexOf(parts.weekday!), hour: Number(parts.hour) % 24, minute: Number(parts.minute) };
}

/** The day `t` falls on in `tz`, as "2026-10-21" (for daily limits). */
export function dayOf(t: number, tz: string): string {
	const l = local(t, tz);
	return `${l.year}-${String(l.month).padStart(2, "0")}-${String(l.day).padStart(2, "0")}`;
}

function field(text: string, min: number, max: number): Set<number> {
	const out = new Set<number>();
	for (const part of text.split(",")) {
		const m = /^(\*|(\d+)(?:-(\d+))?)(?:\/(\d+))?$/.exec(part);
		if (!m) throw new Error(`Bad cron field “${text}”`);
		const from = m[1] === "*" ? min : Number(m[2]);
		const to = m[1] === "*" ? max : m[3] !== undefined ? Number(m[3]) : m[4] !== undefined ? max : from;
		const step = m[4] !== undefined ? Number(m[4]) : 1;
		for (let v = from; v <= to; v += step) out.add(v);
	}
	return out;
}

/**
 * The first minute after `after` that matches `cron` in `tz` (epoch ms). Day of month and weekday combine with OR
 * when both are restricted, as in classic cron. Throws when nothing matches within two years.
 */
export function nextFire(cron: string, tz: string, after: number): number {
	const [m, h, dom, mon, dow] = cron.trim().split(/\s+/);
	const minutes = field(m!, 0, 59), hours = field(h!, 0, 23), days = field(dom!, 1, 31), months = field(mon!, 1, 12);
	const weekdays = new Set([...field(dow!, 0, 7)].map((d) => d % 7));
	const anyDay = dom === "*", anyWeekday = dow === "*";
	let t = Math.floor(after / 60_000) * 60_000 + 60_000;
	for (let i = 0; i < 200_000; i++) {
		const l = local(t, tz);
		const dayOk = anyDay && anyWeekday ? true : anyDay ? weekdays.has(l.weekday) : anyWeekday ? days.has(l.day) : days.has(l.day) || weekdays.has(l.weekday);
		if (!months.has(l.month) || !dayOk) {
			t += ((23 - l.hour) * 60 + (60 - l.minute)) * 60_000; // to the next local midnight
			continue;
		}
		if (!hours.has(l.hour)) {
			t += (60 - l.minute) * 60_000;
			continue;
		}
		if (!minutes.has(l.minute)) {
			t += 60_000;
			continue;
		}
		return t;
	}
	throw new Error(`“${cron}” doesn't fire in the next two years.`);
}

const parseWindow = (window: string) => {
	const [a, b] = window.split("-").map((s) => s.split(":").map(Number) as [number, number]);
	return { start: a![0] * 60 + a![1], end: b![0] * 60 + b![1] };
};

/** Whether `t` falls inside `window` ("22:30-07:30"; it may cross midnight) in `tz`. */
export function inWindow(window: string, t: number, tz: string): boolean {
	const { start, end } = parseWindow(window);
	const l = local(t, tz);
	const now = l.hour * 60 + l.minute;
	return start <= end ? now >= start && now < end : now >= start || now < end;
}

/** The next moment at or after `t` that is outside `window` (`t` itself when it already is). */
export function windowEnd(window: string, t: number, tz: string): number {
	let x = t;
	for (let i = 0; i < 24 * 60 + 1 && inWindow(window, x, tz); i++) x = Math.floor(x / 60_000) * 60_000 + 60_000;
	return x;
}

/** The next moment at or after `t` that is inside `window` (`t` itself when it already is). */
export function windowStart(window: string, t: number, tz: string): number {
	let x = t;
	for (let i = 0; i < 24 * 60 + 1 && !inWindow(window, x, tz); i++) x = Math.floor(x / 60_000) * 60_000 + 60_000;
	return x;
}

/** "4h", "30m" → milliseconds. */
export function interval(every: string): number {
	const m = /^(\d+)([mh])$/.exec(every);
	if (!m) throw new Error(`Bad interval “${every}”`);
	return Number(m[1]) * (m[2] === "h" ? 3_600_000 : 60_000);
}

/** The next heartbeat: `every` after `after`, moved into `activeHours` when it falls outside them. */
export function nextHeartbeat(every: string, activeHours: string | undefined, tz: string, after: number): number {
	const t = after + interval(every);
	return activeHours ? windowStart(activeHours, t, tz) : t;
}

/** The start of the next local day after `t` (when daily limits reset). */
export function nextDay(t: number, tz: string): number {
	const l = local(t, tz);
	return Math.floor(t / 60_000) * 60_000 + ((23 - l.hour) * 60 + (60 - l.minute)) * 60_000;
}
