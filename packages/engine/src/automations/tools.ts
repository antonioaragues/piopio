/**
 * Making automations by asking (docs/spec/27 AU4–AU5). Piopio's tools, in every conversation with Piopio (a
 * project's or a loose one): it may make one for any runner, and in a project it works there by default. An agent's
 * tools live in the runtime (`automate` and friends); here is the bridge they call, which keeps them to the agent
 * itself. Both answer in words the model can act on, and say what to do instead when a rule refuses.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { JsonObject } from "@earendil-works/pi-durable";
import type { AutomationsBridge, AutomationSummary, AutomationToolInput } from "@piopio/runtime";
import { Type } from "typebox";
import { EngineError } from "../models.js";
import { PIOPIO, whenLabel, type Automation, type ResultTo, type Trigger } from "./model.js";
import type { AgentInfo, AutomationInput, Automations } from "./service.js";
import { promptSection, type PromptEvent } from "../tools/prompt-sections.js";

/** The tools' names: Piopio's and an agent's are the same words. */
export const AUTOMATION_TOOLS = ["automate", "list_automations", "change_automation", "cancel_automation"];

/** `next` off leaves out the next run's time: the one part of a line that changes each time it fires. */
const describe = (s: AutomationSummary, next = true) =>
	`${s.id} “${s.name}”: ${s.when}; runs as ${s.runsAs}; ${s.does}; result: ${s.tellsYou}.${next && s.next ? ` Next ${new Date(s.next).toISOString().slice(0, 16).replace("T", " ")} UTC.` : ""}${s.url ? ` Its URL (POST, from this Mac): ${s.url}` : ""}`;

/** A list for the model: one line per automation. */
export function listText(service: Automations, list: Automation[], next = true): string {
	if (!list.length) return "No automations.";
	return list.map((a) => `- ${describe(service.summary(a), next)}${a.enabled ? "" : " (paused)"}`).join("\n");
}

/** What the agent's tools give the host: its own automations only (AU5). */
export function agentBridge(service: Automations, agentId: string): AutomationsBridge {
	const mine = (id: string) => {
		const a = service.find(id);
		if (!a || a.runsAs !== agentId) throw new EngineError("NOT_FOUND", `You have no automation ${id}. list_automations shows yours.`);
		return a;
	};
	const input = (i: AutomationToolInput): AutomationInput => ({
		...(i.name !== undefined ? { name: i.name } : {}),
		...(i.on !== undefined ? { on: i.on as Trigger } : {}),
		...(i.when !== undefined ? { when: i.when } : {}),
		...(i.folder !== undefined ? { folder: i.folder } : {}),
		...(i.from !== undefined ? { from: i.from } : {}),
		...(i.subject !== undefined ? { subject: i.subject } : {}),
		...(i.prompt !== undefined ? { prompt: i.prompt } : {}),
		...(i.result !== undefined ? { result: i.result as ResultTo } : {}),
		...(i.to !== undefined ? { deliverTo: i.to } : {}),
		...(i.approval !== undefined ? { approval: i.approval } : {}),
		...(i.budget !== undefined ? { budgetPerRunUsd: i.budget } : {}),
		...(i.enabled !== undefined ? { enabled: i.enabled } : {}),
	});
	return {
		// The agent made it, whoever asked (AU5).
		add: async (i) => service.summary(service.add({ ...input(i), runsAs: agentId }, agentId)),
		list: async (o) => listText(service, service.list().filter((a) => a.runsAs === agentId), o?.next !== false),
		change: async (id, i) => {
			const before = structuredClone(mine(id)) as unknown as JsonObject;
			const { runsAs: _drop, ...rest } = input(i) as AutomationInput & { runsAs?: string };
			return { summary: service.summary(service.update(id, rest)), before };
		},
		remove: async (id) => {
			const before = structuredClone(mine(id)) as unknown as JsonObject;
			const a = service.remove(id);
			return { summary: service.summary(a), before };
		},
		undo: async ({ id, before }) => {
			if (id) {
				mine(id);
				service.remove(id);
			} else if (before) service.restore(before as unknown as Automation);
		},
	};
}

/** What Piopio's tools need: the service, your agents (to run one by name), and the conversation's project. */
export type PiopioAutomationsBridge = {
	service: Automations;
	agents(): AgentInfo[];
	/** The project this conversation is in, if any. */
	project(): { id: string; name: string } | undefined;
};

const text = (t: string, details: Record<string, unknown> = {}, isError = false) => ({ content: [{ type: "text" as const, text: t }], details, ...(isError ? { isError: true } : {}) });

export function automationsExtension(bridge: PiopioAutomationsBridge): ExtensionFactory {
	const { service } = bridge;
	/** "piopio", an agent's id or its name (any case). */
	const runner = (value?: string): string => {
		const v = value?.trim();
		if (!v || v.toLowerCase() === "piopio" || v.toLowerCase() === "you") return PIOPIO;
		const agents = bridge.agents();
		const found = agents.find((a) => a.id === v) ?? agents.find((a) => a.name.toLowerCase() === v.replace(/^@/, "").toLowerCase());
		if (!found) throw new EngineError("INVALID", `No agent called “${v}”. Your agents: ${agents.map((a) => a.name).join(", ") || "none"}. Or run it as Piopio.`);
		return found.id;
	};
	const params = (p: Record<string, unknown>, creating: boolean): AutomationInput => {
		const out: AutomationInput = {};
		for (const key of ["name", "when", "folder", "from", "subject", "prompt", "approval", "enabled"] as const) if (p[key] !== undefined) (out as Record<string, unknown>)[key] = p[key];
		if (p.on !== undefined) out.on = p.on as Trigger;
		if (p.result !== undefined) out.result = p.result as ResultTo;
		if (p.budget !== undefined) out.budgetPerRunUsd = p.budget as number;
		if (p.runs_as !== undefined || creating) out.runsAs = runner(p.runs_as as string | undefined);
		// In a project, Piopio works there unless told otherwise; an agent never works in a project (AU6).
		const here = bridge.project();
		if (p.in_project !== undefined) out.project = p.in_project ? (here?.id ?? null) : null;
		else if (creating) out.project = out.runsAs === PIOPIO ? (here?.id ?? null) : null;
		return out;
	};
	const shared = {
		on: Type.Optional(Type.Union([Type.Literal("time"), Type.Literal("email"), Type.Literal("folder"), Type.Literal("webhook")], { description: "What starts it (default time)" })),
		when: Type.Optional(Type.String({ description: "time: a 5-field cron (\"0 9 * * 1\" is Mondays at 9) or a local date-time once (2026-11-23T09:00)" })),
		from: Type.Optional(Type.String({ description: "email: part of the sender's name or address" })),
		subject: Type.Optional(Type.String({ description: "email: words in the subject" })),
		folder: Type.Optional(Type.String({ description: "folder: an absolute path, or one starting with ~/" })),
		name: Type.Optional(Type.String({ description: "A few words, e.g. “Weekly competitor brief”" })),
		runs_as: Type.Optional(Type.String({ description: "Who runs it: piopio (default) or one of the user's agents, by name. An agent runs it in its own chat, outside any project" })),
		in_project: Type.Optional(Type.Boolean({ description: "Piopio only: work in this conversation's project (default true when there is one)" })),
		result: Type.Optional(Type.Union([Type.Literal("conversation"), Type.Literal("chat"), Type.Literal("telegram"), Type.Literal("quiet")], { description: "Piopio: conversation (default) or quiet (only if it needs the user). An agent: chat (default), telegram (if it's connected) or quiet" })),
		approval: Type.Optional(Type.Union([Type.Literal("wait"), Type.Literal("skip")], { description: "When a run needs the user's OK: wait for it (default) or skip that run" })),
		budget: Type.Optional(Type.Number({ description: "USD per run; default 0.50 for Piopio, 0.25 for an agent" })),
	};
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			promptSection(event as unknown as PromptEvent, "automations", `When the user asks for something to happen on its own (every morning, each Monday, whenever a file or an email arrives, or once later), make it with automate and say in a line what you set; the user sees a card with Undo. If they say "just this once", do it now instead. A message that starts with [Automation] is one of their automations running: do what it says as you would their request.`);
			return undefined;
		});
		pi.registerTool(
			defineTool({
				name: "automate",
				label: "New automation",
				description:
					"Make an automation: work that starts on its own, when nobody asks. A time (once or repeating), a new email, a file in a folder, or a URL other apps can call. Use it when the user asks for something regular or for later (\"every Monday at 9…\", \"when an invoice arrives…\"). Piopio runs it in a new conversation (in this project, when there is one); one of the user's agents can run it instead (runs_as), in its own chat. An agent has only its own tools and never works in a project: it can't read or change this project's files. For work on files here, run it as Piopio, and let its prompt ask @Agent for what only that agent knows. The user sees it in Automations and can undo it.",
				promptSnippet: "automate: make work start on its own (a time, an email, a file, a URL)",
				parameters: Type.Object({ ...shared, prompt: Type.String({ description: "What to do then, in plain words" }) }),
				async execute(_id, p) {
					try {
						const a = service.add(params(p, true), "piopio");
						const s = service.summary(a);
						return text(`Made ${describe(s)} The user sees it in Automations.`, { automation: s });
					} catch (error) {
						return text((error as Error).message, {}, true);
					}
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "list_automations",
				label: "Automations",
				description: "The user's automations: what starts each, who runs it, what it does, where the result goes, and when it runs next.",
				promptSnippet: "list_automations: what runs on its own",
				parameters: Type.Object({}),
				async execute() {
					return text(listText(service, service.list()));
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "change_automation",
				label: "Change automation",
				description: "Change an automation, by id: its time or event, prompt, name, who runs it, result, approval, budget, or pause it (enabled false) and resume it.",
				promptSnippet: "change_automation: change or pause an automation",
				parameters: Type.Object({ id: Type.String(), ...shared, prompt: Type.Optional(Type.String()), enabled: Type.Optional(Type.Boolean()) }),
				async execute(_id, p) {
					try {
						const { id, ...rest } = p;
						const s = service.summary(service.update(id, params(rest, false)));
						return text(`Changed ${describe(s)}`, { automation: s, changed: true });
					} catch (error) {
						return text((error as Error).message, {}, true);
					}
				},
			}),
		);
		pi.registerTool(
			defineTool({
				name: "cancel_automation",
				label: "Remove automation",
				description: "Remove an automation, by id.",
				promptSnippet: "cancel_automation: remove an automation",
				parameters: Type.Object({ id: Type.String() }),
				async execute(_id, p) {
					try {
						const a = service.remove(p.id);
						return text(`Removed ${a.id} “${a.name}” (${whenLabel(a)}).`, { removed: { id: a.id, name: a.name } });
					} catch (error) {
						return text((error as Error).message, {}, true);
					}
				},
			}),
		);
	};
}
