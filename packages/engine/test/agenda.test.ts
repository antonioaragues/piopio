import { expect, test } from "vitest";
import { buildAgenda } from "../src/agenda.js";

/** Home's agenda (docs/spec/21 D2, 27 AU10): a Tuesday morning in Madrid, back at 10:00 after leaving at 22:00. */
test("Home's agenda: today's timeline from automations and boards, and what happened while you were away, one line per automation", () => {
	const tz = "Europe/Madrid";
	const at = (h: number, m = 0, day = 10) => new Date(Date.UTC(2026, 10, day, h - 1, m)).toISOString(); // CET = UTC+1
	const brief = { kind: "agent" as const, id: "agt_brief", name: "Morning briefing" };
	const habit = { kind: "agent" as const, id: "agt_habit", name: "Habit coach" };
	const piopio = { kind: "project" as const, id: "prj_p", name: "piopio" };
	const agenda = buildAgenda({
		now: Date.parse(at(10)),
		tz,
		since: Date.parse(at(22, 0, 9)),
		automations: [
			{ id: "a_brief", name: "Morning briefing", source: brief, on: "time", label: "Every day at 08:00", next: Date.parse(at(8, 0, 11)), enabled: true },
			{ id: "a_bank", name: "Bank emails", source: brief, on: "email", label: "When an email from the bank arrives", enabled: true },
			{ id: "a_check", name: "Check-in", source: habit, on: "time", label: "Every day at 21:00", next: Date.parse(at(21)), enabled: true },
			{ id: "a_week", name: "Weekly brief", source: piopio, on: "time", label: "Every Tuesday at 11:00", next: Date.parse(at(11)), enabled: true },
			{ id: "a_off", name: "Paused one", source: piopio, on: "folder", label: "When a file appears in ~/Inbox", enabled: false },
		],
		runs: [
			{ automation: "a_brief", firedAt: at(8), status: "done", summary: "Sent you today's briefing", costUsd: 0.0009 },
			{ automation: "a_check", firedAt: at(21, 0, 9), status: "quiet", costUsd: 0.0004 },
			{ automation: "a_check", firedAt: at(6, 30), status: "quiet" },
		],
		boards: [{ project: { id: "prj_p", name: "piopio" }, tasks: [{ id: "T1", title: "Fix crash reports", state: "doing", attempts: 0, updatedAt: at(9, 30) }, { id: "T2", title: "Settings screen", state: "done", attempts: 1, updatedAt: at(9) }] }],
		held: 2,
	});
	expect(agenda.today.map((x) => [x.at?.slice(11, 16), x.source.name, x.label, x.state])).toEqual([
		["05:30", "Habit coach", "Check-in", "done"],
		["07:00", "Morning briefing", "Morning briefing", "done"],
		["09:00", "piopio", "fix crash reports", "running"],
		["10:00", "piopio", "Weekly brief", "upcoming"],
		["20:00", "Habit coach", "Check-in", "upcoming"],
		// Within the next 24 hours: tomorrow's 8:00 briefing, after a "Tomorrow" divider.
		["07:00", "Morning briefing", "Morning briefing", "upcoming"],
		[undefined, "Morning briefing", "Bank emails · when an email from the bank arrives", "event"],
	]);
	expect(agenda.today.find((x) => x.at?.startsWith("2026-11-11T07"))?.tomorrow).toBe(true);
	expect(agenda.today.find((x) => x.label === "Weekly brief")?.automation).toBe("a_week");
	expect(agenda.away.map((x) => [x.source.name, x.text, x.quiet])).toEqual([
		["piopio", "finished a task; the reviewer sent one back", false],
		["Morning briefing", "Morning briefing: Sent you today's briefing", false],
		["Habit coach", "Check-in: had nothing new", true],
	]);
	expect(agenda.held).toBe(2);
});
