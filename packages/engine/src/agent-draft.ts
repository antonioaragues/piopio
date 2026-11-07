/**
 * Turn into an agent (docs/spec/18 §8 phase 3, CF6): a draft for the Agent start page from a conversation: a short
 * name, instructions in the user's words, and a schedule when the conversation said when ("every morning",
 * "cada lunes a las 9"). The background model writes it when there is one; without it, the conversation's own words
 * and a small schedule reader do. Nothing is created: the user reviews the draft on the start page.
 */
import { cronError } from "@piopio/runtime";

export type AgentDraft = { name: string; instructions: string; schedule: string | null };
type Line = { role: "user" | "assistant"; text: string };

const MAX_TRANSCRIPT = 8_000;

const SYSTEM = `You turn a conversation into a personal agent that will run on its own: on a schedule, or when messaged.
Answer with JSON only: {"name": "...", "instructions": "...", "schedule": "<cron or null>"}.
- name: 1 to 3 words, what the agent is (e.g. "Morning briefing", "Kitchen planner"). In the user's language.
- instructions: what the agent should do each time it runs, in the second person ("Check…", "Tell me…"), with the standing details the conversation settled (people, places, preferences, sources, format). 3 to 8 short sentences. In the user's language. No greeting.
- schedule: a 5-field cron (minute hour day-of-month month day-of-week) when the user said when it should run ("every morning" is 0 8 * * *, "weekdays at 7:30" is 30 7 * * 1-5); null when they didn't.`;

/** The draft: the background model's, else one from the conversation's words. */
export async function draftAgent(title: string, lines: readonly Line[], complete?: (system: string, prompt: string) => Promise<string | undefined>): Promise<AgentDraft> {
	const transcript = lines.map((l) => `${l.role === "user" ? "User" : "Assistant"}: ${l.text}`).join("\n\n");
	const clipped = transcript.length > MAX_TRANSCRIPT ? transcript.slice(-MAX_TRANSCRIPT) : transcript;
	const userText = lines.filter((l) => l.role === "user").map((l) => l.text).join("\n");
	const fallback = plainDraft(title, lines);
	const reply = complete ? await complete(SYSTEM, `Conversation “${title}”:\n\n${clipped}`).catch(() => undefined) : undefined;
	const json = reply ? /\{[\s\S]*\}/.exec(reply)?.[0] : undefined;
	let parsed: Partial<{ name: unknown; instructions: unknown; schedule: unknown }> | undefined;
	try {
		parsed = json ? JSON.parse(json) : undefined;
	} catch {
		parsed = undefined;
	}
	const name = typeof parsed?.name === "string" && parsed.name.trim() ? parsed.name.trim().slice(0, 60) : fallback.name;
	const instructions = typeof parsed?.instructions === "string" && parsed.instructions.trim() ? parsed.instructions.trim() : fallback.instructions;
	const modelCron = typeof parsed?.schedule === "string" && !cronError(parsed.schedule.trim()) ? parsed.schedule.trim() : undefined;
	// The model's schedule when it gave a valid one; else what the user's own words say.
	const schedule = modelCron ?? scheduleFrom(userText);
	return { name, instructions, schedule };
}

/** Without a model: a name from the title, the user's messages as what it should do, a schedule from their words. */
function plainDraft(title: string, lines: readonly Line[]): AgentDraft {
	const asks = lines.filter((l) => l.role === "user").map((l) => l.text.trim()).filter(Boolean);
	return { name: plainName(title), instructions: asks.length ? `Do what was asked in the conversation “${title.trim()}”:\n\n${asks.map((a) => `- ${a}`).join("\n")}` : "", schedule: scheduleFrom(asks.join("\n")) };
}

/** A name from the title without the "when" ("Every weekday at 7:30, check the weather…" is "Check the weather in"). */
function plainName(title: string): string {
	let t = title.trim();
	const comma = t.indexOf(",");
	if (comma > 0 && comma < 40 && scheduleFrom(t.slice(0, comma))) t = t.slice(comma + 1).trim();
	const words = t.replace(/[.,;:!?…]+$/u, "").split(/\s+/).filter(Boolean).slice(0, 4).join(" ").slice(0, 40);
	return words ? words[0]!.toUpperCase() + words.slice(1) : "New agent";
}

const DAYS: [RegExp, string][] = [
	[/\b(sundays?|domingos?)\b/, "0"],
	[/\b(mondays?|lunes)\b/, "1"],
	[/\b(tuesdays?|martes)\b/, "2"],
	[/\b(wednesdays?|mi[eé]rcoles)\b/, "3"],
	[/\b(thursdays?|jueves)\b/, "4"],
	[/\b(fridays?|viernes)\b/, "5"],
	[/\b(saturdays?|s[aá]bados?)\b/, "6"],
];

/**
 * A cron from how people say when something should happen, in English and Spanish: "every morning", "weekdays at
 * 7:30", "cada lunes a las 9", "todas las noches", "every hour". Null when the words don't say.
 */
export function scheduleFrom(text: string): string | null {
	const t = ` ${text.toLowerCase()} `;
	if (/\b(every hour|hourly|cada hora)\b/.test(t)) return "0 * * * *";
	let days: string | undefined;
	if (/\b(weekdays?|every weekday|on weekdays|entre semana|de lunes a viernes|d[ií]as laborables)\b/.test(t)) days = "1-5";
	else if (/\b(weekends?|fines? de semana)\b/.test(t)) days = "0,6";
	else if (/\b(every day|daily|each day|cada d[ií]a|todos los d[ií]as|a diario|diariamente)\b/.test(t)) days = "*";
	else {
		const named = DAYS.filter(([re]) => re.test(t)).map(([, d]) => d);
		const recurring = /\b(every|each|on|cada|todos los|todas las|los)\b/.test(t);
		if (named.length && recurring) days = named.join(",");
		else if (/\b(every week|weekly|cada semana|semanalmente)\b/.test(t)) days = "1";
	}
	let hour: number | undefined;
	let minute = 0;
	const at = /\b(?:at|a las|a la)\s+(\d{1,2})(?::|\.|h)?(\d{2})?\s*(am|pm|a\.m\.|p\.m\.)?/.exec(t);
	if (at) {
		hour = Number(at[1]);
		minute = at[2] ? Number(at[2]) : 0;
		const half = at[3]?.replace(/\./g, "");
		if (half === "pm" && hour < 12) hour += 12;
		if (half === "am" && hour === 12) hour = 0;
	}
	const morning = /\b(every morning|each morning|mornings|cada mañana|todas las mañanas|por las mañanas)\b/.test(t);
	const evening = /\b(every evening|each evening|every night|evenings|cada noche|todas las noches|cada tarde|todas las tardes)\b/.test(t);
	if ((morning || evening) && !days) days = "*";
	if (!days) return null;
	if (hour === undefined) hour = evening ? 20 : morning ? 8 : 9;
	if (hour > 23 || minute > 59) return null;
	const cron = `${minute} ${hour} * * ${days}`;
	return cronError(cron) ? null : cron;
}
