/**
 * The engine's `cloud.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `cloud.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function cloudHandlers(engine: Engine): Handlers<"cloud"> {
	return {
		"cloud.status": async (_params, _call) => {
			return (await engine.cloud.status()) satisfies Result<"cloud.status">;
		},
		"cloud.setup": async (params, _call) => {
			const p = params as Params<"cloud.setup">;
			const r = await engine.cloud.setup(p.apiToken, p.accountId);
			if (r.status) void engine.sessions.refreshCloudAgents();
			return r satisfies Result<"cloud.setup">;
		},
		"cloud.update": async (_params, _call) => {
			return (await engine.cloud.update()) satisfies Result<"cloud.update">;
		},
		"cloud.connect": async (params, _call) => {
			const p = params as Params<"cloud.connect">;
			return (await engine.cloud.connect(p.url, p.token)) satisfies Result<"cloud.connect">;
		},
		"cloud.disconnect": async (_params, _call) => {
			const up = engine.sessions.agentList().filter((a) => engine.sessions.isCloud(a.id));
			if (up.length) throw new EngineError("INVALID", `${up.map((a) => a.name).join(", ")} ${up.length === 1 ? "runs" : "run"} in your cloud. Move ${up.length === 1 ? "it" : "them"} to this Mac first.`);
			await engine.cloud.disconnect();
			return {} satisfies Result<"cloud.disconnect">;
		},
	};
}
