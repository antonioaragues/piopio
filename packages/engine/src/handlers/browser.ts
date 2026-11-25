/**
 * The engine's `browser.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `browser.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function browserHandlers(engine: Engine): Handlers<"browser"> {
	return {
		"browser.sites": async (_params, _call) => {
			return { sites: engine.browserSites.list() } satisfies Result<"browser.sites">;
		},
		"browser.setSite": async (params, _call) => {
			const p = params as Params<"browser.setSite">;
			engine.browserSites.set(p.site, p.level);
			return {};
		},
	};
}
