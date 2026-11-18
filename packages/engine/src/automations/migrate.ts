/**
 * What became automations (docs/spec/27 §6). Each agent's definition schedules, heartbeat and webhook triggers, and
 * the reminders and watches it set itself, become automations run by that agent; each project's routines become
 * automations run by Piopio there. Webhook addresses they had are kept as aliases, so callers don't break; watches
 * and routines keep their ids, so the mail watcher's place in each mailbox carries over. Pure functions: the engine
 * reads the old records, adopts what these return, and clears the old ones.
 */
import type { AgentDefinition, Reminder, RunRecord, Watch } from "@piopio/runtime";
import { nameOf, nextOf, PIOPIO, systemZone, whenLabel, type Automation, type AutomationRun } from "./model.js";

/** A project routine as it was kept (docs/spec/21 AD5, 26 CL10). */
export type LegacyRoutine = {
	id: string;
	on: "time" | "folder" | "email" | "webhook";
	prompt: string;
	cron?: string;
	at?: number;
	tz?: string;
	folder?: string;
	from?: string;
	subject?: string;
	by: string;
	createdAt: string;
	next?: number;
	lastRun?: string;
	runs: number;
	lastConversation?: string;
};
export type LegacyPlace = { project: string; path: string; routines: LegacyRoutine[]; fired?: string[] };

export type Migrated = { automations: Automation[]; runs: AutomationRun[]; lines: string[] };

const MAX_RUNS = 100;

/** A heartbeat's `every` ("30m", "2h") and active hours ("08:00-22:00") as a cron, or undefined when it can't be one. */
export function heartbeatCron(every: string, activeHours?: string): string | undefined {
	const m = /^(\d+)([mh])$/.exec(every.trim());
	if (!m) return undefined;
	const minutes = m[2] === "h" ? Number(m[1]) * 60 : Number(m[1]);
	let hours = "*";
	const span = activeHours ? /^(\d\d):\d\d-(\d\d):\d\d$/.exec(activeHours) : undefined;
	if (span) {
		const from = Number(span[1]);
		const to = Math.max(from, Number(span[2]) - 1);
		hours = to > from ? `${from}-${to}` : `${from}`;
	}
	if (minutes < 60) return `*/${Math.max(1, minutes)} ${hours} * * *`;
	const stepHours = Math.max(1, Math.round(minutes / 60));
	if (stepHours === 1) return `0 ${hours} * * *`;
	return `0 ${hours === "*" ? "*" : hours}/${stepHours} * * *`;
}

const base = (now: number) => ({ approval: "wait" as const, enabled: true, createdAt: new Date(now).toISOString(), runCount: 0 });

/** One agent's: its definition's schedules, heartbeat and triggers, and the reminders and watches it set itself. */
export function fromAgent(agent: { id: string; name: string; definition: AgentDefinition }, legacy: { reminders: Reminder[]; watches: Watch[]; runs: RunRecord[] }, now: number): Migrated {
	const def = agent.definition;
	const tz = def.timezone ?? systemZone();
	const owner = def.contacts.find((c) => c.role === "owner")?.id;
	const deliver = (to?: string) => (to && to !== owner ? { deliverTo: to } : {});
	const out: Migrated = { automations: [], runs: [], lines: [] };
	const sources = new Map<string, string>();
	const add = (a: Automation, source: string, what: string) => {
		if (a.on === "time") a.next = nextOf(a, now);
		if (a.on === "time" && a.next === undefined) return;
		out.automations.push(a);
		sources.set(source, a.id);
		out.lines.push(`- ${agent.name}: ${what} became “${a.name}” (${whenLabel(a)}).`);
	};
	const short = agent.id.replace(/^agt_/, "").slice(0, 6);
	for (const s of def.schedules ?? []) {
		add({ id: `a${short}${s.id.replace(/[^a-z0-9]/gi, "")}`.slice(0, 32), name: nameOf(s.prompt), on: "time", cron: s.cron, tz: s.tz ?? tz, runsAs: agent.id, prompt: s.prompt, result: "chat", ...deliver(s.deliverTo), by: "you", ...base(now) }, `schedule:${s.id}`, `its schedule “${s.id}”`);
	}
	if (def.heartbeat) {
		const cron = heartbeatCron(def.heartbeat.every, def.heartbeat.activeHours);
		if (cron) add({ id: `a${short}heartbeat`, name: "Check-in", on: "time", cron, tz, runsAs: agent.id, prompt: def.heartbeat.prompt, result: "quiet", by: "you", ...base(now) }, "heartbeat:heartbeat", "its heartbeat");
		else out.lines.push(`- ${agent.name}: its heartbeat (“every ${def.heartbeat.every}”) couldn't become an automation; ask ${agent.name} to make one.`);
	}
	for (const t of def.triggers ?? []) {
		add({ id: `a${short}${t.id.replace(/[^a-z0-9]/gi, "")}`.slice(0, 32), name: nameOf(t.prompt.replaceAll("{{body}}", "").trim() || t.id), on: "webhook", runsAs: agent.id, prompt: t.prompt, result: "chat", by: "you", aliases: [`${agent.id}/${t.id}`], ...base(now) }, `trigger:${t.id}`, `its webhook trigger “${t.id}” (the same URL still works)`);
	}
	for (const r of legacy.reminders) {
		const a: Automation = { id: r.id, name: nameOf(r.prompt), on: "time", ...(r.cron ? { cron: r.cron } : {}), ...(r.at !== undefined ? { at: r.at } : {}), tz: r.tz ?? tz, runsAs: agent.id, prompt: r.prompt, result: "chat", ...deliver(r.deliverTo), by: agent.id, ...base(now), createdAt: r.createdAt };
		add(a, `reminder:${r.id}`, r.cron ? "a schedule it set" : "a reminder it set");
	}
	for (const w of legacy.watches) {
		add(
			{ id: w.id, name: nameOf(w.prompt.replaceAll("{{body}}", "").trim() || "Webhook"), on: w.on, ...(w.folder ? { folder: w.folder } : {}), ...(w.from ? { from: w.from } : {}), ...(w.subject ? { subject: w.subject } : {}), runsAs: agent.id, prompt: w.prompt, result: "chat", ...deliver(w.deliverTo), by: agent.id, ...(w.on === "webhook" ? { aliases: [`${agent.id}/${w.id}`] } : {}), ...base(now), createdAt: w.createdAt },
			`trigger:${w.id}`,
			w.on === "webhook" ? "a webhook routine it set (the same URL still works)" : "an event routine it set",
		);
	}
	// Their history: each one's runs, newest last (the agent keeps its own records too).
	for (const r of [...legacy.runs].sort((x, y) => x.firedAt.localeCompare(y.firedAt))) {
		const kind = r.kind === "schedule" ? "schedule" : r.kind === "heartbeat" ? "heartbeat" : r.kind === "reminder" ? "reminder" : r.kind === "trigger" ? "trigger" : undefined;
		const id = kind ? sources.get(`${kind}:${r.source}`) : undefined;
		if (!id) continue;
		const status = r.status === "done" && r.sent === 0 ? "quiet" : r.status;
		out.runs.push({ id: `ar_${r.id}`, automation: id, firedAt: r.firedAt, cause: kind === "trigger" ? "event" : "time", status, ...(r.summary ? { summary: r.summary } : {}), ...(r.costUsd !== undefined ? { costUsd: r.costUsd } : {}), conversation: `run:${r.id}`, agent: agent.id, agentRun: r.id });
	}
	for (const id of new Set(out.runs.map((r) => r.automation))) {
		const mine = out.runs.filter((r) => r.automation === id);
		const a = out.automations.find((x) => x.id === id)!;
		a.runCount = mine.length;
		a.lastRun = mine[mine.length - 1]!.firedAt;
	}
	out.runs = out.runs.slice(-MAX_RUNS * Math.max(1, out.automations.length));
	return out;
}

/** Projects' routines: run by Piopio in their project, keeping who set them, their next time and their count. */
export function fromProjects(places: LegacyPlace[], projectName: (id: string) => string | undefined, now: number): Migrated & { fired: string[] } {
	const out: Migrated & { fired: string[] } = { automations: [], runs: [], lines: [], fired: [] };
	for (const place of places) {
		const name = projectName(place.project) ?? "a project";
		for (const r of place.routines) {
			const a: Automation = {
				id: r.id,
				name: nameOf(r.prompt.replaceAll("{{body}}", "").trim() || "Webhook"),
				on: r.on,
				...(r.cron ? { cron: r.cron } : {}),
				...(r.at !== undefined ? { at: r.at } : {}),
				...(r.on === "time" ? { tz: r.tz ?? systemZone() } : {}),
				...(r.folder ? { folder: r.folder } : {}),
				...(r.from ? { from: r.from } : {}),
				...(r.subject ? { subject: r.subject } : {}),
				runsAs: PIOPIO,
				project: place.project,
				prompt: r.prompt,
				result: "conversation",
				by: r.by === "you" ? "you" : "piopio",
				...(r.on === "webhook" ? { aliases: [`${place.project}/${r.id}`] } : {}),
				...base(now),
				createdAt: r.createdAt,
				runCount: r.runs,
				...(r.lastRun ? { lastRun: r.lastRun } : {}),
			};
			if (a.on === "time") a.next = r.next ?? nextOf(a, now);
			if (a.on === "time" && a.at !== undefined && a.next === undefined) continue;
			out.automations.push(a);
			if (r.lastRun && r.lastConversation) out.runs.push({ id: `ar_${r.id}_last`, automation: r.id, firedAt: r.lastRun, cause: r.on === "time" ? "time" : "event", status: "done", summary: "Opened a conversation", conversation: r.lastConversation });
			out.lines.push(`- ${name}: the routine “${a.name}” (${whenLabel(a)}) is an automation run by Piopio there.`);
		}
		out.fired.push(...(place.fired ?? []));
	}
	return out;
}

export const REPORT_FILE = "automations-migration.md";

/** The report's head; the lines follow. */
export function reportOf(lines: string[]): string {
	return `# What changed in your routines\n\nSchedules, reminders, watches and project routines are now **automations**: one list in the sidebar, where you can see, pause, change and run each one. Ask Piopio or any agent to make more.\n\n${lines.join("\n")}\n`;
}
