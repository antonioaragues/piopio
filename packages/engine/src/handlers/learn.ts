/**
 * The engine's `learn.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `learn.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function learnHandlers(engine: Engine): Handlers<"learn"> {
	return {
		"learn.save": async (params, _call) => {
			const p = params as Params<"learn.save">;
			return (await engine.sessions.learnSave(p.ref, p.callId, p.items)) satisfies Result<"learn.save">;
		},
		"learn.answer": async (params, _call) => {
			const p = params as Params<"learn.answer">;
			await engine.sessions.learnAnswer(p.ref, p.callId, p.choice);
			return {} satisfies Result<"learn.answer">;
		},
	};
}
