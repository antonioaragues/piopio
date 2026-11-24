/**
 * /learn (docs/spec/14 M5): what a conversation proposes to keep, written where it belongs once you save the card.
 * Project rules go into the project's instructions file (Q3: AGENTS.md, pi's own context file), as bullets under a
 * section; facts about you go to About me. Plain code here, no model: the model only proposes (tools/learn.ts).
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { LearnItem } from "@piopio/protocol";

/** Where a section's bullets go when the model names none. */
export const DEFAULT_SECTION = "Lessons";

/**
 * The project's instructions file: AGENTS.md when it's there or when there's none; CLAUDE.md when that's the only one,
 * so Claude Code keeps reading what Piopio learned (pi reads both).
 */
export function instructionsFile(project: string): string {
	for (const name of ["AGENTS.md", "CLAUDE.md"]) if (existsSync(join(project, name))) return name;
	return "AGENTS.md";
}

const bullet = (text: string) => `- ${text.replace(/\s+/g, " ").replace(/^[-*]\s+/, "").trim()}`;
const sectionOf = (item: Pick<LearnItem, "section">) => item.section?.replace(/^#+\s*/, "").trim() || DEFAULT_SECTION;

/**
 * The file with the rules added: each under its `## Section` when the file has one (after its last line), else in a
 * new section at the end. A rule already there, word for word, isn't added again.
 */
export function addRules(content: string, items: readonly Pick<LearnItem, "text" | "section">[]): { content: string; added: string[] } {
	const lines = content.replace(/\r\n/g, "\n").split("\n");
	if (lines.length && lines.at(-1) === "") lines.pop();
	const added: string[] = [];
	const present = new Set(lines.map((l) => l.trim()));
	const bySection = new Map<string, string[]>();
	for (const item of items) {
		const line = bullet(item.text);
		if (line === "- " || present.has(line) || added.includes(line)) continue;
		added.push(line);
		const key = sectionOf(item);
		bySection.set(key, [...(bySection.get(key) ?? []), line]);
	}
	for (const [section, rules] of bySection) {
		const at = lines.findIndex((l) => /^##\s+/.test(l) && l.replace(/^##\s+/, "").trim().toLowerCase() === section.toLowerCase());
		if (at < 0) {
			if (lines.length && lines.at(-1)!.trim() !== "") lines.push("");
			lines.push(`## ${section}`, "", ...rules);
			continue;
		}
		// The section ends where the next heading starts; rules go after its last non-blank line.
		let end = lines.findIndex((l, i) => i > at && /^#{1,2}\s+/.test(l));
		if (end < 0) end = lines.length;
		let last = end - 1;
		while (last > at && lines[last]!.trim() === "") last--;
		lines.splice(last + 1, 0, ...(last === at ? ["", ...rules] : rules));
	}
	return { content: `${lines.join("\n")}\n`, added };
}

/** Takes the rules a save added back out; a section left empty goes too, and a file left with nothing is "". */
export function removeRules(content: string, added: readonly string[]): string {
	const remove = new Set(added);
	let lines = content.replace(/\r\n/g, "\n").split("\n").filter((l) => !remove.has(l.trim()));
	// Sections with no content left (a heading followed only by blanks up to the next heading or the end).
	for (let i = lines.length - 1; i >= 0; i--) {
		if (!/^##\s+/.test(lines[i]!)) continue;
		let j = i + 1;
		while (j < lines.length && lines[j]!.trim() === "") j++;
		if (j === lines.length || /^#{1,2}\s+/.test(lines[j]!)) lines.splice(i, j - i);
	}
	while (lines.length && lines.at(-1)!.trim() === "") lines.pop();
	lines = lines.length ? [...lines, ""] : [];
	return lines.join("\n");
}

/** The file's current text, or "" when it isn't there yet. */
export function readInstructions(project: string, file: string): string {
	const path = join(project, file);
	return existsSync(path) ? readFileSync(path, "utf8") : "";
}
