/**
 * The engine's `settings.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `settings.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function settingsHandlers(engine: Engine): Handlers<"settings"> {
	return {
		"settings.get": async (_params, _call) => {
			return engine.settings.get() satisfies Result<"settings.get">;
		},
		"settings.set": async (params, _call) => {
			const p = params as Params<"settings.set">;
			return engine.settings.set(p) satisfies Result<"settings.set">;
		},
	};
}
