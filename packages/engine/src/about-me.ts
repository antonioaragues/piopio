/**
 * "About me" memory (07-shared §5, GM1–GM2): one markdown doc about the user, edited in Settings › Chat, shown to
 * Threads and Spaces when on. With capture on, the agents can add facts with `remember_about_me`; every write is a
 * tool card in the conversation and a revision in the editor's history.
 */
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import { EngineError } from "./models.js";
import { applyPatch, describe, diffFacts, memoryPrompt, pushRevision, type MemoryAuthor, type MemoryState, type Revision } from "./runtimes/space-memory.js";
import type { Settings } from "./settings.js";

export const ABOUT_ME_EXTENSION = "piopio-about-me";

export class AboutMe {
	private state: MemoryState;

	constructor(private readonly file: string) {
		this.state = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as MemoryState) : { text: "", revisions: [], proposals: {} };
	}

	get text(): string {
		return this.state.text;
	}

	info(): { text: string; revisions: Omit<Revision, "before" | "after">[] } {
		return { text: this.state.text, revisions: [...this.state.revisions].reverse().map(({ before: _b, after: _a, ...r }) => r) };
	}

	patch(by: MemoryAuthor, add: string[], remove: string[], sectionName?: string): Revision {
		const before = this.state.text;
		const patched = applyPatch(before, add, remove, sectionName);
		const revision: Revision = { id: randomUUID(), at: new Date().toISOString(), by, summary: describe(patched.added, patched.removed), added: patched.added, removed: patched.removed, before, after: patched.text };
		if (patched.added.length || patched.removed.length) {
			this.state.text = patched.text;
			pushRevision(this.state, revision);
			this.save();
		}
		return revision;
	}

	set(text: string): void {
		const after = text.trim();
		if (after === this.state.text) return;
		const { added, removed } = diffFacts(this.state.text, after);
		pushRevision(this.state, { id: randomUUID(), at: new Date().toISOString(), by: { kind: "user" }, summary: added.length || removed.length ? describe(added, removed) : "Edited the text", added, removed, before: this.state.text, after });
		this.state.text = after;
		this.save();
	}

	restore(revisionId: string): void {
		const revision = this.state.revisions.find((r) => r.id === revisionId);
		if (!revision) throw new EngineError("NOT_FOUND", "That version is no longer in the history.");
		this.set(revision.after);
	}

	private save(): void {
		const tmp = `${this.file}.tmp`;
		writeFileSync(tmp, JSON.stringify(this.state, null, "\t"));
		renameSync(tmp, this.file);
	}
}

/** The section and the capture tool, for Threads (`kind: "thread"`) and Spaces. */
export function aboutMeExtension(store: AboutMe, settings: Settings, kind: "thread" | "space") {
	const applies = () => {
		const s = settings.get().aboutMe;
		return s.enabled && (kind === "thread" ? s.inThreads : s.inSpaces);
	};
	const remember = defineTool({
		name: "remember_about_me",
		description: "Save a lasting fact about the user (who they are, their preferences, their situation) to their “About me” memory, which every conversation reads. Only for facts that will matter again; the user sees every change.",
		parameters: Type.Object({
			add: Type.Optional(Type.Array(Type.String(), { description: "Facts to add, one sentence each" })),
			remove: Type.Optional(Type.Array(Type.String(), { description: "Facts that are wrong or outdated" })),
			section: Type.Optional(Type.String({ description: "Heading, e.g. Work, Preferences, Family. Default: Notes" })),
		}),
		execute: async (args) => {
			if (!applies() || !settings.get().aboutMe.capture) return { output: [{ type: "text", text: "Saving to About me is off. The user can turn it on in Settings › Chat." }], isError: true };
			const revision = store.patch({ kind: "organizer" }, args.add ?? [], args.remove ?? [], args.section);
			const text = revision.added.length || revision.removed.length ? `Saved to About me: ${revision.summary}.` : "Nothing changed: already known, or not found.";
			return { output: [{ type: "text", text }], details: { revisionId: revision.id, added: revision.added, removed: revision.removed } as never };
		},
	});
	return defineExtension({
		name: ABOUT_ME_EXTENSION,
		tools: [remember],
		sections: [
			section("about-me", () => {
				if (!applies()) return undefined;
				const capture = settings.get().aboutMe.capture ? "\nWhen the user tells you something lasting about themselves, save it with remember_about_me." : "";
				return `What the user wants you to know about them (their “About me”):\n${memoryPrompt(store.text, "(nothing yet)")}${capture}`;
			}),
		],
	});
}
