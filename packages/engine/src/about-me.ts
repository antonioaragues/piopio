/**
 * "About me" memory (07-shared §5, GM1–GM2), in a memory provider's "about-me" bank: one fact per record, tagged
 * with its section. The editor shows it as markdown (`## Section`, `- fact`), the history comes from the provider,
 * and Undo takes one change back. When on, it's shown to Threads and Spaces; with capture on, agents add facts with
 * `remember_about_me`, and every write is a tool card in the conversation. An MCP memory provider that can't list
 * what it stored (07 §6.2 MM3) shows no text here; the agents then recall from it instead.
 */
import { existsSync, readFileSync, renameSync } from "node:fs";
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import type { BuiltinMemory, MemoryEvent, MemoryProvider, MemoryRecord } from "@piopio/runtime";
import type { MemoryProviders } from "./memory.js";
import { EngineError } from "./models.js";
import { describe, memoryPrompt, type MemoryState } from "./runtimes/space-memory.js";
import type { Settings } from "./settings.js";

export const ABOUT_ME_EXTENSION = "piopio-about-me";
export const ABOUT_ME_BANK = "about-me";
const DEFAULT_SECTION = "Notes";
const PROMPT_CACHE_MS = 30_000;

type Fact = { section: string; text: string };
type Revision = { id: string; at: string; by: { kind: "organizer" | "user" }; summary: string; added: string[]; removed: string[] };

export class AboutMe {
	private cache?: { text: string; at: number };

	constructor(
		private readonly providers: MemoryProviders,
		private readonly settings: Settings,
		private readonly legacyFile: string,
	) {
		settings.onChange((next, previous) => {
			if (next.aboutMe.provider !== previous.aboutMe.provider) this.cache = undefined;
		});
	}

	private get provider(): MemoryProvider {
		return this.providers.get(this.settings.get().aboutMe.provider);
	}

	private get builtin(): BuiltinMemory | undefined {
		return this.provider === this.providers.builtin ? this.providers.builtin : undefined;
	}

	/** Brings the 3.4 doc (`about-me.json`) into the built-in provider, once. */
	async migrate(): Promise<void> {
		if (!existsSync(this.legacyFile)) return;
		const builtin = this.providers.builtin;
		if (!(await builtin.list(ABOUT_ME_BANK, { limit: 1 })).records.length) {
			const legacy = JSON.parse(readFileSync(this.legacyFile, "utf8")) as MemoryState;
			const batch = builtin.batch();
			for (const f of parse(legacy.text)) await builtin.retain(ABOUT_ME_BANK, { content: f.text, kind: "fact", createdBy: "user", tags: [f.section] });
			batch.end();
		}
		renameSync(this.legacyFile, `${this.legacyFile}.migrated`);
	}

	private async facts(): Promise<MemoryRecord[]> {
		const provider = this.provider;
		if (!provider.list || !provider.capabilities.list) return [];
		const out: MemoryRecord[] = [];
		let cursor: string | undefined;
		do {
			const page = await provider.list(ABOUT_ME_BANK, { limit: 200, ...(cursor ? { cursor } : {}) });
			out.push(...page.records);
			cursor = page.cursor;
		} while (cursor && out.length < 2000);
		return out.reverse(); // oldest first, as written
	}

	async text(): Promise<string> {
		return render((await this.facts()).map((r) => ({ section: r.tags?.[0] ?? DEFAULT_SECTION, text: r.text })));
	}

	/** What the agents see: the doc, or, from a provider that can't list, what it recalls about the user. */
	async promptText(): Promise<string> {
		if (this.cache && Date.now() - this.cache.at < PROMPT_CACHE_MS) return this.cache.text;
		const provider = this.provider;
		const text = provider.capabilities.list ? await this.text() : (await provider.recall([ABOUT_ME_BANK], "Who the user is: their life, work, preferences and situation", { budgetTokens: 800 })).map((h) => `- ${h.text}`).join("\n");
		this.cache = { text, at: Date.now() };
		return text;
	}

	async info(): Promise<{ text: string; revisions: Revision[]; provider: string; limited: boolean }> {
		const provider = this.provider;
		return {
			text: await this.text(),
			revisions: provider.history && provider.capabilities.history ? group(await provider.history(ABOUT_ME_BANK, { limit: 200 })) : [],
			provider: provider.id,
			limited: !provider.capabilities.list,
		};
	}

	/** Adds facts under `section` and removes facts that match (exactly, else the first that contains the text). */
	async patch(by: "agent" | "user", add: string[], remove: string[], sectionName = DEFAULT_SECTION): Promise<{ added: string[]; removed: string[]; summary: string }> {
		const provider = this.provider;
		const batch = this.builtin?.batch();
		const added: string[] = [];
		const removed: string[] = [];
		try {
			const current = provider.capabilities.list ? await this.facts() : [];
			for (const r of remove) {
				const want = r.trim().toLowerCase();
				if (!want) continue;
				if (!provider.forget || !provider.capabilities.forget || !provider.capabilities.list) throw new EngineError("INVALID", "This memory provider can't remove facts from here; remove them in the memory system itself.");
				const hit = current.find((f) => f.text.toLowerCase() === want) ?? current.find((f) => f.text.toLowerCase().includes(want));
				if (!hit) continue;
				await provider.forget(ABOUT_ME_BANK, hit.id, by);
				current.splice(current.indexOf(hit), 1);
				removed.push(hit.text);
			}
			for (const a of add) {
				const fact = a.replace(/\s+/g, " ").replace(/^[-*]\s+/, "").trim();
				if (!fact || current.some((f) => f.text.toLowerCase() === fact.toLowerCase())) continue;
				await provider.retain(ABOUT_ME_BANK, { content: fact, kind: "fact", createdBy: by, tags: [sectionName.trim() || DEFAULT_SECTION] });
				added.push(fact);
			}
		} finally {
			batch?.end();
			this.cache = undefined;
		}
		return { added, removed, summary: describe(added, removed) };
	}

	/** Your edit in Settings › Chat: the facts that differ are added or forgotten. */
	async set(text: string): Promise<void> {
		const before = (await this.facts()).map((r) => ({ section: r.tags?.[0] ?? DEFAULT_SECTION, text: r.text }));
		const after = parse(text);
		const key = (f: Fact) => f.text.toLowerCase();
		const removed = before.filter((f) => !after.some((g) => key(g) === key(f)));
		const added = after.filter((f) => !before.some((g) => key(g) === key(f)));
		const provider = this.provider;
		const batch = this.builtin?.batch();
		try {
			if (removed.length) await this.patch("user", [], removed.map((f) => f.text));
			for (const f of added) await provider.retain(ABOUT_ME_BANK, { content: f.text, kind: "fact", createdBy: "user", tags: [f.section] });
		} finally {
			batch?.end();
			this.cache = undefined;
		}
	}

	/** Takes one change of the history back: what it added goes, what it removed comes back (in its section). */
	async undo(revisionId: string): Promise<void> {
		const provider = this.provider;
		if (!provider.history || !provider.capabilities.history) throw new EngineError("INVALID", "This memory provider has no history to undo.");
		const events = (await provider.history(ABOUT_ME_BANK, { limit: 500 })).filter((e) => (e.batch ?? e.id) === revisionId);
		if (!events.length) throw new EngineError("NOT_FOUND", "That change is no longer in the history.");
		const current = await this.facts();
		const batch = this.builtin?.batch();
		try {
			for (const e of events) {
				if (e.action === "added") {
					const record = current.find((r) => r.id === e.recordId);
					if (record) await provider.forget!(ABOUT_ME_BANK, record.id, "user");
				} else if (e.action === "removed" && !current.some((r) => r.text === e.text)) {
					await provider.retain(ABOUT_ME_BANK, { content: e.text, kind: "fact", createdBy: "user", tags: e.tags ?? [DEFAULT_SECTION] });
				}
			}
		} finally {
			batch?.end();
			this.cache = undefined;
		}
	}
}

/** Changes grouped as they were made (one edit, one tool call), newest first. */
function group(events: readonly MemoryEvent[]): Revision[] {
	const out: Revision[] = [];
	const byId = new Map<string, Revision>();
	for (const e of events) {
		const id = e.batch ?? e.id;
		let r = byId.get(id);
		if (!r) {
			r = { id, at: e.at, by: { kind: e.by === "user" ? "user" : "organizer" }, summary: "", added: [], removed: [] };
			byId.set(id, r);
			out.push(r);
		}
		if (e.action === "added") r.added.push(e.text);
		else if (e.action === "removed") r.removed.push(e.text);
	}
	for (const r of out) {
		// Events come newest first; within a change, show them as they were written.
		r.added.reverse();
		r.removed.reverse();
		r.summary = describe(r.added, r.removed);
	}
	return out;
}

function parse(text: string): Fact[] {
	let sectionName = DEFAULT_SECTION;
	const facts: Fact[] = [];
	for (const line of text.split("\n")) {
		const heading = /^##\s+(.+)$/.exec(line.trim());
		if (heading) sectionName = heading[1]!.trim();
		else if (/^\s*[-*]\s+\S/.test(line)) facts.push({ section: sectionName, text: line.replace(/^\s*[-*]\s+/, "").trim() });
	}
	return facts;
}

function render(facts: readonly Fact[]): string {
	const sections = new Map<string, string[]>();
	for (const f of facts) sections.set(f.section, [...(sections.get(f.section) ?? []), f.text]);
	return [...sections].map(([name, items]) => `## ${name}\n${items.map((i) => `- ${i}`).join("\n")}`).join("\n\n");
}

/** The section and the capture tool, for Threads (`kind: "thread"`) and Spaces. */
export function aboutMeExtension(store: AboutMe, settings: Settings, kind: "thread" | "space" | "agent") {
	const applies = () => {
		const s = settings.get().aboutMe;
		return s.enabled && (kind === "thread" ? s.inThreads : kind === "space" ? s.inSpaces : s.inAgents === true);
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
			const change = await store.patch("agent", args.add ?? [], args.remove ?? [], args.section);
			const text = change.added.length || change.removed.length ? `Saved to About me: ${change.summary}.` : "Nothing changed: already known, or not found.";
			return { output: [{ type: "text", text }], details: { added: change.added, removed: change.removed } as never };
		},
	});
	return defineExtension({
		name: ABOUT_ME_EXTENSION,
		tools: [remember],
		sections: [
			section("about-me", async () => {
				if (!applies()) return undefined;
				const capture = settings.get().aboutMe.capture ? "\nWhen the user tells you something lasting about themselves, save it with remember_about_me." : "";
				return `What the user wants you to know about them (their “About me”):\n${memoryPrompt(await store.promptText().catch(() => ""), "(nothing yet)")}${capture}`;
			}),
		],
	});
}
