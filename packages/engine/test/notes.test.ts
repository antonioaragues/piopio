import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { notesExtension } from "../src/runtimes/build.js";

/** The handler the extension registers for `before_agent_start`. */
function beforeStart(cwd: string) {
	let handler: ((event: { systemPrompt: string }) => { systemPrompt: string } | undefined) | undefined;
	notesExtension(cwd)({ on: (name: string, fn: typeof handler) => void (name === "before_agent_start" && (handler = fn)) } as never);
	return handler!;
}

test("a folder's NOTES.md is read every turn, and the model is asked to keep it (docs/spec/18 CF4)", () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-notes-"));
	expect(beforeStart(dir)({ systemPrompt: "Base" })).toBeUndefined(); // no notes file: nothing added
	writeFileSync(join(dir, "NOTES.md"), "# Notes\n\n- The sink moves 40 cm left.\n");
	const prompt = beforeStart(dir)({ systemPrompt: "Base" })!.systemPrompt;
	expect(prompt.startsWith("Base\n\n")).toBe(true);
	expect(prompt).toContain("add it to NOTES.md");
	expect(prompt).toContain("- The sink moves 40 cm left.");
	writeFileSync(join(dir, "NOTES.md"), "x".repeat(10_000));
	expect(beforeStart(dir)({ systemPrompt: "" })!.systemPrompt).toContain("[… the rest is in NOTES.md]");
});

test("Build's working rules are in every turn's system prompt: stop when done, push only what's asked, don't wait on timers", async () => {
	const { guardsExtension, WORKING_RULES } = await import("../src/tools/guards.js");
	let handler: ((event: { systemPrompt: string }) => { systemPrompt: string } | undefined) | undefined;
	guardsExtension()({ on: (name: string, fn: typeof handler) => void (name === "before_agent_start" && (handler = fn)) } as never);
	const prompt = handler!({ systemPrompt: "Base" })!.systemPrompt;
	expect(prompt).toBe(`Base\n\n${WORKING_RULES}`);
	expect(WORKING_RULES).toContain("then stop and report");
	expect(WORKING_RULES).toContain("another push needs their go-ahead");
	expect(WORKING_RULES).toContain("gh run watch");
});
