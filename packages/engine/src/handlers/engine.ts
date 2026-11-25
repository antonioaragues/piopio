/**
 * The engine's `engine.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `engine.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 * `engine.hello` is server.ts's own: it signs the connection in.
 */
import { type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function engineHandlers(engine: Engine): Omit<Handlers<"engine">, "engine.hello"> {
	return {
		"engine.status": async (_params, _call) => {
			return {
				uptimeMs: Date.now() - engine.startedAt,
				openSessions: engine.sessions.openCount,
				subscriptions: engine.subscriptions.size,
				runtime: `Node ${process.versions.node}`,
				memoryMB: Math.round(process.memoryUsage().rss / 1_048_576),
				dataPath: engine.options.paths.home,
			} satisfies Result<"engine.status">;
		},
		"engine.shutdown": async (_params, _call) => {
			if (!engine.options.onShutdown) throw new EngineError("INVALID", "This engine cannot be shut down remotely.");
			setTimeout(engine.options.onShutdown, 100);
			return {};
		},
	};
}
