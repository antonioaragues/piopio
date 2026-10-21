/**
 * The Agent Definition (docs/spec/06-agents §2): `agent.json` (this schema, v1) plus `instructions.md`, in a folder
 * the app keeps as a git repo. Secrets are referenced as `secret:NAME` and never stored in the folder (AD2).
 * `validate` runs the schema and the semantic checks of AD3; errors carry a path for the editor to show inline.
 */
import { Type, type Static } from "typebox";
import { Value } from "typebox/value";

const SecretRef = Type.String({ pattern: "^secret:[A-Za-z0-9_]+$" });

export const BUILTIN_TOOLS = ["web_search", "web_fetch", "memory", "schedule", "send_message", "http_request", "codemode", "files"] as const;

export const Contact = Type.Object({
	id: Type.String({ pattern: "^[a-z0-9_-]+$" }),
	name: Type.String({ minLength: 1 }),
	role: Type.Union([Type.Literal("owner"), Type.Literal("contact")]),
	channels: Type.Optional(Type.Object({ telegram: Type.Optional(Type.String()), whatsapp: Type.Optional(Type.String()) })),
	preferred: Type.Optional(Type.Union([Type.Literal("inapp"), Type.Literal("telegram"), Type.Literal("whatsapp")])),
	/** What the agent should know about this person, from the owner. */
	notes: Type.Optional(Type.String()),
});
export type Contact = Static<typeof Contact>;

export const Schedule = Type.Object({
	id: Type.String({ pattern: "^[a-z0-9_-]+$" }),
	cron: Type.String(),
	tz: Type.Optional(Type.String()),
	prompt: Type.String({ minLength: 1 }),
	deliverTo: Type.Optional(Type.String()),
});

export const AgentDefinition = Type.Object({
	version: Type.Literal(1),
	id: Type.String({ pattern: "^agt_[A-Za-z0-9]+$" }),
	slug: Type.String({ pattern: "^[a-z0-9][a-z0-9-]*$" }),
	name: Type.String({ minLength: 1, maxLength: 60 }),
	avatar: Type.Optional(Type.String({ maxLength: 8 })),
	/** IANA time zone for schedules, quiet hours and daily limits. Default: the machine's. */
	timezone: Type.Optional(Type.String()),
	/** One line for the sidebar. */
	description: Type.Optional(Type.String({ maxLength: 120 })),
	models: Type.Object({ default: Type.String({ minLength: 1 }), utility: Type.Optional(Type.String()) }),
	thinking: Type.Optional(Type.Union([Type.Literal("off"), Type.Literal("low"), Type.Literal("medium"), Type.Literal("high")])),
	tools: Type.Object({
		builtin: Type.Array(
			Type.Union([
				Type.Literal("web_search"),
				Type.Literal("web_fetch"),
				Type.Literal("memory"),
				Type.Literal("schedule"),
				Type.Literal("send_message"),
				Type.Literal("http_request"),
				Type.Literal("codemode"),
				Type.Literal("files"),
			]),
		),
		mcp: Type.Optional(Type.Array(Type.Object({ name: Type.String({ pattern: "^[A-Za-z0-9_-]+$" }), url: Type.String(), auth: Type.Optional(SecretRef) }))),
		/** Apple apps on this Mac (§4.1 NB1), served by the Piopio app. */
		apple: Type.Optional(Type.Array(Type.Union([Type.Literal("reminders"), Type.Literal("calendar"), Type.Literal("contacts"), Type.Literal("notes"), Type.Literal("music")]))),
		/** Shortcuts the agent may run, by name. */
		shortcuts: Type.Optional(Type.Array(Type.String({ minLength: 1 }))),
		agents: Type.Optional(Type.Array(Type.String())),
	}),
	contacts: Type.Array(Contact),
	channels: Type.Optional(
		Type.Object({
			telegram: Type.Optional(Type.Object({ bot: SecretRef })),
			whatsapp: Type.Optional(Type.Object({ phoneNumberId: Type.String(), token: SecretRef })),
		}),
	),
	schedules: Type.Optional(Type.Array(Schedule)),
	heartbeat: Type.Optional(Type.Object({ every: Type.String({ pattern: "^[0-9]+[mh]$" }), activeHours: Type.Optional(Type.String({ pattern: "^[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]$" })), prompt: Type.String() })),
	triggers: Type.Optional(Type.Array(Type.Object({ id: Type.String({ pattern: "^[a-z0-9_-]+$" }), type: Type.Literal("webhook"), prompt: Type.String() }))),
	policies: Type.Optional(
		Type.Object({
			quietHours: Type.Optional(Type.String({ pattern: "^[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]$" })),
			maxOutboundPerDay: Type.Optional(Type.Integer({ minimum: 0 })),
			/** The same cap for each person. */
			maxOutboundPerContactPerDay: Type.Optional(Type.Integer({ minimum: 0 })),
			/** Messages to one other agent per hour (AA4, default 30), and what one exchange between agents may cost (default $0.50). */
			agentMessagesPerHour: Type.Optional(Type.Integer({ minimum: 0 })),
			traceBudgetUsd: Type.Optional(Type.Number({ minimum: 0 })),
			/** Messages the agent marks urgent go out during quiet hours (PR4). */
			urgentBypassesQuiet: Type.Optional(Type.Boolean()),
			budgetUsdPerMonth: Type.Optional(Type.Number({ minimum: 0 })),
			requireApproval: Type.Optional(Type.Array(Type.String())),
			unknownSenders: Type.Optional(Type.Union([Type.Literal("ignore"), Type.Literal("reply_canned"), Type.Literal("ask_owner")])),
		}),
	),
	/** Agents that may write to this one (ids or slugs; AA1). Unset: every agent of the owner. */
	acceptFrom: Type.Optional(Type.Array(Type.String())),
	/** Partitions other agents may read (AA6), e.g. `{ "agt_x": ["shared"] }`. */
	shareMemory: Type.Optional(Type.Record(Type.String(), Type.Array(Type.String()))),
	/** Where long-term memory lives: "builtin" (default) or an MCP memory provider's id (07-shared §6.2). */
	memory: Type.Optional(Type.Object({ provider: Type.String() })),
});
export type AgentDefinition = Static<typeof AgentDefinition>;

export type DefinitionError = { path: string; message: string };

/** Schema errors, then the semantic checks of AD3. `knownAgents`: the ids an agent may reference. */
export function validate(value: unknown, options: { knownAgents?: readonly string[]; knownModels?: (id: string) => boolean } = {}): DefinitionError[] {
	const errors: DefinitionError[] = [...Value.Errors(AgentDefinition, value)].slice(0, 20).map((e) => ({ path: e.instancePath || "/", message: e.message }));
	if (errors.length) return errors;
	const def = value as AgentDefinition;
	const ids = new Set<string>();
	def.contacts.forEach((c, i) => {
		if (ids.has(c.id)) errors.push({ path: `/contacts/${i}/id`, message: `Two contacts have the id “${c.id}”.` });
		ids.add(c.id);
	});
	const owners = def.contacts.filter((c) => c.role === "owner");
	if (owners.length !== 1) errors.push({ path: "/contacts", message: owners.length ? "Only one contact can be the owner." : "Add the owner: the person the agent works for." });
	def.contacts.forEach((c, i) => {
		if (c.channels?.whatsapp && !/^\+[1-9][0-9]{6,14}$/.test(c.channels.whatsapp)) errors.push({ path: `/contacts/${i}/channels/whatsapp`, message: "A WhatsApp number in international format, like +34600111222." });
		if (c.channels?.telegram && !/^-?[0-9]{4,20}$/.test(c.channels.telegram)) errors.push({ path: `/contacts/${i}/channels/telegram`, message: "A Telegram chat id: digits only." });
	});
	(def.schedules ?? []).forEach((s, i) => {
		const cron = cronError(s.cron);
		if (cron) errors.push({ path: `/schedules/${i}/cron`, message: cron });
		if (s.deliverTo && !ids.has(s.deliverTo)) errors.push({ path: `/schedules/${i}/deliverTo`, message: `No contact “${s.deliverTo}”.` });
	});
	const scheduleIds = new Set<string>();
	(def.schedules ?? []).forEach((s, i) => {
		if (scheduleIds.has(s.id)) errors.push({ path: `/schedules/${i}/id`, message: `Two schedules have the id “${s.id}”.` });
		scheduleIds.add(s.id);
	});
	if (options.knownAgents) {
		(def.tools.agents ?? []).forEach((a, i) => {
			if (a === def.id) errors.push({ path: `/tools/agents/${i}`, message: "An agent can't contact itself." });
			else if (!options.knownAgents!.includes(a)) errors.push({ path: `/tools/agents/${i}`, message: `No agent “${a}”.` });
		});
	}
	if (options.knownModels && !options.knownModels(def.models.default)) errors.push({ path: "/models/default", message: `Unknown model “${def.models.default}”.` });
	return errors;
}

const CRON_FIELDS: [string, number, number][] = [
	["minute", 0, 59],
	["hour", 0, 23],
	["day of month", 1, 31],
	["month", 1, 12],
	["day of week", 0, 7],
];

/** Five fields (minute hour day month weekday) of numbers, ranges, lists, steps and `*`; undefined when valid. */
export function cronError(cron: string): string | undefined {
	const fields = cron.trim().split(/\s+/);
	if (fields.length !== 5) return "A cron has five fields: minute hour day month weekday (e.g. “0 8 * * 1-5”).";
	for (const [i, field] of fields.entries()) {
		const [name, min, max] = CRON_FIELDS[i]!;
		for (const part of field.split(",")) {
			const m = /^(\*|(\d+)(?:-(\d+))?)(?:\/(\d+))?$/.exec(part);
			if (!m) return `The ${name} field “${field}” isn't valid.`;
			for (const n of [m[2], m[3]]) if (n !== undefined && (Number(n) < min || Number(n) > max)) return `The ${name} must be between ${min} and ${max}.`;
			if (m[4] !== undefined && Number(m[4]) === 0) return `A step in the ${name} field can't be 0.`;
		}
	}
	return undefined;
}
