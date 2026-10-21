import { describe, expect, test } from "vitest";
import { dayOf, inWindow, nextDay, nextFire, nextHeartbeat, windowEnd } from "../src/agents/time.js";

const at = (iso: string) => Date.parse(iso);
const iso = (t: number) => new Date(t).toISOString();

describe("proactivity time", () => {
	test("cron next fire, in a time zone, across DST and with day-of-week", () => {
		// Madrid is UTC+2 in summer, UTC+1 from the last Sunday of October.
		expect(iso(nextFire("0 8 * * 1-5", "Europe/Madrid", at("2026-10-21T05:00:00Z")))).toBe("2026-10-21T06:00:00.000Z");
		expect(iso(nextFire("0 8 * * 1-5", "Europe/Madrid", at("2026-10-21T06:00:00Z")))).toBe("2026-10-22T06:00:00.000Z");
		expect(iso(nextFire("0 8 * * 1-5", "Europe/Madrid", at("2026-10-23T07:00:00Z")))).toBe("2026-10-26T07:00:00.000Z"); // Monday, after DST
		expect(iso(nextFire("*/15 * * * *", "UTC", at("2026-10-21T10:07:30Z")))).toBe("2026-10-21T10:15:00.000Z");
		expect(iso(nextFire("0 9 1 * *", "UTC", at("2026-10-21T10:00:00Z")))).toBe("2026-11-01T09:00:00.000Z");
		expect(iso(nextFire("0 9 13 * 5", "UTC", at("2026-10-21T10:00:00Z")))).toBe("2026-10-23T09:00:00.000Z"); // Friday OR the 13th
	});

	test("quiet hours across midnight, heartbeat within active hours, days", () => {
		expect(inWindow("22:30-07:30", at("2026-10-21T21:00:00Z"), "Europe/Madrid")).toBe(true); // 23:00 local
		expect(inWindow("22:30-07:30", at("2026-10-21T10:00:00Z"), "Europe/Madrid")).toBe(false);
		expect(iso(windowEnd("22:30-07:30", at("2026-10-21T21:00:00Z"), "Europe/Madrid"))).toBe("2026-10-22T05:30:00.000Z");
		expect(iso(nextHeartbeat("4h", "08:00-22:00", "UTC", at("2026-10-21T20:00:00Z")))).toBe("2026-10-22T08:00:00.000Z");
		expect(iso(nextHeartbeat("30m", undefined, "UTC", at("2026-10-21T20:00:00Z")))).toBe("2026-10-21T20:30:00.000Z");
		expect(dayOf(at("2026-10-21T23:30:00Z"), "Europe/Madrid")).toBe("2026-10-22");
		expect(iso(nextDay(at("2026-10-21T10:20:00Z"), "UTC"))).toBe("2026-10-22T00:00:00.000Z");
	});
});
