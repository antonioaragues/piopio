/**
 * The engine's `models.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `models.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function modelsHandlers(engine: Engine): Handlers<"models"> {
	return {
		"models.onDevice": async (_params, _call) => {
			return (await engine.hub.onDevice.status()) satisfies Result<"models.onDevice">;
		},
		"models.list": async (params, _call) => {
			const p = params as Params<"models.list">;
			return { models: await engine.hub.listModels(p.refresh ?? false), defaultModel: engine.hub.defaultModel } satisfies Result<"models.list">;
		},
	};
}
