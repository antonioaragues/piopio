/**
 * The engine's `watchdog.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `watchdog.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function watchdogHandlers(engine: Engine): Handlers<"watchdog"> {
	return {
		"watchdog.list": async (_params, _call) => {
			return { notes: engine.watchdog.list() } satisfies Result<"watchdog.list">;
		},
		"watchdog.dismiss": async (params, _call) => {
			const p = params as Params<"watchdog.dismiss">;
			engine.watchdog.dismiss(p.id);
			return {} satisfies Result<"watchdog.dismiss">;
		},
	};
}
