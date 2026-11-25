/**
 * The engine's `catalog.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `catalog.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function catalogHandlers(engine: Engine): Handlers<"catalog"> {
	return {
		"catalog.search": async (params, _call) => {
			const p = params as Params<"catalog.search">;
			return { results: await engine.sessions.find(p.query, p.limit ?? 30, p.kind) } satisfies Result<"catalog.search">;
		},
	};
}
