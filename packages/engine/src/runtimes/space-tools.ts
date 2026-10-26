/**
 * The Space's agent tools (docs/spec/04-chat §3.3, §3.5). The organizer (Main) routes, creates topics, keeps the
 * memory and tidies topics. Topics propose memory changes. Both can ask another topic, search the Space and read
 * its files. They reach the runtime through `SpaceHost`.
 */
import type { Context } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import { defineDoc, defineExtension, defineTool, section, type Conversation, type ConversationId, type Tx } from "@earendil-works/pi-durable";
import { USER_ENTRY } from "../input.js";
import { contentText, type PiContentBlock } from "../timeline/builder.js";
import type { SpaceFiles } from "./space-files.js";
import { memoryPrompt, type MemoryAuthor, type Proposal, type Revision } from "./space-memory.js";

export type TopicRecord = {
	id: string;
	title: string;
	brief: string;
	status: "active" | "archived";
	createdAt: string;
	lastActiveAt: string;
	lastReplyAt?: string;
	/** One or two lines, refreshed after each reply. */
	summary?: string;
	mergedInto?: string;
};
export type Hint = { message: string; wrong: string; right: string; at: string };
/** Where a routed message went: the organizer's tool result details, a route entry, or a reroute. */
export type Route = { decision: "route" | "create"; topicId: string; topicTitle: string; reason: string; message: string; submissionId?: string; forced?: boolean; movedFrom?: string; at?: string };
export type SpaceState = { topics: TopicRecord[]; hints: Hint[]; reroutes: Record<string, Route> };

/** The Space's topics, routing hints and moved messages (`piopio.space`). */
export const SpaceDoc = defineDoc<SpaceState>({ kind: "piopio.space", version: 1, scope: "session", initial: () => ({ topics: [], hints: [], reroutes: {} }), checkpointWhen: () => false });

/** Tools whose cards the views turn into routing and memory cards. */
export const ROUTE_TOOLS = new Set(["route_to_topic", "create_topic"]);
export const MEMORY_TOOLS = new Set(["update_memory", "propose_memory"]);

export interface SpaceHost {
	readonly info: { name: string; instructions?: string };
	readonly settings: { memory: boolean; autoTidy: boolean };
	readonly topics: readonly TopicRecord[];
	readonly hints: readonly Hint[];
	readonly memoryText: string;
	readonly files: SpaceFiles;
	topic(idOrTitle: string): TopicRecord | undefined;
	createTopic(tx: Tx, title: string, brief: string): Promise<TopicRecord>;
	sendToTopic(topicId: string, text: string, requestId: string, conversation?: (id: ConversationId) => Promise<{ submit: Conversation["submit"] } | undefined>): Promise<string>;
	touchTopic(topicId: string): Promise<void>;
	updateMemory(by: MemoryAuthor, add: string[], remove: string[], section?: string): Promise<Revision>;
	proposeMemory(topicId: string, add: string[], remove: string[], reason: string): Promise<Proposal>;
	renameTopic(topicId: string, title: string): Promise<void>;
	archiveTopic(topicId: string, archived: boolean): Promise<void>;
	mergeTopics(fromId: string, intoId: string): Promise<string>;
	search(query: string): Promise<string[]>;
}

type ToolApi = { commit: <T>(change: (tx: Tx) => Promise<T>, context: Context) => Promise<T>; conversationId: ConversationId; taskId: unknown; conversation: (id: ConversationId, context: Context) => Promise<unknown> };

const text = (t: string, isError = false) => ({ output: [{ type: "text" as const, text: t }], ...(isError ? { isError: true } : {}) });
const noTopic = (host: SpaceHost, name: string) => text(`No topic “${name}”. Topics: ${host.topics.map((t) => `${t.id} “${t.title}”`).join(", ") || "none yet"}.`, true);

// ── Organizer (Main) ─────────────────────────────────────────────────────────

export function organizerExtension(host: () => SpaceHost) {
	const routeTool = defineTool({
		name: "route_to_topic",
		description: "Send the user's latest message to an existing topic. The topic's agent answers it there; you don't answer it yourself.",
		parameters: Type.Object({
			topic: Type.String({ description: "The topic's id or exact title" }),
			reason: Type.String({ description: "One short line saying why it belongs there" }),
			message: Type.Optional(Type.String({ description: "The message as the topic should get it. Default: the user's words as written. Rewrite only to add context from Main that the topic needs." })),
		}),
		execute: async (args, api, context) => {
			const space = host();
			const topic = space.topic(args.topic);
			if (!topic) return noTopic(space, args.topic);
			const message = args.message?.trim() || (await lastUserText(api as never, context));
			const submissionId = await space.sendToTopic(topic.id, message, `route:${String(api.taskId)}`, (id) => api.conversation(id, context) as never);
			await space.touchTopic(topic.id);
			const details: Route = { decision: "route", topicId: topic.id, topicTitle: topic.title, reason: args.reason, message, submissionId };
			return { ...text(`Sent to “${topic.title}”. Its agent answers there.`), details: details as never, control: { terminate: true } };
		},
	});

	const createTool = defineTool({
		name: "create_topic",
		description: "Start a new topic for a new subject that will likely come back or needs depth, and send the user's latest message to it. Its agent answers there.",
		parameters: Type.Object({
			title: Type.String({ description: "A short title (2–5 words)" }),
			brief: Type.String({ description: "One or two sentences: what this topic is about, for its agent" }),
			reason: Type.String({ description: "One short line saying why this needs its own topic" }),
			message: Type.Optional(Type.String({ description: "The message as the topic should get it. Default: the user's words as written." })),
		}),
		execute: async (args, api, context) => {
			const space = host();
			const topic = await api.commit((tx) => space.createTopic(tx, args.title, args.brief), context);
			const message = args.message?.trim() || (await lastUserText(api as never, context));
			const submissionId = await space.sendToTopic(topic.id, message, `route:${String(api.taskId)}`, (id) => api.conversation(id, context) as never);
			const details: Route = { decision: "create", topicId: topic.id, topicTitle: topic.title, reason: args.reason, message, submissionId };
			return { ...text(`Created “${topic.title}” and sent the message there. Its agent answers there.`), details: details as never, control: { terminate: true } };
		},
	});

	const memoryTool = defineTool({
		name: "update_memory",
		description: "Change the Notebook's memory: decisions, facts and preferences that every topic should know. Add short, self-contained facts; remove ones that are wrong or outdated. The user sees each change and can undo it.",
		parameters: Type.Object({
			add: Type.Optional(Type.Array(Type.String(), { description: "Facts to add, one sentence each" })),
			remove: Type.Optional(Type.Array(Type.String(), { description: "Facts to remove (their text, or enough of it to find them)" })),
			section: Type.Optional(Type.String({ description: "The heading to add under, e.g. Decisions, Preferences, Facts. Default: Notes" })),
		}),
		execute: async (args) => {
			const space = host();
			if (!space.settings.memory) return text("Memory is off for this Notebook.", true);
			const revision = await space.updateMemory({ kind: "organizer" }, args.add ?? [], args.remove ?? [], args.section);
			if (!revision.added.length && !revision.removed.length) return text("Nothing changed: those facts were already there, or weren't found.");
			return { ...text(`Memory updated: ${revision.summary}.`), details: { revisionId: revision.id, added: revision.added, removed: revision.removed } as never };
		},
	});

	const tidy = (run: (space: SpaceHost) => Promise<string>) => async () => {
		const space = host();
		if (!space.settings.autoTidy) return text("Not done: auto-tidy is off in this Notebook. Suggest it to the user in your answer instead; they can do it from the topic's menu.", true);
		return text(await run(space));
	};

	const renameTool = defineTool({
		name: "rename_topic",
		description: "Rename a topic whose subject drifted. Only when auto-tidy is on; otherwise suggest it to the user.",
		parameters: Type.Object({ topic: Type.String({ description: "The topic's id or title" }), title: Type.String({ description: "The new title" }) }),
		execute: async (args) => {
			const topic = host().topic(args.topic);
			if (!topic) return noTopic(host(), args.topic);
			return tidy(async (space) => (await space.renameTopic(topic.id, args.title), `Renamed “${topic.title}” to “${args.title.trim()}”.`))();
		},
	});

	const archiveTool = defineTool({
		name: "archive_topic",
		description: "Archive a topic that is finished. Only when auto-tidy is on; otherwise suggest it to the user.",
		parameters: Type.Object({ topic: Type.String({ description: "The topic's id or title" }) }),
		execute: async (args) => {
			const topic = host().topic(args.topic);
			if (!topic) return noTopic(host(), args.topic);
			return tidy(async (space) => (await space.archiveTopic(topic.id, true), `Archived “${topic.title}”.`))();
		},
	});

	const mergeTool = defineTool({
		name: "merge_topics",
		description: "Merge topic `from` into topic `into` when they cover the same subject: a summary of `from` joins `into`'s brief and `from` is archived. Only when auto-tidy is on; otherwise suggest it to the user.",
		parameters: Type.Object({ from: Type.String({ description: "The topic to merge away (id or title)" }), into: Type.String({ description: "The topic to keep (id or title)" }) }),
		execute: async (args) => {
			const from = host().topic(args.from), into = host().topic(args.into);
			if (!from) return noTopic(host(), args.from);
			if (!into) return noTopic(host(), args.into);
			return tidy(async (space) => `Merged “${from.title}” into “${into.title}”: ${await space.mergeTopics(from.id, into.id)}`)();
		},
	});

	return defineExtension({
		name: "piopio-space-organizer",
		tools: [routeTool, createTool, memoryTool, renameTool, archiveTool, mergeTool],
		sections: [section("space-organizer", () => organizerPrompt(host()))],
	});
}

function organizerPrompt(space: SpaceHost): string {
	const { name, instructions } = space.info;
	const topics = space.topics.length
		? [...space.topics]
				.sort((a, b) => b.lastActiveAt.localeCompare(a.lastActiveAt))
				.map((t) => `- id ${t.id} · “${t.title}”${t.brief ? `: ${t.brief}` : ""}${t.summary ? ` Latest: ${t.summary}` : ""} (last active ${t.lastActiveAt.slice(0, 16).replace("T", " ")})`)
				.join("\n")
		: "(no topics yet)";
	const hints = space.hints.length ? `\n\nCorrections the user made (route similar messages the same way):\n${space.hints.map((h) => `- “${h.message}” belongs in “${h.right}”, not “${h.wrong}”`).join("\n")}` : "";
	const memory = space.settings.memory ? "\nWhen the user states a decision, fact or preference that matters beyond one message, save it with update_memory." : "";
	const tidy = space.settings.autoTidy ? "\nAuto-tidy is on: rename, archive or merge topics yourself when it clearly helps, and say so." : "\nWhen topics should be renamed, archived or merged, suggest it in your answer (auto-tidy is off).";
	return `You are the organizer of the Space “${name}”, an area of the user's life or work. The user always writes to you, in Main. For each message, decide one of:
1. Route it: when it continues the subject of an existing topic, call route_to_topic.
2. Create a topic: when it starts a new subject that will likely come back or needs depth, call create_topic (it also sends the message there).
3. Answer it yourself, here: quick one-offs, questions about the Space or its topics, and questions across topics (ask_topic and search_space help). Call no routing tool then.
When you route or create, the topic's agent answers in the topic, so don't answer the message yourself. The reason you give is shown to the user: one short line.${memory}${tidy}${instructions ? `\n\nThe Notebook's instructions:\n${instructions}` : ""}

Topics, most recently active first:
${topics}${hints}`;
}

// ── Topics ───────────────────────────────────────────────────────────────────

export function topicExtension(host: () => SpaceHost) {
	const proposeTool = defineTool({
		name: "propose_memory",
		description: "Propose a change to the Notebook's memory (facts every topic should know). The user saves or dismisses it.",
		parameters: Type.Object({
			add: Type.Optional(Type.Array(Type.String(), { description: "Facts to add, one sentence each" })),
			remove: Type.Optional(Type.Array(Type.String(), { description: "Facts to remove" })),
			reason: Type.String({ description: "One short line: why this belongs in memory" }),
		}),
		execute: async (args, api) => {
			const space = host();
			if (!space.settings.memory) return text("Memory is off for this Notebook.", true);
			if (!args.add?.length && !args.remove?.length) return text("Nothing to propose.", true);
			const proposal = await space.proposeMemory(String(api.conversationId), args.add ?? [], args.remove ?? [], args.reason);
			return { ...text("Proposed. The user saves or dismisses it."), details: { proposalId: proposal.id } as never };
		},
	});

	return defineExtension({
		name: "piopio-space-topic",
		tools: [proposeTool],
		sections: [
			section("space-topic", (input) => {
				const space = host();
				const topic = space.topics.find((t) => t.id === String(input.conversationId));
				if (!topic) return undefined;
				const { name, instructions } = space.info;
				return `You are the agent for the topic “${topic.title}” in the Notebook “${name}”.${topic.brief ? ` ${topic.brief}` : ""}
Messages here come from the user: typed here, or routed from the Space's Main conversation by its organizer. Answer them fully here.${space.settings.memory ? " When something should be remembered across the Notebook, propose it with propose_memory." : ""}${instructions ? `\n\nThe Notebook's instructions:\n${instructions}` : ""}`;
			}),
		],
	});
}

// ── Both ─────────────────────────────────────────────────────────────────────

export function sharedExtension(host: () => SpaceHost) {
	const askTool = defineTool({
		name: "ask_topic",
		description: "Ask another topic a question about its history and get the answer back. Read-only: the topic's own conversation doesn't change.",
		parameters: Type.Object({ topic: Type.String({ description: "The topic's id or title" }), question: Type.String() }),
		execute: async (args, api, context) => {
			const space = host();
			const topic = space.topic(args.topic);
			if (!topic) return noTopic(space, args.topic);
			if (topic.id === String(api.conversationId)) return text("That's this topic: answer from your own history.", true);
			const answer = await askFork(api as unknown as ToolApi, topic.id, `${args.question}\n\n(This is a side question from elsewhere in the Notebook. Answer from this topic's history, briefly.)`, context);
			return text(`“${topic.title}” says:\n${answer || "(no answer)"}`);
		},
	});

	const searchTool = defineTool({
		name: "search_space",
		description: "Search every topic, Main and the memory of this Notebook for words (substring match). Returns matching lines with where they are.",
		parameters: Type.Object({ query: Type.String() }),
		execute: async (args) => {
			const hits = await host().search(args.query);
			return text(hits.length ? hits.join("\n") : `Nothing matches “${args.query}”.`);
		},
	});

	const listFiles = defineTool({
		name: "space_files_list",
		description: "List the Notebook's files (documents the user added for every topic).",
		parameters: Type.Object({}),
		execute: async () => {
			const files = host().files.list();
			return text(files.length ? files.map((f) => `${f.name} (${Math.max(1, Math.round(f.size / 1024))} KB)`).join("\n") : "The Notebook has no files.");
		},
	});

	const readFile = defineTool({
		name: "space_files_read",
		description: "Read one of the Notebook's files as text.",
		parameters: Type.Object({ name: Type.String({ description: "The file name, as space_files_list shows it" }) }),
		execute: async (args) => {
			try {
				return text(host().files.read(args.name));
			} catch (error) {
				return text((error as Error).message, true);
			}
		},
	});

	const searchFiles = defineTool({
		name: "space_files_search",
		description: "Find lines in the Notebook's files that contain some text.",
		parameters: Type.Object({ query: Type.String() }),
		execute: async (args) => {
			const hits = host().files.search(args.query);
			return text(hits.length ? hits.join("\n") : `No file mentions “${args.query}”.`);
		},
	});

	return defineExtension({
		name: "piopio-space-shared",
		tools: [askTool, searchTool, listFiles, readFile, searchFiles],
		sections: [
			section("space-memory", () => {
				const space = host();
				if (!space.settings.memory) return undefined;
				const files = space.files.list();
				return `The Notebook's memory (shared by every topic):\n${memoryPrompt(space.memoryText)}${files.length ? `\n\nThe Space has ${files.length} file${files.length === 1 ? "" : "s"} (space_files_list).` : ""}`;
			}),
		],
	});
}

/** Asks a question on a fork of the topic (owned by this call), so the topic itself doesn't change. */
async function askFork(api: ToolApi, topicId: string, question: string, context: Context): Promise<string> {
	const forkId = await api.commit(async (tx) => {
		const last = (await tx.scanEntries({ conversationId: Number(topicId) as never, order: "descending" }, 1)).items[0];
		const fork = last
			? await tx.forkConversation(Number(topicId) as never, last.id, { ownership: { kind: "task", taskId: api.taskId as never } })
			: await tx.createConversation({ ownership: { kind: "task", taskId: api.taskId as never } });
		return fork.id;
	}, context);
	const fork = (await api.conversation(forkId, context)) as { submit: Conversation["submit"] } | undefined;
	if (!fork) return "";
	const submission = await fork.submit({ type: "input", content: question, requestId: `ask:${String(api.taskId)}` } as never, context);
	const settled = (await submission.wait(context)) as { status: string; answer?: unknown };
	if (settled.status !== "done" || settled.answer === undefined) return "";
	const entry = await api.commit((tx) => tx.entry(settled.answer as never), context);
	return contentText((entry?.model?.[0] as { content?: PiContentBlock[] } | undefined)?.content?.filter((b) => b.type === "text")).trim();
}

/** The newest user message of the calling conversation (what the organizer is deciding about). */
async function lastUserText(api: ToolApi, context: Context): Promise<string> {
	return api.commit(async (tx) => {
		const page = await tx.scanEntries({ conversationId: api.conversationId, order: "descending" }, 50);
		for (const entry of page.items) {
			if (entry.kind === USER_ENTRY) return (entry.data as { text: string }).text;
			if (entry.kind === "pi.user") return contentText(entry.model?.[0]?.content as string | PiContentBlock[]);
		}
		return "";
	}, context);
}
