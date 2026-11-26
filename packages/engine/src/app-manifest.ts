/**
 * An app's manifest (docs/spec/35 §3): what it is, the sources it lists and their rules, read from the `<script
 * id="piopio-app">` at the top of its page. Apps (apps.ts) serve it; make_app and the Library read it too.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

export const MANIFEST_ID = "piopio-app";
/** The most a source may hand the page (§3.2). */
export const MAX_SOURCE_BYTES = 2 * 1024 * 1024;
/** Larger than any reasonable app page (as visuals, 25). */
export const MAX_APP_BYTES = 300 * 1024;

/** The calendar spans a source can read, in this Mac's time zone (§16). */
export const CALENDAR_RANGES = ["today", "tomorrow", "this_week", "next_7_days", "this_month"] as const;
export type CalendarRange = (typeof CALENDAR_RANGES)[number];
export const RANGE_WORDS: Record<CalendarRange, string> = { today: "today", tomorrow: "tomorrow", this_week: "this week (Monday to Sunday)", next_7_days: "the next 7 days", this_month: "this month" };

export type FileSource = { file: string; columns?: string[] };
/** Events from these calendar accounts (Settings › Connectors), named one by one so a new account isn't read unasked. */
export type CalendarSource = { calendar: CalendarRange; accounts: string[] };
/** What Piopio's own numbers an app can read (docs/spec/35 §3.2, 34's `stats.*`). */
export const PIOPIO_READS = ["stats.spend", "stats.activity", "stats.budgets", "automations.runs", "agents"] as const;
export type PiopioRead = (typeof PIOPIO_READS)[number];
/** Piopio's own numbers, with fixed arguments (a range, a grouping). */
export type PiopioSource = { piopio: PiopioRead; args?: Record<string, unknown> };
export type AppSource = FileSource | CalendarSource | PiopioSource;
export type AppManifest = { title: string; sources: Record<string, AppSource> };
export const isFileSource = (s: AppSource): s is FileSource => "file" in s;
export const isCalendarSource = (s: AppSource): s is CalendarSource => "calendar" in s;
export const isPiopioSource = (s: AppSource): s is PiopioSource => "piopio" in s;
/** How Apps read Piopio's own numbers: the engine's `stats.*`, or a fake in tests. */
export type PiopioAccess = { read(what: PiopioRead, args: Record<string, unknown>): Promise<unknown> };

const SPEND_RANGES = ["today", "7d", "month", "last_month", "12m"];
const RANGE_NAMES: Record<string, string> = { today: "today", "7d": "the last 7 days", month: "this month", last_month: "last month", "12m": "the last 12 months" };
const GROUPINGS = ["what", "model", "provider", "project", "where"];

/** A piopio source's arguments, checked: what it may ask for, nothing else. Throws with what's wrong. */
function checkPiopio(name: string, what: unknown, raw: unknown): PiopioSource {
	if (!PIOPIO_READS.includes(what as PiopioRead)) throw new Error(`The source “${name}”: piopio is one of ${PIOPIO_READS.join(", ")}.`);
	const args = (raw ?? {}) as Record<string, unknown>;
	if (typeof args !== "object" || Array.isArray(args)) throw new Error(`The source “${name}”: args is an object.`);
	const out: Record<string, unknown> = {};
	const bad = (key: string, allowed: string) => new Error(`The source “${name}”: ${key} is ${allowed}.`);
	for (const [key, value] of Object.entries(args)) {
		if (key === "range" && (what === "stats.spend" || what === "stats.activity")) {
			if (!SPEND_RANGES.includes(value as string)) throw bad("range", `one of ${SPEND_RANGES.join(", ")}`);
		} else if (key === "groupBy" && what === "stats.spend") {
			if (!GROUPINGS.includes(value as string)) throw bad("groupBy", `one of ${GROUPINGS.join(", ")}`);
		} else if (key === "filter" && what === "stats.spend") {
			const f = (value ?? {}) as Record<string, unknown>;
			if (typeof f !== "object" || Object.entries(f).some(([k, v]) => !["agent", "automation", "place"].includes(k) || typeof v !== "string")) throw bad("filter", "{ agent?, automation?, place? } as text");
		} else if (key === "limit" && what === "automations.runs") {
			if (typeof value !== "number" || value < 1 || value > 100) throw bad("limit", "a number from 1 to 100");
		} else if (key === "automation" && what === "automations.runs") {
			if (typeof value !== "string") throw bad("automation", "an automation's id");
		} else throw new Error(`The source “${name}”: ${what} takes no “${key}”.`);
		out[key] = value;
	}
	if ((what === "stats.spend" || what === "stats.activity") && out.range === undefined) out.range = "month";
	return { piopio: what as PiopioRead, ...(Object.keys(out).length ? { args: out } : {}) };
}

/** A piopio source in words (the card, the sources menu, the app's conversation). */
export function piopioWords(s: PiopioSource): string {
	const range = RANGE_NAMES[(s.args?.range as string) ?? "month"] ?? "this month";
	switch (s.piopio) {
		case "stats.spend": return `what Piopio spent ${range}${s.args?.groupBy ? `, by ${s.args.groupBy}` : ""}`;
		case "stats.activity": return `what Piopio did ${range}`;
		case "stats.budgets": return "Piopio's budgets";
		case "automations.runs": return "your automations' latest runs";
		case "agents": return "your agents and their status";
	}
}

/** What the page gets from each piopio source, for the model (make_app, the app's conversation). */
export const PIOPIO_SHAPES: Record<PiopioRead, string> = {
	"stats.spend": '{ knownUsd, calls, unknownCalls (requests with no price: never $0), planCalls, planTokens, forecastUsd?, days: [{ day: "2026-11-23" (or "2026-11" on 12m), macUsd, cloudUsd, calls, unknownCalls, top: [{ label, usd }] }], groupBy, groups: [{ id, label, usd, calls, unknownCalls, plan (tokens, not dollars), tokens, share 0…1 }], since? }',
	"stats.activity": "{ groups: [{ id, title, rows: [{ id, label, value, previous? (the range before), unit?: count|files, detail? }] }], year: [{ day, count }] }",
	"stats.budgets": "{ budgets: [{ id, kind: agent|automation, name, spentUsd, limitUsd, period: month|run, resets? }], piopio: { month, limitUsd?, spentUsd, resets, state: off|ok|near|over|allowed, held: [{ run, automation, name, at }] } }",
	"automations.runs": "a list, newest first, of { id, automation, name, firedAt, status: running|done|quiet|waiting|skipped|failed, summary?, costUsd? }",
	agents: "a list of { id, name, runsOn: mac|cloud, model, paused, spendUsd (this month), budgetUsd?, nextRun?, inbox (waiting for you) }",
};


// ── The manifest ────────────────────────────────────────────────────────────────

const MANIFEST_RE = new RegExp(`<script[^>]*\\bid\\s*=\\s*["']${MANIFEST_ID}["'][^>]*>([\\s\\S]*?)</script>\\s*`, "i");
const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]{0,39}$/;

/** True when an `.html` file's start has an app manifest (the Library's kind). */
export function isAppFile(path: string): boolean {
	if (!/\.html?$/i.test(path)) return false;
	try {
		const head = readFileSync(path, "utf8").slice(0, 16_384);
		return MANIFEST_RE.test(head);
	} catch {
		return false;
	}
}

/** The page's manifest, checked; throws with what's wrong. */
export function parseManifest(html: string): AppManifest {
	const m = MANIFEST_RE.exec(html);
	if (!m) throw new Error("This page has no app manifest.");
	let raw: unknown;
	try {
		raw = JSON.parse(m[1]!);
	} catch {
		throw new Error("The app's manifest isn't valid JSON.");
	}
	return checkManifest(raw);
}

export function checkManifest(raw: unknown): AppManifest {
	const o = (raw ?? {}) as { title?: unknown; sources?: unknown };
	const title = typeof o.title === "string" && o.title.trim() ? o.title.trim() : "App";
	if (!o.sources || typeof o.sources !== "object" || Array.isArray(o.sources)) throw new Error("The manifest has no sources.");
	const sources: Record<string, AppSource> = {};
	for (const [name, value] of Object.entries(o.sources as Record<string, unknown>)) {
		if (!NAME_RE.test(name)) throw new Error(`“${name}” can't name a source: letters, digits and _ only.`);
		const v = (value ?? {}) as { file?: unknown; columns?: unknown; tool?: unknown; script?: unknown; piopio?: unknown; calendar?: unknown; accounts?: unknown };
		if (v.calendar !== undefined) {
			if (!CALENDAR_RANGES.includes(v.calendar as CalendarRange)) throw new Error(`The source “${name}”: calendar is one of ${CALENDAR_RANGES.join(", ")}.`);
			const accounts = Array.isArray(v.accounts) ? [...new Set(v.accounts.filter((a): a is string => typeof a === "string" && a.trim() !== "").map((a) => a.trim()))] : [];
			if (!accounts.length) throw new Error(`The source “${name}” needs the calendar accounts it reads.`);
			sources[name] = { calendar: v.calendar as CalendarRange, accounts };
			continue;
		}
		if (v.piopio !== undefined) {
			sources[name] = checkPiopio(name, v.piopio, (v as { args?: unknown }).args);
			continue;
		}
		if (v.tool || v.script) throw new Error(`The source “${name}” isn't a file, a calendar or Piopio's numbers. Apps read those for now: write what it needs to a CSV or JSON file, and read that.`);
		if (typeof v.file !== "string" || !v.file.trim()) throw new Error(`The source “${name}” needs a file.`);
		const columns = Array.isArray(v.columns) ? v.columns.filter((c): c is string => typeof c === "string" && c.trim() !== "").map((c) => c.trim()) : undefined;
		sources[name] = { file: v.file.trim(), ...(columns?.length ? { columns } : {}) };
	}
	if (!Object.keys(sources).length) throw new Error("The manifest has no sources.");
	return { title, sources };
}

/** What allowing covers: the sources, not the page (§3.4). */
export function sourcesHash(m: AppManifest): string {
	return createHash("sha256").update(sortedSources(m)).digest("hex");
}

function sortedSources(m: AppManifest): string {
	const sorted = Object.keys(m.sources)
		.sort()
		.map((k) => {
			const s = m.sources[k]!;
			// Files hash as they did in L2, so apps allowed then stay allowed.
			if (isFileSource(s)) return [k, s.file, s.columns ?? []];
			if (isPiopioSource(s)) return [k, { piopio: s.piopio, args: s.args ?? {} }];
			return [k, { calendar: s.calendar, accounts: [...s.accounts].sort() }];
		});
	return JSON.stringify(sorted);
}

/** The page with this manifest at the top (replacing any it had), and a stand-in `piopio` for other browsers. */
export function withManifest(html: string, manifest: AppManifest): string {
	const body = html.replace(MANIFEST_RE, "");
	const json = JSON.stringify(manifest, null, "\t").replace(/</g, "\\u003c");
	const top = `<script type="application/json" id="${MANIFEST_ID}">\n${json}\n</script>\n${STANDIN}\n`;
	const head = /<head[^>]*>/i.exec(body);
	if (head) return body.slice(0, head.index + head[0].length) + "\n" + top + body.slice(head.index + head[0].length);
	return top + body.replace(/^\s+/, "");
}

/** Outside Piopio there's no `piopio`: the page says where to open it instead of failing. Piopio's own comes first. */
const STANDIN = `<script>window.piopio ??= { send() {}, prefill() {}, onData() { addEventListener("DOMContentLoaded", () => document.body.insertAdjacentHTML("afterbegin", '<p style="font:13px system-ui;color:#888">Open in Piopio to see live data.</p>')); } };</script>`;

/** The span a calendar source reads, from local midnight (this Mac's time zone); weeks start on Monday. */
export function calendarSpan(range: CalendarRange, now = new Date()): { from: string; to: string } {
	const day = new Date(now.getFullYear(), now.getMonth(), now.getDate());
	const plus = (d: Date, days: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + days);
	switch (range) {
		case "today":
			return { from: day.toISOString(), to: plus(day, 1).toISOString() };
		case "tomorrow":
			return { from: plus(day, 1).toISOString(), to: plus(day, 2).toISOString() };
		case "this_week": {
			const monday = plus(day, -((day.getDay() + 6) % 7));
			return { from: monday.toISOString(), to: plus(monday, 7).toISOString() };
		}
		case "next_7_days":
			return { from: now.toISOString(), to: new Date(now.getTime() + 7 * 86_400_000).toISOString() };
		case "this_month":
			return { from: new Date(now.getFullYear(), now.getMonth(), 1).toISOString(), to: new Date(now.getFullYear(), now.getMonth() + 1, 1).toISOString() };
	}
}
