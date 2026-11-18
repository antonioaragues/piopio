/**
 * Home's agenda (docs/spec/21 D2, design 5e; docs/spec/27 AU10): one place for what happened while you were away and
 * today's timeline. It reads automations (their next times, their events and their runs) and projects' boards. Each
 * line names its automation, so the app can open it. Built from plain inputs so it can be tested without an engine;
 * `home.agenda` gathers them.
 */
import { dayOf } from "@piopio/runtime";

/** Who did it: an agent, Piopio in a project, or Piopio. */
export type Source = { kind: "agent" | "project" | "piopio"; id: string; name: string };

export type AgendaInput = {
	now: number;
	tz: string;
	/** Your last visit (epoch ms): "While you were away" starts there. */
	since?: number;
	automations: { id: string; name: string; source: Source; on: "time" | "folder" | "email" | "webhook"; label: string; next?: number; enabled: boolean }[];
	runs: { automation: string; firedAt: string; status: "running" | "done" | "quiet" | "waiting" | "skipped" | "failed"; summary?: string; costUsd?: number }[];
	/** Projects' boards (docs/spec/26): their tasks show under the project's name. */
	boards: { project: { id: string; name: string }; tasks: { id: string; title: string; state: string; attempts: number; updatedAt: string }[] }[];
	/** Messages held by quiet hours or limits, across agents. */
	held: number;
};

/** A row of today's timeline: a time (or none for an event automation), what, whose, and how it went. */
export type TodayItem = { at?: string; label: string; source: Source; automation?: string; state: "done" | "failed" | "skipped" | "running" | "upcoming" | "event"; tomorrow?: boolean };
/** A line of "While you were away": one per automation (or project board). Quiet runs (nothing new) are marked. */
export type AwayItem = { at: string; source: Source; automation?: string; text: string; costUsd?: number; quiet: boolean; failed?: boolean };

export type Agenda = { today: TodayItem[]; away: AwayItem[]; held: number };

const short = (text: string, n = 60) => {
	const one = text.trim().split("\n")[0]!.replace(/\s+/g, " ");
	return one.length > n ? `${one.slice(0, n - 1).trimEnd()}…` : one;
};

export function buildAgenda(input: AgendaInput): Agenda {
	const today = dayOf(input.now, input.tz);
	const isToday = (iso?: string) => !!iso && dayOf(Date.parse(iso), input.tz) === today;
	// What's next: the rest of today, and up to this time tomorrow (late at night, tomorrow morning is what matters).
	const soon = (t?: number) => t !== undefined && t > input.now && t <= input.now + 24 * 3_600_000;
	const since = input.since ?? input.now - 12 * 3_600_000;
	const after = (iso: string) => Date.parse(iso) > since;
	const items: TodayItem[] = [];
	const away: AwayItem[] = [];
	const byId = new Map(input.automations.map((a) => [a.id, a]));

	for (const r of input.runs) {
		const a = byId.get(r.automation);
		if (!a || !isToday(r.firedAt)) continue;
		const state = r.status === "quiet" ? "done" : r.status === "waiting" ? "running" : r.status;
		items.push({ at: r.firedAt, label: a.name, source: a.source, automation: a.id, state });
	}
	for (const a of input.automations) {
		if (!a.enabled) continue;
		if (a.on !== "time") items.push({ label: `${a.name} · ${a.label.replace(/^When /, "when ")}`, source: a.source, automation: a.id, state: "event" });
		else if (soon(a.next)) {
			const at = new Date(a.next!).toISOString();
			items.push({ at, label: a.name, source: a.source, automation: a.id, state: "upcoming", ...(isToday(at) ? {} : { tomorrow: true }) });
		}
		// One line per automation: its latest run since your last visit, and how many there were.
		const recent = input.runs.filter((r) => r.automation === a.id && after(r.firedAt) && r.status !== "running");
		const last = [...recent].sort((x, y) => y.firedAt.localeCompare(x.firedAt))[0];
		if (!last) continue;
		const quiet = last.status === "quiet";
		const failed = last.status === "failed";
		const cost = recent.reduce((n, r) => n + (r.costUsd ?? 0), 0);
		const what = failed ? `A run failed: ${short(last.summary ?? "no reason given")}` : quiet ? "had nothing new" : last.status === "waiting" ? "waits for your OK" : last.status === "skipped" ? `skipped: ${short(last.summary ?? "it needed your OK")}` : short(last.summary ?? "ran", 90);
		const text = `${a.name}: ${what}${recent.length > 1 ? ` (${recent.length} runs)` : ""}`;
		away.push({ at: last.firedAt, source: a.source, automation: a.id, text, ...(cost ? { costUsd: cost } : {}), quiet, ...(failed ? { failed: true } : {}) });
	}

	for (const t of input.boards) {
		const source: Source = { kind: "project", id: t.project.id, name: t.project.name };
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

	// Timed rows by time; event automations ("any time") last.
	items.sort((x, y) => (x.at && y.at ? x.at.localeCompare(y.at) : x.at ? -1 : y.at ? 1 : 0));
	away.sort((x, y) => y.at.localeCompare(x.at));
	return { today: items, away, held: input.held };
}
