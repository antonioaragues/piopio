/**
 * The engine's `stats.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `stats.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { rangeBounds, type LedgerNames } from "../ledger.js";
import { suggestions } from "../suggest.js";
import { activity } from "../activity.js";
import { cleanWorktrees, storage, worktrees } from "../storage.js";
import { setupMap, type SetupAgent } from "../setup.js";
import type { SpendSuggestion } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function statsHandlers(engine: Engine): Handlers<"stats"> {
	return {
		"stats.spend": async (params, _call) => {
			const p = params as Params<"stats.spend">;
			// The first open reads past conversations into the ledger; what's there after a moment is shown, marked.
			const done = await Promise.race([engine.sessions.backfillLedger().then(() => true), new Promise<false>((r) => setTimeout(() => r(false), 1500))]);
			const names = engine.sessions.ledgerNames();
			const result = engine.hub.ledger.spend(p, names);
			result.suggestions = await spendSuggestions(engine, p, names).catch(() => []);
			const cloudAsOf = engine.sessions.cloudLedgerAsOf();
			return { ...result, ...(done ? {} : { backfilling: true }), ...(cloudAsOf ? { cloudAsOf } : {}) } satisfies Result<"stats.spend">;
		},
		"stats.items": async (params, _call) => {
			const p = params as Params<"stats.items">;
			return { items: engine.hub.ledger.items(p, engine.sessions.ledgerNames()) } satisfies Result<"stats.items">;
		},
		"stats.activity": async (params, _call) => {
			const p = params as Params<"stats.activity">;
			const done = await Promise.race([engine.sessions.backfillLedger().then(() => true), new Promise<false>((r) => setTimeout(() => r(false), 1500))]);
			const result = activity(p.range, {
				ledger: engine.hub.ledger,
				sessions: engine.sessions.list(),
				runs: engine.automations.allRuns(),
				automationName: (id) => engine.automations.find(id)?.name,
				agentName: (id) => engine.sessions.titleOf({ kind: "agent", id }),
			});
			return (done ? result : { ...result, backfilling: true }) satisfies Result<"stats.activity">;
		},
		"stats.storage": async (_params, _call) => {
			return (await storage(engine.options.paths.home, worktreeList(engine), (id) => projectName(engine, id))) satisfies Result<"stats.storage">;
		},
		"stats.storage.clean": async (_params, _call) => {
			return (await cleanWorktrees(worktreeList(engine))) satisfies Result<"stats.storage.clean">;
		},
		"stats.setup": async (_params, _call) => {
			return (await setup(engine)) satisfies Result<"stats.setup">;
		},
		"stats.budgets": async (_params, _call) => {
			return { budgets: engine.sessions.budgets(), piopio: engine.hub.budget.state() } satisfies Result<"stats.budgets">;
		},
		"stats.budget.set": async (params, _call) => {
			const p = params as Params<"stats.budget.set">;
			try {
				return engine.hub.budget.set(p.monthUsd) satisfies Result<"stats.budget.set">;
			} catch (error) {
				throw new EngineError("INVALID", (error as Error).message);
			}
		},
		"stats.budget.release": async (params, _call) => {
			const p = params as Params<"stats.budget.release">;
			if (p.month) return engine.hub.budget.allowMonth() satisfies Result<"stats.budget.release">;
			if (p.run) await engine.automations.release(p.run);
			return engine.hub.budget.state() satisfies Result<"stats.budget.release">;
		},
		"stats.export": async (params, _call) => {
			const p = params as Params<"stats.export">;
			await engine.sessions.backfillLedger();
			return engine.hub.ledger.csv(p.range) satisfies Result<"stats.export">;
		},
	};
}

function projectName(engine: Engine, id: string): string | undefined {
	try {
		return engine.projects.get(id).name;
	} catch {
		return id === "teams" ? "Teams (before 26)" : undefined;
	}
}

/** Overview › Setup (docs/spec/34 §6): what the engine knows, as the map and the table. */
async function setup(engine: Engine): Promise<Result<"stats.setup">> {
	const now = new Date();
	const month = rangeBounds("month", now);
	const monthRows = engine.hub.ledger.rows(month.from, month.to);
	const monthOf = (match: (r: (typeof monthRows)[number]) => boolean) => monthRows.filter((r) => !r.plan && match(r)).reduce((n, r) => n + (r.usd ?? 0), 0);
	const since = new Date(now.getTime() - 30 * 86_400_000);
	const usedProviders = new Set(engine.hub.ledger.rows(since, now).flatMap((r) => (r.provider ? [r.provider] : [])));
	const toolNames = new Set(engine.hub.ledger.activityRows(since, now).flatMap((r) => (r.kind === "tool" && r.name ? [r.name] : [])));
	const [providers, codingAgents, connectors, memory, cloud] = await Promise.all([
		engine.hub.listProviders((id) => engine.logins.connecting(id)).catch(() => []),
		engine.hub.listAgents().catch(() => []),
		engine.connectorInfos().catch(() => []),
		engine.memory.status().catch(() => ({ semantic: false })),
		engine.cloud.status().catch(() => ({ connected: false, agents: [] })),
	]);
	const mcp = engine.mcp.list(undefined).servers;
	const usedMcp = new Set(mcp.map((m) => m.name).filter((name) => [...toolNames].some((t) => t.startsWith(`${name}_`) || t.startsWith(`mcp__${name}__`) || t.includes(`__${name}__`))));
	const summaries = new Map(engine.sessions.list("agent").map((s) => [s.ref.id, s]));
	const automations = engine.automations.list();
	const agents: SetupAgent[] = engine.sessions.agents.agentList().map((a) => {
		const s = summaries.get(a.id);
		const status = s?.agent?.status;
		return {
			id: a.id,
			name: a.name,
			...(s?.agent?.avatar ? { avatar: s.agent.avatar } : {}),
			cloud: engine.sessions.agents.isCloud(a.id),
			model: a.definition.models.default,
			telegram: Boolean(a.definition.channels?.telegram),
			paused: status?.paused ?? false,
			overBudget: status?.budgetUsd !== undefined && status.spendUsd >= status.budgetUsd,
			...(status?.nextRun ? { nextRun: status.nextRun } : {}),
			monthUsd: monthOf((r) => r.agent === a.id),
			automations: automations.filter((x) => x.runsAs === a.id).length,
		};
	});
	const cloudAgents = new Set(agents.filter((a) => a.cloud).map((a) => a.id));
	return setupMap({
		providers,
		codingAgents,
		connectors,
		mcp,
		memory,
		cloud,
		agents,
		automations: automations.map((x) => ({
			id: x.id,
			name: x.name,
			runsAs: x.runsAs,
			enabled: x.enabled,
			result: x.result,
			...(x.next ? { nextRun: new Date(x.next).toISOString() } : {}),
			monthUsd: monthOf((r) => r.automation === x.id),
			cloud: cloudAgents.has(x.runsAs),
		})),
		projects: engine.projects.list().length,
		defaultModel: `${engine.hub.defaultModel.provider}/${engine.hub.defaultModel.id}`,
		usedProviders,
		usedMcp,
	});
}

/** Cheaper next time (docs/spec/34 §5.5): from the range's rows, today's prices and what this Mac can run. */
async function spendSuggestions(engine: Engine, p: Params<"stats.spend">, names: LedgerNames): Promise<SpendSuggestion[]> {
	const { from, to } = rangeBounds(p.range);
	const [models, onDevice] = await Promise.all([engine.hub.listModels().catch(() => []), engine.hub.onDevice.status().catch(() => ({ available: false }))]);
	const labels: Record<string, string> = { today: "today", "7d": "these 7 days", month: "this month", last_month: "last month", "12m": "this year" };
	return suggestions(engine.hub.ledger.rows(from, to), { models, names, onDeviceOffer: onDevice.available && engine.settings.get().models?.utility !== "on_device", rangeLabel: labels[p.range] ?? "" });
}

/** Worktrees in the data folder, each with whether a live session works in it (Overview › Disk). */
function worktreeList(engine: Engine) {
	const home = engine.options.paths.home;
	const inUse = new Set<string>();
	// A worktree session works in its worktree until it's merged or discarded (then its cwd is the project).
	for (const s of engine.sessions.list()) if (s.cwd) inUse.add(s.cwd);
	return worktrees(home, inUse, (id) => {
		try {
			return engine.projects.get(id).path;
		} catch {
			return undefined;
		}
	});
}
