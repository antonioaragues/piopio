/**
 * The engine's `inbox.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `inbox.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function inboxHandlers(engine: Engine): Handlers<"inbox"> {
	return {
		"inbox.list": async (_params, _call) => {
			return (await engine.sessions.agents.inbox()) satisfies Result<"inbox.list">;
		},
		"inbox.read": async (params, _call) => {
			const p = params as Params<"inbox.read">;
			await engine.sessions.agents.inboxRead(p.items);
			return {} satisfies Result<"inbox.read">;
		},
	};
}
