/**
 * What a conversation in a project without a folder knows (docs/spec/18 §3): the project's instructions, its files
 * (read with `read_project_file`) and the facts its conversations saved (`remember_in_project`), from the project's
 * memory bank in the built-in provider, shared by every conversation in the project.
 */
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import type { MemoryProvider } from "@piopio/runtime";
import type { ProjectInfo } from "@piopio/protocol";
import { ProjectFiles } from "./project-files.js";

export const PROJECT_EXTENSION = "piopio-project";

/** The memory bank of a project without a folder. */
export const projectBank = (id: string) => `project:${id}`;

/** About 1,500 tokens of facts in every turn; older ones are found with recall in the Memory browser. */
const MAX_FACTS_CHARS = 6_000;

export type ProjectContext = { project: ProjectInfo; memory: MemoryProvider };

/** `current`: the conversation's project now (it can move in or out); undefined outside one. */
export function projectExtension(current: () => ProjectContext | undefined) {
	const files = (c: ProjectContext) => new ProjectFiles(c.project.path);
	const read = defineTool({
		name: "read_project_file",
		description: "Read a file of the project this conversation is in (its text; documents have a text copy). The project's files are listed in the system prompt.",
		parameters: Type.Object({ name: Type.String({ description: "The file name, as listed" }) }),
		execute: async (args) => {
			const c = current();
			if (!c) return { output: [{ type: "text", text: "This conversation isn't in a project." }], isError: true };
			try {
				return { output: [{ type: "text", text: files(c).read(args.name) }] };
			} catch (error) {
				return { output: [{ type: "text", text: (error as Error).message }], isError: true };
			}
		},
	});
	const remember = defineTool({
		name: "remember_in_project",
		description: "Save a fact that matters to the whole project (a decision, a measurement, a date, a preference), so every conversation in the project knows it. One self-contained sentence. The user sees it and can undo it.",
		parameters: Type.Object({ fact: Type.String({ description: "One self-contained sentence" }) }),
		execute: async (args) => {
			const c = current();
			if (!c) return { output: [{ type: "text", text: "This conversation isn't in a project." }], isError: true };
			const fact = args.fact.trim();
			if (!fact) return { output: [{ type: "text", text: "Nothing to save." }], isError: true };
			await c.memory.retain(projectBank(c.project.id), { content: fact, kind: "fact", createdBy: "agent", source: { ref: `project:${c.project.id}`, title: c.project.name } });
			return { output: [{ type: "text", text: `Saved to ${c.project.name}: ${fact}` }] };
		},
	});
	return defineExtension({
		name: PROJECT_EXTENSION,
		tools: [read, remember],
		sections: [
			section("project", async () => {
				const c = current();
				if (!c) return undefined;
				const list = files(c).list();
				const facts = (await c.memory.list?.(projectBank(c.project.id), { kinds: ["fact"], limit: 200 }).catch(() => undefined))?.records ?? [];
				let budget = MAX_FACTS_CHARS;
				const kept = facts.filter((f) => (budget -= f.text.length + 3) > 0).map((f) => `- ${f.text}`);
				return [
					`This conversation is part of the project “${c.project.name}”. Other conversations in the project share its files and what it remembers.`,
					c.project.instructions ? `The project's instructions:\n${c.project.instructions}` : "",
					list.length ? `The project's files (read them with read_project_file):\n${list.map((f) => `- ${f.name} (${Math.max(1, Math.round(f.size / 1024))} KB)`).join("\n")}` : "The project has no files yet.",
					kept.length ? `What the project remembers:\n${kept.join("\n")}` : "The project doesn't remember anything yet.",
					"When something comes up that the whole project should know later (a decision, a number, a date), save it with remember_in_project.",
				]
					.filter(Boolean)
					.join("\n\n");
			}),
		],
	});
}
