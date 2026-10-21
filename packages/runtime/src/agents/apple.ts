/**
 * Apple apps as tools (docs/spec/06-agents §4.1). The engine can't use Apple frameworks, so these tools only
 * describe themselves; a call goes to the Mac app (`app.tool`, 03-engine-protocol §3.12), which runs it with the
 * user's permissions and answers with what the model reads, a result card, and the call that undoes it (§4.2).
 * Groups are opted into per agent (`tools.apple`, NB1); reading is free, changes follow the approval policy (§9).
 * With no app connected (background mode, app closed) the tools say so (NB2).
 */
import { Type, type TSchema } from "@earendil-works/pi-ai";
import { defineTool, type JsonObject } from "@earendil-works/pi-durable";
import type { ResultCard } from "./safety.js";

export type AppleGroup = "reminders" | "calendar" | "contacts" | "notes" | "music" | "shortcuts";

/** What the Mac app answers (`app.tool`). */
export type AppToolResult = { ok: boolean; output: string; card?: ResultCard; undo?: { name: string; args: unknown; title: string } };

export interface AppleHost {
	/** Runs a call in the Mac app; throws `AppUnavailable` when no app is connected. */
	call(name: string, args: JsonObject, conversationId: string): Promise<AppToolResult>;
	/** Records how to undo a change; returns the id the card carries. */
	recordUndo(undo: { name: string; args: unknown; title: string }, conversationId: string): Promise<string>;
}

export class AppUnavailable extends Error {}

const when = (what: string) => Type.String({ description: `${what}: an ISO date-time in local time (2026-10-23T09:00) or a date (2026-10-23)` });
const opt = <T extends TSchema>(t: T) => Type.Optional(t);

/** Every tool, by group. Names are what `requireApproval` rules match (`apple_reminders_create`, `apple_*`). */
export const APPLE_TOOLS: { group: AppleGroup; name: string; description: string; parameters: TSchema }[] = [
	{ group: "reminders", name: "apple_reminders_lists", description: "The owner's reminder lists in Apple Reminders.", parameters: Type.Object({}) },
	{
		group: "reminders",
		name: "apple_reminders_list",
		description: "Reminders from Apple Reminders: open ones by default, or due today, overdue or completed; optionally from one list.",
		parameters: Type.Object({ list: opt(Type.String()), filter: opt(Type.Union([Type.Literal("open"), Type.Literal("due"), Type.Literal("overdue"), Type.Literal("completed")])), limit: opt(Type.Integer({ minimum: 1, maximum: 200 })) }),
	},
	{
		group: "reminders",
		name: "apple_reminders_create",
		description: "Create a reminder in Apple Reminders (the default list unless given).",
		parameters: Type.Object({ title: Type.String(), list: opt(Type.String()), due: opt(when("When it's due")), notes: opt(Type.String()), priority: opt(Type.Union([Type.Literal("high"), Type.Literal("medium"), Type.Literal("low")])) }),
	},
	{ group: "reminders", name: "apple_reminders_complete", description: "Tick a reminder done (or not done) by its id.", parameters: Type.Object({ id: Type.String(), completed: opt(Type.Boolean()) }) },
	{
		group: "reminders",
		name: "apple_reminders_update",
		description: "Change a reminder: reschedule it, rename it, move it to another list, change its notes.",
		parameters: Type.Object({ id: Type.String(), title: opt(Type.String()), due: opt(when("New due date")), list: opt(Type.String()), notes: opt(Type.String()) }),
	},
	{ group: "calendar", name: "apple_calendar_calendars", description: "The owner's calendars in Apple Calendar.", parameters: Type.Object({}) },
	{
		group: "calendar",
		name: "apple_calendar_events",
		description: "Events in Apple Calendar between two moments (busy times included), optionally in one calendar.",
		parameters: Type.Object({ from: when("From"), to: when("To"), calendar: opt(Type.String()) }),
	},
	{
		group: "calendar",
		name: "apple_calendar_create",
		description: "Create an event in Apple Calendar (the default calendar unless given).",
		parameters: Type.Object({ title: Type.String(), start: when("Start"), end: when("End"), calendar: opt(Type.String()), location: opt(Type.String()), notes: opt(Type.String()) }),
	},
	{
		group: "calendar",
		name: "apple_calendar_update",
		description: "Move or change an event by its id.",
		parameters: Type.Object({ id: Type.String(), title: opt(Type.String()), start: opt(when("New start")), end: opt(when("New end")), location: opt(Type.String()) }),
	},
	{ group: "contacts", name: "apple_contacts_find", description: "Find people in the owner's Contacts by name, email or phone: names, emails, phones, birthday.", parameters: Type.Object({ query: Type.String() }) },
	{ group: "notes", name: "apple_notes_search", description: "Search Apple Notes by words in the title or body.", parameters: Type.Object({ query: Type.String(), limit: opt(Type.Integer({ minimum: 1, maximum: 50 })) }) },
	{ group: "notes", name: "apple_notes_read", description: "Read a note from Apple Notes by its id.", parameters: Type.Object({ id: Type.String() }) },
	{ group: "notes", name: "apple_notes_create", description: "Create a note in Apple Notes.", parameters: Type.Object({ title: Type.String(), body: Type.String(), folder: opt(Type.String()) }) },
	{ group: "notes", name: "apple_notes_append", description: "Add text at the end of a note.", parameters: Type.Object({ id: Type.String(), text: Type.String() }) },
	{ group: "music", name: "apple_music_now", description: "What Apple Music is playing.", parameters: Type.Object({}) },
	{ group: "music", name: "apple_music_play", description: "Play something from the owner's Apple Music library: a song, album, artist or playlist name.", parameters: Type.Object({ query: Type.String() }) },
	{
		group: "music",
		name: "apple_music_control",
		description: "Play, pause, skip or go back in Apple Music.",
		parameters: Type.Object({ action: Type.Union([Type.Literal("play"), Type.Literal("pause"), Type.Literal("next"), Type.Literal("previous")]) }),
	},
	{ group: "shortcuts", name: "shortcuts_run", description: "Run one of the owner's Shortcuts by name (only those allowed in your definition), with optional text input.", parameters: Type.Object({ name: Type.String(), input: opt(Type.String()) }) },
];

export const appleGroupOf = (name: string): AppleGroup | undefined => APPLE_TOOLS.find((t) => t.name === name)?.group;

/** The tools, executed through the host. */
export function appleTools(host: AppleHost) {
	return APPLE_TOOLS.map((spec) =>
		defineTool({
			name: spec.name,
			description: spec.description,
			parameters: spec.parameters,
			execute: async (args, api) => {
				const conversationId = String(api.conversationId);
				let result: AppToolResult;
				try {
					result = await host.call(spec.name, args as JsonObject, conversationId);
				} catch (error) {
					const text = error instanceof AppUnavailable ? "Piopio isn't open on the Mac, so Apple apps can't be reached now. Try later, or tell the owner." : `The Mac app couldn't do it: ${(error as Error).message}`;
					return { output: [{ type: "text", text }], isError: true };
				}
				if (!result.ok) return { output: [{ type: "text", text: result.output }], isError: true };
				const undo = result.undo ? await host.recordUndo(result.undo, conversationId) : undefined;
				return { output: [{ type: "text", text: result.output }], details: { ...(result.card ? { card: result.card } : {}), ...(undo ? { undo } : {}) } as never };
			},
		}),
	);
}
