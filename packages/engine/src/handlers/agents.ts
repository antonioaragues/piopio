/**
 * The engine's `agents.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `agents.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { TEMPLATES } from "@piopio/runtime";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function agentsHandlers(engine: Engine): Handlers<"agents"> {
	return {
		"agents.templates": async (_params, _call) => {
			return { templates: TEMPLATES.map(({ id, name, avatar, description, instructions, definition }) => ({ id, name, avatar, description, instructions, ...(definition.schedules?.[0] ? { schedule: definition.schedules[0].cron } : {}) })) } satisfies Result<"agents.templates">;
		},
		"agents.create": async (params, _call) => {
			const p = params as Params<"agents.create">;
			return { ref: await engine.sessions.agents.createAgent(p) } satisfies Result<"agents.create">;
		},
		"agents.get": async (params, _call) => {
			const p = params as Params<"agents.get">;
			return (await engine.sessions.agents.getAgent(p.ref)) satisfies Result<"agents.get">;
		},
		"agents.save": async (params, _call) => {
			const p = params as Params<"agents.save">;
			return (await engine.sessions.agents.saveAgent(p.ref, p.definition, p.instructions, p.message)) satisfies Result<"agents.save">;
		},
		"agents.conversations": async (params, _call) => {
			const p = params as Params<"agents.conversations">;
			return { people: await engine.sessions.agents.agentConversations(p.ref) } satisfies Result<"agents.conversations">;
		},
		"agents.runs": async (params, _call) => {
			const p = params as Params<"agents.runs">;
			return (await engine.sessions.agents.agentRuns(p.ref)) satisfies Result<"agents.runs">;
		},
		"agents.runNow": async (params, _call) => {
			const p = params as Params<"agents.runNow">;
			if (engine.sessions.agents.isCloud(p.ref.id)) return (await engine.sessions.agents.cloudAgentCall(p.ref.id, "agents.runNow", { ...p, ref: { kind: "agent", id: p.ref.id } })) satisfies Result<"agents.runNow">;
			const run = await (await engine.sessions.agent(p.ref)).runNow(p.scheduleId, p.prompt, p.trial ?? false);
			return { runId: run.id } satisfies Result<"agents.runNow">;
		},
		"agents.triggers": async (params, _call) => {
			const p = params as Params<"agents.triggers">;
			const def = engine.sessions.agents.agentDefinition(p.ref.id).definition;
			if (!engine.hooks.port) throw new EngineError("INTERNAL", "Webhook triggers are off (the port couldn't be opened).");
			return { triggers: (def.triggers ?? []).map((t) => ({ id: t.id, url: engine.hooks.url(p.ref.id, t.id) })) } satisfies Result<"agents.triggers">;
		},
		"agents.decide": async (params, _call) => {
			const p = params as Params<"agents.decide">;
			if (engine.sessions.agents.isCloud(p.ref.id)) return (await engine.sessions.agents.cloudAgentCall(p.ref.id, "agents.decide", { ...p, ref: { kind: "agent", id: p.ref.id } })) satisfies Result<"agents.decide">;
			const runtime = await engine.sessions.agent(p.ref);
			try {
				const a = await runtime.core.safety.decide(p.approvalId, { approve: p.approve, ...(p.args && typeof p.args === "object" ? { args: p.args as never } : {}), ...(p.always ? { always: true } : {}), ...(p.reason ? { reason: p.reason } : {}) });
				return { status: a.status } satisfies Result<"agents.decide">;
			} catch (error) {
				throw new EngineError("CONFLICT", (error as Error).message);
			}
		},
		"agents.undo": async (params, _call) => {
			const p = params as Params<"agents.undo">;
			if (engine.sessions.agents.isCloud(p.ref.id)) return (await engine.sessions.agents.cloudAgentCall(p.ref.id, "agents.undo", { ...p, ref: { kind: "agent", id: p.ref.id } })) satisfies Result<"agents.undo">;
			const runtime = await engine.sessions.agent(p.ref);
			try {
				await runtime.core.safety.undo(p.undoId);
			} catch (error) {
				throw new EngineError("CONFLICT", (error as Error).message);
			}
			return {} satisfies Result<"agents.undo">;
		},
		"agents.pause": async (params, _call) => {
			const p = params as Params<"agents.pause">;
			if (engine.sessions.agents.isCloud(p.ref.id)) return (await engine.sessions.agents.cloudAgentCall(p.ref.id, "agents.pause", { ...p, ref: { kind: "agent", id: p.ref.id } })) satisfies Result<"agents.pause">;
			await (await engine.sessions.agent(p.ref)).core.safety.setPaused(p.paused);
			return {} satisfies Result<"agents.pause">;
		},
		"agents.trace": async (params, _call) => {
			const p = params as Params<"agents.trace">;
			return (await engine.sessions.agents.agentTrace(p.traceId)) satisfies Result<"agents.trace">;
		},
		"agents.move": async (params, _call) => {
			const p = params as Params<"agents.move">;
			return { lines: await engine.sessions.agents.moveAgent(p.ref, p.to) } satisfies Result<"agents.move">;
		},
		"agents.files": async (params, _call) => {
			const p = params as Params<"agents.files">;
			const store = engine.sessions.agentFiles(p.ref);
			return { files: store.listSync(), folder: store.dir } satisfies Result<"agents.files">;
		},
		"agents.files.add": async (params, _call) => {
			const p = params as Params<"agents.files.add">;
			return { files: engine.sessions.agentFiles(p.ref).keep(p.attachments, { from: "owner" }) } satisfies Result<"agents.files.add">;
		},
		"agents.files.note": async (params, _call) => {
			const p = params as Params<"agents.files.note">;
			return (await engine.sessions.agentFiles(p.ref).note(p.name, { ...(p.note !== undefined ? { note: p.note } : {}), ...(p.rename ? { rename: p.rename } : {}) })) satisfies Result<"agents.files.note">;
		},
		"agents.files.delete": async (params, _call) => {
			const p = params as Params<"agents.files.delete">;
			await engine.sessions.agentFiles(p.ref).remove(p.name);
			return {} satisfies Result<"agents.files.delete">;
		},
		"agents.memory": async (params, _call) => {
			const p = params as Params<"agents.memory">;
			return engine.sessions.agents.agentMemory(p.ref) satisfies Result<"agents.memory">;
		},
	};
}
