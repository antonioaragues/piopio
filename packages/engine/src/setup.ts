/**
 * Overview › Setup (docs/spec/34 §6): one map of what you have and where each piece runs (You · Piopio · Uses), with
 * a dot where something needs you and dashes where something is unused, then the same facts as a table. Read from
 * what the engine already knows; drawn by the app.
 */
import type { CloudStatus, ConnectorInfo, McpServerInfo, ProviderInfo, SetupNode, SetupResult } from "@piopio/protocol";

export type SetupAgent = {
	id: string;
	name: string;
	avatar?: string;
	cloud: boolean;
	model: string;
	/** A Telegram bot is set for it. */
	telegram: boolean;
	paused: boolean;
	/** Out of its monthly budget. */
	overBudget: boolean;
	nextRun?: string;
	monthUsd: number;
	automations: number;
	/** Its definition doesn't validate. */
	invalid?: string;
};

export type SetupAutomation = { id: string; name: string; runsAs: string; enabled: boolean; result: string; nextRun?: string; monthUsd: number; cloud: boolean };

export type SetupInput = {
	providers: readonly ProviderInfo[];
	codingAgents: readonly ProviderInfo[];
	connectors: readonly ConnectorInfo[];
	mcp: readonly McpServerInfo[];
	memory: { semantic: boolean; reason?: string; error?: string };
	cloud: CloudStatus;
	agents: readonly SetupAgent[];
	automations: readonly SetupAutomation[];
	projects: number;
	defaultModel: string;
	/** Providers with requests in the last 30 days (unused ones are dashed). */
	usedProviders: ReadonlySet<string>;
	/** MCP servers whose tools ran in the last 30 days. */
	usedMcp: ReadonlySet<string>;
};

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

export function setupMap(input: SetupInput): SetupResult {
	const nodes: SetupNode[] = [];
	const edges: SetupResult["edges"] = [];
	const agentState = (a: SetupAgent): { state: SetupNode["state"]; reason?: string } =>
		a.invalid ? { state: "needs_you", reason: a.invalid } : a.overBudget ? { state: "needs_you", reason: "out of budget this month" } : a.paused ? { state: "off", reason: "paused" } : !a.automations && !a.telegram && a.monthUsd === 0 ? { state: "unused" } : { state: "ok" };

	// ── You ──
	nodes.push({ id: "you:mac", column: "you", kind: "device", name: "This Mac", line: "the app and its windows", state: "ok" });
	for (const a of input.agents.filter((x) => x.telegram)) {
		nodes.push({ id: `channel:telegram:${a.id}`, column: "you", kind: "channel", name: "Telegram", line: `reaches ${a.name}`, state: "ok", open: { kind: "agent", id: a.id } });
		edges.push({ from: `channel:telegram:${a.id}`, to: `agent:${a.id}` });
	}

	// ── Piopio ──
	const here = input.agents.filter((a) => !a.cloud);
	const autosHere = input.automations.filter((x) => !x.cloud && x.enabled).length;
	nodes.push({
		id: "place:mac",
		column: "piopio",
		kind: "place",
		name: "This Mac",
		line: [plural(input.projects, "project"), plural(here.length, "agent"), plural(autosHere, "automation")].join(" · "),
		state: "ok",
		agents: here.map((a) => ({ id: a.id, name: a.name, ...(a.avatar ? { avatar: a.avatar } : {}), ...agentState(a) })),
	});
	edges.push({ from: "you:mac", to: "place:mac" });
	if (input.cloud.connected || input.agents.some((a) => a.cloud)) {
		const there = input.agents.filter((a) => a.cloud);
		const down = input.cloud.connected && input.cloud.reachable === false;
		nodes.push({
			id: "place:cloud",
			column: "piopio",
			kind: "place",
			name: "Cloud",
			line: [input.cloud.url ? new URL(input.cloud.url).host.split(".")[0] : "your cloud", plural(there.length, "agent")].join(" · "),
			state: down ? "needs_you" : "ok",
			...(down ? { reason: input.cloud.error ? `not answering: ${input.cloud.error}` : "not answering" } : {}),
			open: { kind: "settings", pane: "cloud" },
			agents: there.map((a) => ({ id: a.id, name: a.name, ...(a.avatar ? { avatar: a.avatar } : {}), ...agentState(a) })),
		});
	}

	// ── Uses ──
	const connected = input.providers.filter((p) => p.status === "connected" || p.status === "needs_attention");
	const defaultProvider = input.defaultModel.split("/")[0];
	for (const p of connected) {
		const needs = p.status === "needs_attention";
		const used = input.usedProviders.has(p.id) || p.id === defaultProvider;
		nodes.push({
			id: `provider:${p.id}`,
			column: "uses",
			kind: "provider",
			name: p.name,
			line: [p.id === defaultProvider ? `default · ${input.defaultModel.split("/").slice(1).join("/")}` : `${p.models} models`, p.billing].filter(Boolean).join(" · "),
			state: needs ? "needs_you" : used ? "ok" : "unused",
			...(needs ? { reason: p.message ?? "sign-in or key rejected" } : {}),
			open: { kind: "settings", pane: "providers", id: p.id },
		});
		edges.push({ from: "place:mac", to: `provider:${p.id}` });
	}
	// The cloud's agents use OpenRouter with the key this Mac gave it (30 K1).
	if (nodes.some((n) => n.id === "place:cloud") && nodes.some((n) => n.id === "provider:openrouter")) edges.push({ from: "place:cloud", to: "provider:openrouter" });
	for (const a of input.codingAgents.filter((x) => x.agent?.path)) {
		const signedIn = a.agent?.signedIn ?? false;
		nodes.push({
			id: `coding:${a.id}`,
			column: "uses",
			kind: "coding_agent",
			name: a.name,
			line: signedIn ? (a.billing ?? "signed in") : "installed",
			state: signedIn ? (input.usedProviders.has(a.id) ? "ok" : "unused") : "needs_you",
			...(signedIn ? {} : { reason: "signed out" }),
			open: { kind: "settings", pane: "providers", id: a.id },
		});
		edges.push({ from: "place:mac", to: `coding:${a.id}` });
	}
	for (const c of input.connectors.filter((x) => x.accounts.length)) {
		const problem = c.accounts.find((x) => x.problem)?.problem;
		nodes.push({
			id: `connector:${c.id}`,
			column: "uses",
			kind: "connector",
			name: c.name,
			line: c.accounts.length === 1 ? c.accounts[0]!.label : plural(c.accounts.length, "account"),
			state: problem ? "needs_you" : "ok",
			...(problem ? { reason: problem } : {}),
			open: { kind: "settings", pane: "connectors", id: c.id },
		});
		edges.push({ from: "place:mac", to: `connector:${c.id}` });
	}
	for (const m of input.mcp.filter((x) => x.scope === "global")) {
		nodes.push({
			id: `mcp:${m.name}`,
			column: "uses",
			kind: "mcp",
			name: m.name,
			line: m.transport === "http" ? "MCP · remote" : "MCP · on this Mac",
			state: !m.enabled ? "off" : input.usedMcp.has(m.name) ? "ok" : "unused",
			open: { kind: "settings", pane: "mcp" },
		});
		if (m.enabled) edges.push({ from: "place:mac", to: `mcp:${m.name}` });
	}
	const memoryFailing = input.memory.reason === "failing";
	nodes.push({
		id: "memory",
		column: "uses",
		kind: "memory",
		name: "Memory",
		line: input.memory.semantic ? "words and meaning" : "words only",
		state: memoryFailing ? "needs_you" : "ok",
		...(memoryFailing ? { reason: input.memory.error ?? "semantic search is failing" } : {}),
		open: { kind: "settings", pane: "memory" },
	});
	edges.push({ from: "place:mac", to: "memory" });

	// ── What runs where (§6.2) ──
	const agentName = new Map(input.agents.map((a) => [a.id, a]));
	const rows: SetupResult["rows"] = [
		...input.agents.map((a) => ({
			kind: "agent" as const,
			id: a.id,
			name: a.name,
			runsOn: a.cloud ? ("cloud" as const) : ("mac" as const),
			model: a.model,
			reachesYouIn: a.telegram ? "Telegram and its chat" : "its chat",
			...(a.nextRun ? { nextRun: a.nextRun } : {}),
			monthUsd: a.monthUsd,
			...(a.paused ? { paused: true } : {}),
		})),
		...input.automations.map((x) => {
			const agent = agentName.get(x.runsAs);
			return {
				kind: "automation" as const,
				id: x.id,
				name: x.name,
				runsOn: x.cloud ? ("cloud" as const) : ("mac" as const),
				...(agent ? { model: agent.model } : {}),
				reachesYouIn: x.result === "telegram" ? "Telegram" : x.result === "quiet" ? "quietly, unless it needs you" : x.result === "conversation" ? "a conversation" : agent ? `${agent.name}'s chat` : "a conversation",
				...(x.nextRun ? { nextRun: x.nextRun } : {}),
				monthUsd: x.monthUsd,
				...(!x.enabled ? { paused: true } : {}),
			};
		}),
	];
	return { nodes, edges, rows };
}
