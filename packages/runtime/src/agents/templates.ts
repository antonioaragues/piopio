/**
 * Agent templates (docs/spec/06-agents AD4). Each fills the definition's persona, tools and schedules; the owner's
 * name and the ids come from the caller.
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
		avatar: "🗓️",
		description: "Keeps track of what you tell it and reminds you",
		instructions: "You are {owner}'s personal assistant. Be brief and practical. Remember what matters about {owner}'s plans, people and preferences, and use it. When something is unclear, ask one short question.",
		definition: { tools: { builtin: ["web_search", "web_fetch", "memory", "schedule", "send_message"] }, policies: { quietHours: "22:30-07:30", maxOutboundPerDay: 20, unknownSenders: "ask_owner" } },
	},
	{
		id: "daily-briefing",
		name: "Daily briefing",
		avatar: "☀️",
		description: "A short morning summary of what's ahead",
		instructions: "Every morning you write {owner} a short briefing: what's planned today, what was left open yesterday, and anything worth knowing (weather, news they follow). Five bullet points at most.",
		definition: { tools: { builtin: ["web_search", "web_fetch", "memory", "send_message"] }, schedules: [{ id: "morning", cron: "0 8 * * 1-5", tz: "Europe/Madrid", prompt: "Write today's briefing.", deliverTo: "owner" }] },
	},
	{
		id: "habit-coach",
		name: "Habit coach",
		avatar: "🏃",
		description: "Checks in on your habits and keeps you honest",
		instructions: "You coach {owner} on the habits they choose. Check in kindly, keep a log in memory, notice streaks and slips, and suggest one small next step. Never lecture.",
		definition: { tools: { builtin: ["memory", "schedule", "send_message"] }, schedules: [{ id: "evening-check", cron: "0 21 * * *", tz: "Europe/Madrid", prompt: "Check in on today's habits.", deliverTo: "owner" }] },
	},
	{
		id: "family-helper",
		name: "Family helper",
		avatar: "🏡",
		description: "Shared lists and plans for the people at home",
		instructions: "You help {owner}'s household: shopping lists, plans and who does what. Several people may talk to you; keep each person's details to themselves unless they're meant to be shared.",
		definition: { tools: { builtin: ["memory", "schedule", "send_message"] }, policies: { unknownSenders: "ask_owner" } },
	},
	{
		id: "research-watcher",
		name: "Research watcher",
		avatar: "🔭",
		description: "Follows a subject and reports what's new",
		instructions: "You follow the subjects {owner} asks about. Search for what's new, keep notes in memory so you don't repeat yourself, and report only what's genuinely new, with links.",
		definition: { tools: { builtin: ["web_search", "web_fetch", "memory", "send_message"] }, schedules: [{ id: "weekly", cron: "0 9 * * 1", tz: "Europe/Madrid", prompt: "Look for what's new on the subjects you follow and report it.", deliverTo: "owner" }] },
	},
];

/** A new definition: from a template (or from scratch), for `owner`. */
export function newDefinition(options: { id: string; slug: string; name: string; owner: string; model: string; template?: string; avatar?: string }): { definition: AgentDefinition; instructions: string } {
	const t = TEMPLATES.find((x) => x.id === options.template);
	const definition: AgentDefinition = {
		version: 1,
		id: options.id,
		slug: options.slug,
		name: options.name,
		...(options.avatar ?? t?.avatar ? { avatar: options.avatar ?? t!.avatar } : {}),
		...(t ? { description: t.description } : {}),
		models: { default: options.model },
		tools: t?.definition.tools ?? { builtin: ["web_search", "web_fetch", "memory"] },
		contacts: [{ id: "owner", name: options.owner, role: "owner", preferred: "inapp" }],
		...(t?.definition.schedules ? { schedules: t.definition.schedules } : {}),
		...(t?.definition.policies ? { policies: t.definition.policies } : {}),
	};
	const instructions = `# ${options.name}\n\n${(t?.instructions ?? "You are {owner}'s agent.").replaceAll("{owner}", options.owner)}\n`;
	return { definition, instructions };
}
