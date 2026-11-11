import { expect, test } from "vitest";
import { buildAgenda } from "../src/agenda.js";

/** Home's agenda (docs/spec/21 D2, design 5e): a Tuesday morning in Madrid, back at 10:00 after leaving at 22:00. */
test("Home's agenda: today's timeline across agents, projects and teams, and what happened while you were away", () => {
	const tz = "Europe/Madrid";
	const at = (h: number, m = 0, day = 10) => new Date(Date.UTC(2026, 10, day, h - 1, m)).toISOString(); // CET = UTC+1
	const agenda = buildAgenda({
		now: Date.parse(at(10)),
		tz,
		since: Date.parse(at(22, 0, 9)),
		agents: [
			{
				id: "agt_brief",
				name: "Morning briefing",
				runs: [{ id: "r1", kind: "schedule", source: "Morning briefing", prompt: "Send the briefing", firedAt: at(8), status: "done", summary: "Sent you today's briefing", sent: 1, costUsd: 0.0009 }],
				upcoming: [{ id: "s1", kind: "schedule", label: "Morning briefing", next: at(8, 0, 11) }, { id: "w1", kind: "watch", label: "Bank emails" }],
				held: 0,
			},
			{
				id: "agt_habit",
				name: "Habit coach",
				runs: [{ id: "r2", kind: "schedule", source: "Check-in", prompt: "Check in", firedAt: at(21, 0, 9), status: "done", sent: 0, costUsd: 0.0004 }, { id: "r3", kind: "schedule", source: "Check-in", prompt: "Check in", firedAt: at(6, 30), status: "done", sent: 0 }],
				upcoming: [{ id: "s2", kind: "schedule", label: "Check-in", next: at(21) }],
				held: 2,
			},
		],
		projects: [{ id: "prj_p", name: "piopio", routines: [{ id: "rt", on: "time", prompt: "Write this week's brief", cron: "0 11 * * 2", tz, by: "you", createdAt: at(9, 0, 1), next: Date.parse(at(11)), runs: 0 }] }],
		teams: [{ id: "team_p", name: "Development team", project: { id: "prj_p", name: "piopio" }, tasks: [{ id: "T1", title: "Fix crash reports", state: "doing", attempts: 0, updatedAt: at(9, 30) }, { id: "T2", title: "Settings screen", state: "done", attempts: 1, updatedAt: at(9) }] }],
	});
	expect(agenda.today.map((x) => [x.at?.slice(11, 16), x.source.name, x.label, x.state])).toEqual([
		["05:30", "Habit coach", "", "done"],
		["07:00", "Morning briefing", "", "done"],
		["09:00", "piopio team", "fix crash reports", "running"],
		["10:00", "piopio", "Write this week's brief", "upcoming"],
		["20:00", "Habit coach", "Check-in", "upcoming"],
		// Within the next 24 hours: tomorrow's 8:00 briefing, after a "Tomorrow" divider.
		["07:00", "Morning briefing", "Morning briefing", "upcoming"],
		[undefined, "Morning briefing", "Bank emails", "event"],
	]);
	expect(agenda.today.find((x) => x.at?.startsWith("2026-11-11T07"))?.tomorrow).toBe(true);
	expect(agenda.away.map((x) => [x.source.name, x.text, x.quiet])).toEqual([
		["piopio team", "finished a task; the reviewer sent one back", false],
		["Morning briefing", "Sent you today's briefing", false],
		["Habit coach", "had nothing new", true],
	]);
	expect(agenda.held).toBe(2);
});
