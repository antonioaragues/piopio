/**
 * Side conversations (docs/spec/24): a conversation gives a different subject its own conversation, linked to this
 * one, which works beside it and reports back with a note. Started when you ask for separate work (or by hand with
 * /side); offered as a card when you bring up something unrelated (`side_offer`, SD3) and proposed as a card for a
 * follow-up Piopio notices (`side_propose`); followed with `side_send`, `side_read` and `side_stop`. Notes come back
 * as `[Side]` messages.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { promptSection, type PromptEvent } from "./prompt-sections.js";

/** One of this conversation's side conversations, as its context lists it. */
export type SideLine = { id: string; title: string; state: string; branch?: string; line?: string };

/** How this conversation treats a new subject (Settings › Chat, docs/spec/24 §6). */
export type SideSettings = { onUnrelated: "ask" | "start" | "off"; propose: boolean };

export interface SideBridge {
	/** Starts one, with the brief as its first message; why it can't, as an error. */
	start(input: { title: string; brief: string; workOn?: "worktree" | "here"; project?: string }, callId?: string): Promise<SideLine>;
	/** Leaves the offer card (New conversation · Do it here) for this tool call. */
	offer(callId: string, input: { title: string; brief?: string; project?: string }): Promise<string>;
	/** Leaves a proposal card (Start · Dismiss) for this tool call. */
	propose(callId: string, input: { title: string; brief: string; why: string; project?: string }): Promise<string>;
	dismiss(id: string): Promise<string>;
	settings(): SideSettings;
	/** Your projects' names, for one that's plainly about another project (SCQ5, 26 CL11). */
	projects(): string[];
	send(id: string, message: string): Promise<string>;
	read(id: string, from?: number): Promise<string>;
	stop(id: string): Promise<string>;
	/** This conversation's side conversations now, for each turn's context. */
	list(): SideLine[];
}

const text = (t: string, isError = false) => ({ content: [{ type: "text" as const, text: t }], details: {}, ...(isError ? { isError: true } : {}) });

/** What the model is told (docs/spec/24 §3, §5), with this conversation's side conversations. */
export function sidePrompt(lines: readonly SideLine[], settings: SideSettings = { onUnrelated: "off", propose: false }, projects: readonly string[] = []): string {
	const unrelated =
		settings.onUnrelated === "ask"
			? `\n- When the user's message is a new task (see below), your first action is side_offer with a short title and, as its brief, the part of their words that is the new task; then stop and wait. Don't read files or start the work first. They choose New conversation, or Do it here (then you do it here).`
			: settings.onUnrelated === "start"
				? `\n- When the user's message is a new task (see below), your first action is side_start with a title and a brief; tell them in a line that it started, and go on with anything else they asked.`
				: "";
	const newTask = settings.onUnrelated === "off" ? "" : `\n- A new task is unrelated work that a fresh conversation would do just as well from the user's words alone: it builds on nothing done, found or decided here. Everything else stays here: a correction, a follow-up, a question, the next iteration of the work here, going ahead with what was just investigated ("ok, do it"), and anything a few tool calls settle, whatever it's about. When unsure, it stays: a wrong offer stops the user, a wrong stay only makes this conversation a little longer.`;
	const propose = settings.propose
		? `\n- When you notice work outside what the user asked (a fix spotted in passing, the follow-up your own answer recommends), leave it as a card with side_propose: a title, a brief, and why in one line. At most three per turn, none twice, never for what you're about to do anyway. Work that only acts on what this conversation just found (the fix for what you just diagnosed) isn't proposed away: ask about it here instead. side_dismiss withdraws a proposal that went stale.`
		: "";
	const elsewhere = projects.length ? `\n- A task plainly about one of the user's projects (${projects.join(", ")}) can go there: give its name as project, and the side conversation works in that project's folder.` : "";
	const rules = `- A side conversation is a conversation of its own, linked to this one, for a task of its own. It works beside this one and reports back.
- Start one with side_start when the user asks for separate work in their message ("do that in its own conversation", "in the background", "in parallel", "separately"), or by /side. Give a short title and a brief: what to do, which files or area, and what done looks like, in your own words. The new conversation knows nothing of this one; don't write "as discussed". It can read this conversation with read_conversation if it needs the background.${unrelated}${newTask}${propose}${elsewhere}
- A piece of the task at hand is never a side conversation, however large: searching widely, the independent parts of one change, testing or reviewing what was just built. Do those here (a wide search can go to task, which only reads).
- Messages that start with [Side] are reports from your side conversations, not the user. A report isn't proof: before telling the user something is done, check it with side_read (or the diff on its branch). When a report unblocks a step of what the user asked you here, carry on with it and say so in a line; otherwise report in a line or two. Start nothing the user didn't ask for.
- side_send writes to one that has the context instead of starting another; side_stop stops its running turn. Its branch isn't in this checkout until the user merges it; merge only on their word.
${lines.length ? `Side conversations now:\n${lines.map((l) => `- ${l.id}: ${l.title} · ${l.state}${l.branch ? ` · ${l.branch}` : ""}${l.line ? ` · ${l.line}` : ""}`).join("\n")}` : ""}`;
	return rules;
}

export function sideExtension(bridge: SideBridge): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			promptSection(event as unknown as PromptEvent, "side-conversations", sidePrompt(bridge.list(), bridge.settings(), bridge.projects()));
			return undefined;
		});
		const run = async (work: () => Promise<string>) => {
			try {
				return text(await work());
			} catch (error) {
				return text((error as Error).message, true);
			}
		};
		pi.registerTool(
			defineTool({
				name: "side_start",
				label: "Side conversation",
				description: "Start a side conversation: a conversation of its own, linked to this one, for a task of its own the user asked to be done separately. It starts at once and reports back here when it's done or needs the user. Returns its id.",
				promptSnippet: "side_start: give a separate task its own linked conversation",
				parameters: Type.Object({
					title: Type.String({ description: "A few words: what it's for" }),
					brief: Type.String({ description: "What to do, where, and what done looks like; it knows nothing of this conversation" }),
					workOn: Type.Optional(Type.Union([Type.Literal("worktree"), Type.Literal("here")], { description: "In a git project: its own worktree (default when it will change files) or this folder" })),
					project: Type.Optional(Type.String({ description: "Another of the user's projects, by name, when the task is plainly about it" })),
				}),
				async execute(callId, params) {
					return run(async () => {
						const s = await bridge.start(params, callId);
						return `Started ${s.id} “${s.title}”${s.state === "queued" ? " (queued: others are running)" : ""}${s.branch ? ` on ${s.branch}` : ""}. Tell the user in a line; its report comes back here.`;
					});
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "side_offer",
				label: "Offer a side conversation",
				description: "Offer to give a new task its own conversation: shows a card where the user chooses New conversation or Do it here. Call it first, before any work; then end your turn. The card asks: don't restate its choices or add questions of your own.",
				promptSnippet: "side_offer: offer a new task its own conversation",
				parameters: Type.Object({
					title: Type.String({ description: "A few words: the new task" }),
					brief: Type.Optional(Type.String({ description: "The part of the user's words that is the new task; default their whole message" })),
					project: Type.Optional(Type.String({ description: "Another of the user's projects, by name, when the task is plainly about it" })),
				}),
				async execute(callId, params) {
					return run(() => bridge.offer(callId, params));
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "side_propose",
				label: "Propose a side conversation",
				description: "Leave a card proposing a follow-up you noticed, outside what the user asked: they may start it, as its own conversation, or dismiss it. It expires in a week. Returns at once.",
				promptSnippet: "side_propose: propose a follow-up as a card",
				parameters: Type.Object({
					title: Type.String({ description: "A few words" }),
					brief: Type.String({ description: "What to do, where, and what done looks like; it knows nothing of this conversation" }),
					why: Type.String({ description: "One line: why it's worth doing" }),
					project: Type.Optional(Type.String({ description: "Another of the user's projects, by name, when it's plainly about it" })),
				}),
				async execute(callId, params) {
					return run(() => bridge.propose(callId, params));
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "side_dismiss",
				label: "Withdraw a proposal",
				description: "Withdraw a proposal you made with side_propose that went stale (done here after all, or replaced by a better one), by its id.",
				promptSnippet: "side_dismiss: withdraw a stale proposal",
				parameters: Type.Object({ id: Type.String() }),
				async execute(_id, params) {
					return run(() => bridge.dismiss(params.id));
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "side_send",
				label: "Message a side conversation",
				description: "Write to one of this conversation's side conversations: a follow-up, a correction, more context. Queued if it's busy.",
				promptSnippet: "side_send: write to a side conversation",
				parameters: Type.Object({ id: Type.String(), message: Type.String() }),
				async execute(_id, params) {
					return run(() => bridge.send(params.id, params.message));
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "side_read",
				label: "Read a side conversation",
				description: "One of this conversation's side conversations: its state, branch, changed files and last answer, as text. Long answers are cut; `from` reads on.",
				promptSnippet: "side_read: read a side conversation",
				parameters: Type.Object({ id: Type.String(), from: Type.Optional(Type.Number({ description: "A character offset in its last answer" })) }),
				async execute(_id, params) {
					return run(() => bridge.read(params.id, params.from));
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "side_stop",
				label: "Stop a side conversation",
				description: "Stop the running turn of one of this conversation's side conversations.",
				promptSnippet: "side_stop: stop a side conversation's turn",
				parameters: Type.Object({ id: Type.String() }),
				async execute(_id, params) {
					return run(() => bridge.stop(params.id));
				},
			}),
		);
	};
}
