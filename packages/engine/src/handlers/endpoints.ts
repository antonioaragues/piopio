/**
 * The engine's `endpoints.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `endpoints.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { detectLocalServers } from "../endpoints.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function endpointsHandlers(engine: Engine): Handlers<"endpoints"> {
	return {
		"endpoints.check": async (params, _call) => {
			const p = params as Params<"endpoints.check">;
			const check = await engine.hub.checkEndpoint(p.baseUrl, p.key, p.id, { ...(p.format ? { format: p.format } : {}), ...(p.headers ? { headers: p.headers } : {}) });
			return (check.ok ? { ok: true, baseUrl: check.baseUrl, models: check.models, latencyMs: check.latencyMs } : { ok: false, models: [], message: check.message, error: check.error }) satisfies Result<"endpoints.check">;
		},
		"endpoints.save": async (params, _call) => {
			const p = params as Params<"endpoints.save">;
			const endpoint = await engine.hub.saveEndpoint(p);
			for (const c of engine.authed) c.notify("providers.changed", {});
			return { id: endpoint.id } satisfies Result<"endpoints.save">;
		},
		"endpoints.remove": async (params, _call) => {
			const p = params as Params<"endpoints.remove">;
			await engine.hub.removeEndpoint(p.id);
			for (const c of engine.authed) c.notify("providers.changed", {});
			return {};
		},
		"endpoints.detect": async (_params, _call) => {
			const added = new Set(engine.hub.endpoints.list().map((e) => e.baseUrl));
			return { found: (await detectLocalServers()).filter((f) => !added.has(f.baseUrl)) } satisfies Result<"endpoints.detect">;
		},
	};
}
