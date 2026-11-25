/**
 * The engine's `memory.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `memory.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { join } from "node:path";
import { existsSync, statSync } from "node:fs";
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { ABOUT_ME_BANK } from "../about-me.js";
import { exportMemory } from "../memory.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function memoryHandlers(engine: Engine): Handlers<"memory"> {
	return {
		"memory.list": async (params, _call) => {
			const p = params as Params<"memory.list">;
			const provider = engine.memory.get(p.provider);
			if (!provider.list || !provider.capabilities.list) return { records: [], limited: true } satisfies Result<"memory.list">;
			if (p.query?.trim()) {
				const hits = await provider.recall([p.bank], p.query, { budgetTokens: 20_000, limit: 100, ...(p.kinds ? { kinds: p.kinds as never } : {}) });
				return { records: hits.map(({ bank: _b, tags: _t, confidence: _c, score: _s, ...r }) => r), limited: false } satisfies Result<"memory.list">;
			}
			const page = await provider.list(p.bank, { ...(p.cursor ? { cursor: p.cursor } : {}), ...(p.kinds ? { kinds: p.kinds as never } : {}), ...(p.includeEnded ? { includeEnded: true } : {}) } as never);
			return { records: page.records.map(({ bank: _b, tags: _t, confidence: _c, ...r }) => r), ...(page.cursor ? { cursor: page.cursor } : {}), limited: false } satisfies Result<"memory.list">;
		},
		"memory.add": async (params, _call) => {
			const p = params as Params<"memory.add">;
			await engine.memory.get(p.provider).retain(p.bank, { content: p.text, kind: "fact", createdBy: "user", ...(p.replaces ? { replaces: p.replaces } : {}) });
			return {};
		},
		"memory.forget": async (params, _call) => {
			const p = params as Params<"memory.forget">;
			const provider = engine.memory.get(p.provider);
			if (!provider.forget) throw new EngineError("INVALID", "This memory provider can't forget from here.");
			// Forget in Settings › Memory or an agent's memory: gone, history included (About me keeps its own Undo).
			await provider.forget(p.bank, p.id, "user", { purge: true });
			return {};
		},
		"memory.update": async (params, _call) => {
			const p = params as Params<"memory.update">;
			const provider = engine.memory.get(p.provider);
			if (!provider.update) throw new EngineError("INVALID", "This memory provider can't edit from here.");
			await provider.update(p.bank, p.id, { ...(p.text !== undefined ? { text: p.text } : {}), ...(p.pinned !== undefined ? { pinned: p.pinned } : {}) }, "user");
			return {};
		},
		"memory.tools": async (params, _call) => {
			const p = params as Params<"memory.tools">;
			if (!p.server === !p.url) throw new EngineError("INVALID", "Give an MCP server's name or a URL.");
			return { tools: await engine.memory.tools(p) } satisfies Result<"memory.tools">;
		},
		"memory.status": async (_params, _call) => {
			return (await engine.memory.status()) satisfies Result<"memory.status">;
		},
		"memory.banks": async (_params, _call) => {
			const owners = engine.sessions.agents.memoryOwners();
			const labels = new Map(owners.agents.flatMap((a) => a.partitions.map((p) => [p.bank, { label: p.label, agent: a }] as const)));
			const banks = engine.memory.builtin.banks().map((b) => {
				const owner = labels.get(b.bank);
				const area = b.bank === ABOUT_ME_BANK ? "about-me" : owner ? "agent" : "other";
				return {
					...b,
					label: b.bank === ABOUT_ME_BANK ? "About me" : (owner?.label ?? b.bank),
					area,
					...(owner ? { agent: { id: owner.agent.id, name: owner.agent.name, ...(owner.agent.avatar ? { avatar: owner.agent.avatar } : {}), learns: owner.agent.learns } } : {}),
				};
			});
			const bytes = ["memory.db", "memory.db-wal"].reduce((n, f) => n + (existsSync(join(engine.options.paths.home, f)) ? statSync(join(engine.options.paths.home, f)).size : 0), 0);
			return { banks, agents: owners.agents.map(({ partitions: _p, ...a }) => a), bytes } satisfies Result<"memory.banks">;
		},
		"memory.history": async (params, _call) => {
			const p = params as Params<"memory.history">;
			const provider = engine.memory.get(p.provider);
			const events = provider.history ? await provider.history(p.bank, { limit: p.limit ?? 200 }) : [];
			return { events: events.map((e) => ({ id: e.id, at: e.at, action: e.action, recordId: e.recordId, text: e.text, by: e.by })) } satisfies Result<"memory.history">;
		},
		"memory.export": async (params, _call) => {
			const p = params as Params<"memory.export">;
			return exportMemory(engine.memory.builtin, p.folder, (bank) => (bank === ABOUT_ME_BANK ? "About me" : bank)) satisfies Result<"memory.export">;
		},
		"memory.wipe": async (params, _call) => {
			const p = params as Params<"memory.wipe">;
			return { records: engine.memory.builtin.wipe(p.bank === "*" ? undefined : p.bank) } satisfies Result<"memory.wipe">;
		},
		"memory.reindex": async (_params, _call) => {
			return { pending: engine.memory.reindex() } satisfies Result<"memory.reindex">;
		},
		"memory.setLearning": async (params, _call) => {
			const p = params as Params<"memory.setLearning">;
			await engine.sessions.agents.setLearning(p.ref, p.learn);
			return {} satisfies Result<"memory.setLearning">;
		},
		"memory.recall": async (params, _call) => {
			const p = params as Params<"memory.recall">;
			const hits = await engine.memory.get(p.provider).recall([p.bank], p.query, { budgetTokens: 2000 });
			return { hits: hits.map((h) => ({ id: h.id, text: h.text, score: h.score, ...(h.at ? { at: h.at } : {}) })) } satisfies Result<"memory.recall">;
		},
	};
}
