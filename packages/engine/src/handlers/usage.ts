/**
 * The engine's `usage.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `usage.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { SECRET_OPENROUTER, type Params, type Result } from "@piopio/protocol";
import { keyHint, providerUsage } from "../models.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function usageHandlers(engine: Engine): Handlers<"usage"> {
	return {
		"usage.extras": async (params, _call) => {
			const p = params as Params<"usage.extras">;
			return engine.hub.ledger.costSummary(p.ref?.id) satisfies Result<"usage.extras">;
		},
		"usage.summary": async (params, _call) => {
			const p = params as Params<"usage.summary">;
			if (engine.usageCache && !p.refresh && Date.now() - engine.usageCache.at < 60_000) return engine.usageCache.value;
			const key = await engine.secrets.get(SECRET_OPENROUTER, "Show what your provider has billed").catch(() => null);
			const usage = key ? await providerUsage(key) : undefined;
			const value: Result<"usage.summary"> = { connected: Boolean(key), ...(key ? { keyHint: keyHint(key) } : {}), ...(usage ?? {}) };
			engine.usageCache = { at: Date.now(), value };
			return value;
		},
	};
}
