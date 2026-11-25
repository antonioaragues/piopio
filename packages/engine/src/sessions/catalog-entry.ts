/**
 * What the engine keeps about each conversation, beyond what clients see (`SessionSummary`): the catalog's entries,
 * saved in catalog.json by Sessions. The parts of Sessions that live in src/sessions/ read and change these through
 * their host, and Sessions saves.
 */
import type { ApprovalMode, ContainerRef, SessionSummary } from "@piopio/protocol";
import type { Automation } from "../automations/model.js";
import type { Segment } from "../runtimes/segments.js";

export type CatalogEntry = SessionSummary & {
	thinking?: string;
	file?: string;
	sessionFile?: string;
	/** A conversation run by a coding agent (docs/spec/31): Piopio's copy of its transcript. */
	agentFile?: string;
	/** Earlier parts of a conversation that changed who runs it (docs/spec/31 CA7), oldest first. */
	segments?: Segment[];
	/** The current part hasn't sent its first message yet: it carries the summary of the earlier ones. */
	handoff?: boolean;
	/** A review by an agent (05-build "Review by an agent"): the session whose `review` its findings go to. */
	reviewFor?: ContainerRef;
	/** Chats moved from pi-durable (2026-11-15): the old SQLite file, kept until the chat is deleted. */
	migratedFrom?: string;
	/** Original CLI file for recovered history; avoid importing a duplicate after restore. */
	restoredFromSessionFile?: string;
	/** The pi session file was seen on disk, so its disappearance means it was deleted. */
	onDisk?: boolean;
	/** Chats before 2026-11-15: the branch a pi-durable chat showed (read once, by the migration). */
	branches?: { active?: string };
	web?: boolean;
	/** Build: the session's approval mode (new sessions take their project's). */
	approvalMode?: ApprovalMode;
	/** Build: plan mode (piopio-plan). */
	planMode?: boolean;
	/** Agents: the definition folder. */
	agentFolder?: string;
	/**
	 * Agents in your cloud (docs/spec/30 K1): when it went up, and its automations that need this Mac (a folder, an
	 * email, a URL), kept here off until it comes back.
	 */
	cloud?: { deployedAt: string; parked?: Automation[] };
	/** A side conversation (docs/spec/24): its brief while queued, and who drove its last turn (a turn you drove doesn't wake its parent). */
	sideBrief?: string;
	sideBy?: "parent" | "you";
	/** A conversation with side conversations: turns their notes woke in a row since your last message, and notes waiting for a sibling. */
	sideWoke?: number;
	sidePending?: string[];
	/** Offer cards this conversation left (by tool call id), answered or not; and its proposals' briefs. */
	sideOffers?: Record<string, { title: string; brief?: string; project?: string; answered?: "new" | "here" }>;
	sideBriefs?: Record<string, string>;
	/** /learn saves (docs/spec/14 M5), by tool call: what each wrote, so Undo takes exactly that back. */
	learnUndo?: Record<string, { project?: string; file?: string; created?: boolean; lines: string[]; facts: string[]; skillsMade?: string[]; skillsBefore?: { path: string; text: string }[] }>;
	/** Its pull request's comments already seen, and the head whose failing checks it was told about (docs/spec/17 §5). */
	prSeen?: string[];
	prFailedSha?: string;
};
