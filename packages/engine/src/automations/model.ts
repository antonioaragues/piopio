/**
 * Automations (docs/spec/27): work that starts when nobody started it. One object holds the trigger (a time, an
 * email, a file in a folder, a URL), who runs it (Piopio or one of your agents), the prompt, a project when Piopio
 * works in one, where the result goes, what it may do while you're away, and its runs. These are the plain types and
 * the words for them; `service.ts` keeps, fires and watches them.
 */
import { nextFire, parseLocal } from "@piopio/runtime";

export type Trigger = "time" | "folder" | "email" | "webhook";
/** Where a run's result goes (AU7). An agent: its chat with you, Telegram, or only if it needs you. Piopio: a conversation, or only if it needs you. */
export type ResultTo = "chat" | "telegram" | "conversation" | "quiet";
export type RunStatus = "running" | "done" | "quiet" | "waiting" | "skipped" | "failed";

export type Automation = {
	id: string;
	name: string;
	on: Trigger;
	/** time: a 5-field cron, or `at` once (epoch ms), in `tz`. */
	cron?: string;
	at?: number;
	tz?: string;
	/** folder: an absolute path, or one starting with ~/. */
	folder?: string;
	/** email: part of the sender, and words in the subject. */
	from?: string;
	subject?: string;
	/** "piopio", or an agent's id. */
	runsAs: string;
	/** A project's id: only when Piopio runs it (AU6). */
	project?: string;
	prompt: string;
	result: ResultTo;
	/** An agent's contact the result is for (default its owner). */
	deliverTo?: string;
	/** While you're away (AU8): wait in Waiting on you, or skip the run, when it needs your approval. */
	approval: "wait" | "skip";
	budgetPerRunUsd?: number;
	enabled: boolean;
	/** "you", "piopio", or the agent that made it. */
	by: string;
	createdAt: string;
	/** time: the next fire (epoch ms), kept so a fire missed while the Mac slept runs once on wake. */
	next?: number;
	lastRun?: string;
	runCount: number;
	/** You haven't opened it since it was made (the list's "New" badge). */
	fresh?: boolean;
	/** Webhook addresses it had before (an agent's trigger, a project's routine): "<id>/<trigger>", still served. */
	aliases?: string[];
};

export type AutomationRun = {
	id: string;
	automation: string;
	firedAt: string;
	/** What started it: its time, its event, or Run now. */
	cause: "time" | "event" | "now";
	status: RunStatus;
	summary?: string;
	costUsd?: number;
	/** Piopio's conversation (a session id), or the agent's run conversation (`run:<id>` in that agent). */
	conversation?: string;
	/** An agent's run: which agent, and its run's id. */
	agent?: string;
	agentRun?: string;
};

export const PIOPIO = "piopio";
/** The default budget per run (27 §5): an agent's, and Piopio's in a project. */
export const DEFAULT_BUDGET = { agent: 0.25, piopio: 0.5 };

export const systemZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** "Every Monday at 09:00", "Every weekday at 08:30", "When a file appears in ~/Inbox"… */
export function whenLabel(a: Pick<Automation, "on" | "cron" | "at" | "tz" | "folder" | "from" | "subject">): string {
	if (a.on === "folder") return `When a file appears or changes in ${a.folder}`;
	if (a.on === "email") return `When an email${a.from ? ` from ${a.from}` : ""}${a.subject ? ` about “${a.subject}”` : ""} arrives`;
	if (a.on === "webhook") return "When its URL is called";
	if (a.at !== undefined) {
		const f = new Intl.DateTimeFormat("en-GB", { timeZone: a.tz ?? systemZone(), weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
		return `Once, ${f.format(new Date(a.at))}`;
	}
	const [m, h, dom, mon, dow] = (a.cron ?? "").trim().split(/\s+/);
	const at = /^\d+$/.test(m ?? "") && /^\d+$/.test(h ?? "") ? `${h!.padStart(2, "0")}:${m!.padStart(2, "0")}` : undefined;
	if (at && dom === "*" && mon === "*") {
		if (dow === "*") return `Every day at ${at}`;
		if (dow === "1-5") return `Every weekday at ${at}`;
		if (dow === "0,6" || dow === "6,0") return `Every weekend day at ${at}`;
		if (/^[0-7]$/.test(dow ?? "")) return `Every ${DAYS[Number(dow) % 7]} at ${at}`;
	}
	if (at && /^\d+$/.test(dom ?? "") && mon === "*" && dow === "*") return `Every month on day ${dom} at ${at}`;
	const every = /^\*\/(\d+)$/.exec(m ?? "");
	if (every && dom === "*" && mon === "*" && dow === "*") {
		const hours = /^(\d+)-(\d+)$/.exec(h ?? "");
		const span = h === "*" ? "" : hours ? ` between ${hours[1]!.padStart(2, "0")}:00 and ${String(Number(hours[2]) + 1).padStart(2, "0")}:00` : "";
		if (h === "*" || hours) return `Every ${every[1]} minutes${span}`;
	}
	return `On the schedule “${a.cron}”`;
}

/** A cron, or a local date-time; the reason when it's neither (or has passed). */
export function parseWhen(when: string, tz: string, now: number): { cron: string } | { at: number } | { error: string } {
	const text = when.trim();
	if (text.split(/\s+/).length === 5) {
		try {
			nextFire(text, tz, now);
			return { cron: text };
		} catch (error) {
			return { error: (error as Error).message };
		}
	}
	const at = parseLocal(text, tz);
	if (at === undefined) return { error: "Give a 5-field cron (0 9 * * 1) or a date and time (2026-11-16T09:00)." };
	if (at <= now) return { error: "That moment has passed." };
	return { at };
}

/** The next fire after `after`, or undefined for a once that's done (or an event). */
export function nextOf(a: Pick<Automation, "on" | "cron" | "at" | "tz">, after: number): number | undefined {
	if (a.on !== "time") return undefined;
	if (a.cron) return nextFire(a.cron, a.tz ?? systemZone(), after);
	return a.at !== undefined && a.at > after ? a.at : undefined;
}

/** A name from a prompt when none was given: its first words. */
export function nameOf(prompt: string): string {
	let line = prompt.trim().split("\n")[0]!.replace(/\s+/g, " ");
	// A webhook's {{body}} isn't words: the name is what comes before it ("A new order came in from the shop form").
	const cut = line.indexOf("{{");
	if (cut > 0) line = line.slice(0, cut);
	line = line.replace(/\{\{\w+\}\}/g, "").trim().replace(/[.!?:;,\s]+$/, "");
	const short = line.length > 48 ? `${line.slice(0, 47).trimEnd()}…` : line;
	return short ? short[0]!.toUpperCase() + short.slice(1) : "Automation";
}

/** "Every Monday at 09:00, ask Rita to …, and tell me on Telegram." The sentence the app shows (27 §3). */
export function resultLabel(result: ResultTo, runner: { piopio: boolean; name: string }, project?: string): string {
	if (result === "quiet") return "Only if it needs you";
	if (result === "telegram") return "Telegram";
	if (runner.piopio) return project ? `A conversation in ${project}` : "A new conversation";
	return `${runner.name}’s chat`;
}
