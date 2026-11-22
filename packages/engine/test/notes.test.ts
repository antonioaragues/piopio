import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { notesExtension } from "../src/runtimes/build.js";

type Event = { systemPrompt: string; systemPromptOptions: { sections: Record<string, string> } };

/** The section the extension's `before_agent_start` handler writes in pi's prompt (docs/spec/38 §8 R1). */
function notesSection(cwd: string): string | undefined {
	let handler: ((event: Event) => unknown) | undefined;
	notesExtension(cwd)({ on: (name: string, fn: typeof handler) => void (name === "before_agent_start" && (handler = fn)) } as never);
	const event: Event = { systemPrompt: "Base", systemPromptOptions: { sections: {} } };
	expect(handler!(event)).toBeUndefined(); // a section, never a forced prompt
	return event.systemPromptOptions.sections["project-notes"];
}

test("a folder's NOTES.md is read every turn, and the model is asked to keep it (docs/spec/18 CF4)", () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-notes-"));
	expect(notesSection(dir)).toBeUndefined(); // no notes file: nothing added
	writeFileSync(join(dir, "NOTES.md"), "# Notes\n\n- The sink moves 40 cm left.\n");
	const notes = notesSection(dir)!;
	expect(notes).toContain("add it to NOTES.md");
	expect(notes).toContain("- The sink moves 40 cm left.");
	writeFileSync(join(dir, "NOTES.md"), "x".repeat(10_000));
	expect(notesSection(dir)).toContain("[… the rest is in NOTES.md]");
});
