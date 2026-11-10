/**
 * Team routines (docs/spec/19 T1): when something should start the team's work without you asking. A time (a cron, or
 * once), a file in a folder, an email, or a webhook call. Each fire is a `[Routine]` message to the lead, which plans
 * it like any request. They're set by the lead when you ask it ("every Monday, a brief on…") or from the team page.
 */
import { nextFire, parseLocal } from "@piopio/runtime";

export type TeamRoutine = {
	id: string;
	on: "time" | "folder" | "email" | "webhook";
	prompt: string;
	/** time: a 5-field cron, or `at` once (epoch ms). */
	cron?: string;
	at?: number;
	tz?: string;
	/** folder: an absolute path, or one starting with ~/. */
	folder?: string;
	/** email: part of the sender, and words in the subject. */
	from?: string;
	subject?: string;
	by: "lead" | "you";
	createdAt: string;
	/** time: the next fire (epoch ms), kept so a fire missed while the Mac slept runs once on wake. */
	next?: number;
	lastRun?: string;
	runs: number;
};

export const systemZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** "Every Monday at 09:00", "Every weekday at 08:30", "When a file appears in ~/Inbox"… */
export function routineLabel(r: Pick<TeamRoutine, "on" | "cron" | "at" | "tz" | "folder" | "from" | "subject">): string {
	if (r.on === "folder") return `When a file appears or changes in ${r.folder}`;
	if (r.on === "email") return `When an email${r.from ? ` from ${r.from}` : ""}${r.subject ? ` about “${r.subject}”` : ""} arrives`;
	if (r.on === "webhook") return "When its URL is called";
	if (r.at !== undefined) {
		const f = new Intl.DateTimeFormat("en-GB", { timeZone: r.tz ?? systemZone(), weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
		return `Once, ${f.format(new Date(r.at))}`;
	}
	const [m, h, dom, mon, dow] = (r.cron ?? "").trim().split(/\s+/);
	const at = /^\d+$/.test(m ?? "") && /^\d+$/.test(h ?? "") ? `${h!.padStart(2, "0")}:${m!.padStart(2, "0")}` : undefined;
	if (at && dom === "*" && mon === "*") {
		if (dow === "*") return `Every day at ${at}`;
		if (dow === "1-5") return `Every weekday at ${at}`;
		if (/^[0-7]$/.test(dow ?? "")) return `Every ${DAYS[Number(dow) % 7]} at ${at}`;
	}
	if (at && /^\d+$/.test(dom ?? "") && mon === "*" && dow === "*") return `Every month on day ${dom} at ${at}`;
	return `On the schedule “${r.cron}”`;
}

/** A cron, or a local date-time; undefined with the reason when it's neither (or has passed). */
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

/** The next fire after `after`, or undefined for a once that's done. */
export function nextOf(r: TeamRoutine, after: number): number | undefined {
	if (r.on !== "time") return undefined;
	if (r.cron) return nextFire(r.cron, r.tz ?? systemZone(), after);
	return r.at !== undefined && r.at > after ? r.at : undefined;
}
