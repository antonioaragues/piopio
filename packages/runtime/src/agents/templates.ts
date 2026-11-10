/**
 * Agent templates (docs/spec/06-agents AD4). Each fills the definition's persona, tools and schedules; the owner's
 * name and the ids come from the caller. Avatars are "symbol:<SF Symbol>" (line icons in the app, no emoji).
 */
import type { AgentDefinition } from "./definition.js";

export type AgentTemplate = {
	id: string;
	name: string;
	avatar: string;
	description: string;
	instructions: string;
	definition: Pick<AgentDefinition, "tools"> & Partial<Pick<AgentDefinition, "schedules" | "heartbeat" | "policies" | "thinking">>;
};

export const TEMPLATES: AgentTemplate[] = [
	{
		id: "personal-assistant",
		name: "Personal assistant",
		avatar: "symbol:calendar",
		description: "Keeps track of what you tell it and reminds you",
		instructions: "You are {owner}'s personal assistant. Be brief and practical. Remember what matters about {owner}'s plans, people and preferences, and use it. When something is unclear, ask one short question.",
		definition: { tools: { builtin: ["web_search", "web_fetch", "memory", "schedule", "send_message"] }, policies: { quietHours: "22:30-07:30", maxOutboundPerDay: 20, unknownSenders: "ask_owner" } },
	},
	{
		id: "daily-briefing",
		name: "Daily briefing",
		avatar: "symbol:sun.max",
		description: "A short morning summary of what's ahead",
		instructions: "Every morning you write {owner} a short briefing: what's planned today, what was left open yesterday, and anything worth knowing (weather, news they follow). Five bullet points at most.",
		definition: { tools: { builtin: ["web_search", "web_fetch", "memory", "schedule", "send_message"] }, schedules: [{ id: "morning", cron: "0 8 * * 1-5", tz: "Europe/Madrid", prompt: "Write today's briefing.", deliverTo: "owner" }] },
	},
	{
		id: "habit-coach",
		name: "Habit coach",
		avatar: "symbol:figure.run",
		description: "Checks in on your habits and keeps you honest",
		instructions: "You coach {owner} on the habits they choose. Check in kindly, keep a log in memory, notice streaks and slips, and suggest one small next step. Never lecture.",
		definition: { tools: { builtin: ["memory", "schedule", "send_message"] }, schedules: [{ id: "evening-check", cron: "0 21 * * *", tz: "Europe/Madrid", prompt: "Check in on today's habits.", deliverTo: "owner" }] },
	},
	{
		id: "family-helper",
		name: "Family helper",
		avatar: "symbol:house",
		description: "Shared lists and plans for the people at home",
		instructions: "You help {owner}'s household: shopping lists, plans and who does what. Several people may talk to you; keep each person's details to themselves unless they're meant to be shared.",
		definition: { tools: { builtin: ["memory", "schedule", "send_message"] }, policies: { unknownSenders: "ask_owner" } },
	},
	{
		id: "research-watcher",
		name: "Research watcher",
		avatar: "symbol:binoculars",
		description: "Follows a subject and reports what's new",
		instructions: "You follow the subjects {owner} asks about. Search for what's new, keep notes in memory so you don't repeat yourself, and report only what's genuinely new, with links.",
		definition: { tools: { builtin: ["web_search", "web_fetch", "memory", "schedule", "send_message"] }, schedules: [{ id: "weekly", cron: "0 9 * * 1", tz: "Europe/Madrid", prompt: "Look for what's new on the subjects you follow and report it.", deliverTo: "owner" }] },
	},
];

/** The prompt a schedule set at creation runs with, when the template has none of its own. */
const SCHEDULED_PROMPT = "It's your scheduled time. Do what your instructions ask for it.";

/**
 * A new definition: from a template (or from scratch), for `owner`. `instructions` replaces the template's (the
 * start page's text); `schedule` is a cron that replaces the template's first schedule, or null for none.
 */
export function newDefinition(options: { id: string; slug: string; name: string; owner: string; model: string; template?: string; avatar?: string; instructions?: string; schedule?: string | null; timezone?: string }): { definition: AgentDefinition; instructions: string } {
	const t = TEMPLATES.find((x) => x.id === options.template);
	const first = t?.definition.schedules?.[0];
	const schedules =
		options.schedule === undefined
			? t?.definition.schedules
			: options.schedule === null
				? undefined
				: [{ id: first?.id ?? "scheduled", cron: options.schedule, tz: options.timezone ?? first?.tz ?? Intl.DateTimeFormat().resolvedOptions().timeZone, prompt: first?.prompt ?? SCHEDULED_PROMPT, deliverTo: "owner" }, ...(t?.definition.schedules?.slice(1) ?? [])];
	const definition: AgentDefinition = {
		version: 1,
		id: options.id,
		slug: options.slug,
		name: options.name,
		...(options.avatar ?? t?.avatar ? { avatar: options.avatar ?? t!.avatar } : {}),
		...(t ? { description: t.description } : {}),
		models: { default: options.model },
		// Every agent can set its own routines and message you (docs/spec/19 S3): proactive by asking, from the start.
		tools: t?.definition.tools ?? { builtin: ["web_search", "web_fetch", "memory", "schedule", "send_message"] },
		contacts: [{ id: "owner", name: options.owner, role: "owner", preferred: "inapp" }],
		...(schedules?.length ? { schedules } : {}),
		...(t?.definition.policies ? { policies: t.definition.policies } : {}),
	};
	const body = options.instructions?.trim() || t?.instructions || "You are {owner}'s agent.";
	const instructions = `# ${options.name}\n\n${body.replaceAll("{owner}", options.owner)}\n`;
	return { definition, instructions };
}
