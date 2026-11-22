import type { TimelineItem } from "@piopio/protocol";
import { expect, test } from "vitest";
import { turnError } from "../src/automations/model.js";

const at = "2026-11-22T09:00:00Z";
const user = { kind: "user", id: "u", at, text: "Write the brief" } as unknown as TimelineItem;
const answer = (status: string, error?: string) => ({ kind: "assistant", id: `a${status}`, at, text: "", status, ...(error ? { error } : {}) }) as unknown as TimelineItem;
const system = (level: string, text: string) => ({ kind: "system", id: `s${level}`, at, level, text }) as unknown as TimelineItem;

test("an automation's turn failed when its last answer, or the run itself, ended in an error", () => {
	expect(turnError([user, answer("done")])).toBeUndefined();
	expect(turnError([user, answer("error", "Rate limited")])).toBe("Rate limited");
	expect(turnError([user, answer("error")])).toBe("The model's answer failed.");
	expect(turnError([user, system("error", "No API key for openrouter")])).toBe("No API key for openrouter");
	// A retry that worked wins; an error from an earlier turn doesn't count.
	expect(turnError([user, answer("error", "Timeout"), answer("done")])).toBeUndefined();
	expect(turnError([answer("error", "Old"), user, answer("done")])).toBeUndefined();
	expect(turnError([user, answer("done"), system("info", "Compacted")])).toBeUndefined();
});
