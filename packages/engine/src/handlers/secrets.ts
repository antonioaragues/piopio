/**
 * The engine's `secrets.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `secrets.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function secretsHandlers(engine: Engine): Handlers<"secrets"> {
	return {
		"secrets.changed": async (params, _call) => {
			const p = params as Params<"secrets.changed">;
			await engine.hub.forgetSecret(p.name);
			await engine.hub.connected();
			for (const c of engine.authed) c.notify("providers.changed", {});
			return {};
		},
	};
}
