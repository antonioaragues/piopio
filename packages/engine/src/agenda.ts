/**
 * Home's agenda (docs/spec/21 D2, design 5e): one place for what waits on you, what happened while you were away and
 * today's timeline, across agents (their runs, schedules and event routines), projects (their routines) and teams (their
 * tasks). Built from plain inputs so it can be tested without an engine; `home.agenda` gathers them.
 */
import { dayOf } from "@piopio/runtime";
import { routineLabel, type TeamRoutine } from "./teams/routines.js";

export type Source = { kind: "agent" | "project" | "team"; id: string; name: string };

export type AgendaInput = {
	now: number;
	tz: string;
	/** Your last visit (epoch ms): "While you were away" starts there. */
	since?: number;
	agents: {
		id: string;
		name: string;
		runs: { id: string; kind: string; source: string; prompt: string; firedAt: string; status: "running" | "done" | "failed" | "skipped"; summary?: string; sent: number; costUsd?: number }[];
		upcoming: { id: string; kind: string; label: string; next?: string }[];
		held: number;
	}[];
	projects: { id: string; name: string; routines: TeamRoutine[] }[];
	teams: { id: string; name: string; project?: { id: string; name: string }; tasks: { id: string; title: string; state: string; attempts: number; updatedAt: string }[] }[];
};

/** A row of today's timeline: a time (or "any" for an event routine), what, whose, and how it went. */
export type TodayItem = { at?: string; label: string; source: Source; state: "done" | "failed" | "skipped" | "running" | "upcoming" | "event"; tomorrow?: boolean };
/** A line of "While you were away": one per agent or team. Quiet runs (nothing new) are marked. */
export type AwayItem = { at: string; source: Source; text: string; costUsd?: number; quiet: boolean; failed?: boolean };

export type Agenda = { today: TodayItem[]; away: AwayItem[]; held: number };

const short = (text: string, n = 60) => {
	const one = text.trim().split("\n")[0]!.replace(/\s+/g, " ");
	return one.length > n ? `${one.slice(0, n - 1).trimEnd()}…` : one;
};

export function buildAgenda(input: AgendaInput): Agenda {
	const today = dayOf(input.now, input.tz);
	const isToday = (iso?: string) => !!iso && dayOf(Date.parse(iso), input.tz) === today;
	// What's next: the rest of today, and up to this time tomorrow (late at night, tomorrow morning is what matters).
	const soon = (iso?: string) => !!iso && Date.parse(iso) > input.now && Date.parse(iso) <= input.now + 24 * 3_600_000;
	const upcoming = (iso: string, label: string, source: Source): TodayItem => ({ at: iso, label, source, state: "upcoming", ...(isToday(iso) ? {} : { tomorrow: true }) });
	const since = input.since ?? input.now - 12 * 3_600_000;
	const after = (iso: string) => Date.parse(iso) > since;
	const items: TodayItem[] = [];
	const away: AwayItem[] = [];

	for (const a of input.agents) {
		const source: Source = { kind: "agent", id: a.id, name: a.name };
		for (const r of a.runs) {
			if (r.kind === "manual") continue;
			// A run of one of its own schedules reads as the agent; a reminder or trigger by what it was for.
			if (isToday(r.firedAt)) items.push({ at: r.firedAt, label: r.kind === "schedule" ? "" : short(r.prompt), source, state: r.status === "running" ? "running" : r.status });
		}
		for (const u of a.upcoming) {
			if (u.kind === "watch") items.push({ label: short(u.label), source, state: "event" });
			else if (u.next && soon(u.next)) items.push(upcoming(u.next, short(u.label), source));
		}
		// One line per agent: its latest run since your last visit, and how many there were.
		const recent = a.runs.filter((r) => r.kind !== "manual" && after(r.firedAt) && r.status !== "running");
		const last = recent.sort((x, y) => y.firedAt.localeCompare(x.firedAt))[0];
		if (last) {
			const quiet = last.status !== "failed" && last.sent === 0;
			const cost = recent.reduce((n, r) => n + (r.costUsd ?? 0), 0);
			const text = last.status === "failed" ? `A run failed: ${short(last.summary ?? last.prompt)}` : quiet ? "had nothing new" : short(last.summary ?? `sent you ${last.sent === 1 ? "a message" : `${last.sent} messages`}`, 90);
			away.push({ at: last.firedAt, source, text: recent.length > 1 ? `${text} (${recent.length} runs)` : text, ...(cost ? { costUsd: cost } : {}), quiet, ...(last.status === "failed" ? { failed: true } : {}) });
		}
	}

	for (const p of input.projects) {
		const source: Source = { kind: "project", id: p.id, name: p.name };
		for (const r of p.routines) {
			const label = short(r.prompt);
			if (r.on !== "time") {
				items.push({ label: `${label} · ${routineLabel(r).replace(/^When /, "when ")}`, source, state: "event" });
				continue;
			}
			if (r.lastRun && isToday(r.lastRun)) items.push({ at: r.lastRun, label, source, state: "done" });
			if (r.next && soon(new Date(r.next).toISOString())) items.push(upcoming(new Date(r.next).toISOString(), label, source));
			if (r.lastRun && after(r.lastRun)) away.push({ at: r.lastRun, source, text: `ran “${label}”`, quiet: false });
		}
	}

	for (const t of input.teams) {
		const source: Source = { kind: "team", id: t.id, name: t.project ? `${t.project.name} team` : t.name };
		const doing = t.tasks.filter((x) => ["doing", "review", "integrating"].includes(x.state));
		if (doing.length) items.push({ at: new Date(input.now).toISOString(), label: doing.length === 1 ? short(doing[0]!.title).toLowerCase() : `${doing.length} tasks`, source, state: "running" });
		const changed = t.tasks.filter((x) => after(x.updatedAt));
		const done = changed.filter((x) => x.state === "done").length;
		const blocked = changed.filter((x) => x.state === "blocked").length;
		const sentBack = changed.filter((x) => x.attempts > 0).length;
		if (done || blocked) {
			const parts = [done ? `finished ${done === 1 ? "a task" : `${done} tasks`}` : "", blocked ? `${blocked === 1 ? "a task is" : `${blocked} tasks are`} blocked` : "", sentBack ? `the reviewer sent ${sentBack === 1 ? "one" : sentBack} back` : ""].filter(Boolean);
			const at = changed.map((x) => x.updatedAt).sort().pop()!;
			away.push({ at, source, text: parts.join("; "), quiet: false, ...(blocked ? { failed: true } : {}) });
		}
	}

	// Timed rows by time; event routines ("any time") last.
	items.sort((x, y) => (x.at && y.at ? x.at.localeCompare(y.at) : x.at ? -1 : y.at ? 1 : 0));
	away.sort((x, y) => y.at.localeCompare(x.at));
	return { today: items, away, held: input.agents.reduce((n, a) => n + a.held, 0) };
}
