/**
 * The engine's `connectors.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `connectors.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function connectorsHandlers(engine: Engine): Handlers<"connectors"> {
	return {
		"connectors.list": async (_params, _call) => {
			return { connectors: await engine.connectorInfos() } satisfies Result<"connectors.list">;
		},
		"connectors.connect": async (params, _call) => {
			const p = params as Params<"connectors.connect">;
			try {
				return { loginId: engine.connectors.connect(p.connector) } satisfies Result<"connectors.connect">;
			} catch (error) {
				throw new EngineError("INVALID", (error as Error).message);
			}
		},
		"connectors.cancel": async (params, _call) => {
			engine.connectors.cancel((params as Params<"connectors.cancel">).loginId);
			return {};
		},
		"connectors.disconnect": async (params, _call) => {
			await engine.connectors.disconnect((params as Params<"connectors.disconnect">).accountId);
			return {};
		},
		"connectors.configure": async (params, _call) => {
			const p = params as Params<"connectors.configure">;
			await engine.connectors.configure(p.connector, p);
			return {};
		},
		"connectors.calendars": async (params, _call) => {
			const p = params as Params<"connectors.calendars">;
			try {
				return { calendars: (await engine.connectors.calendarList(p.accountId)).map((c) => ({ id: c.id, name: c.name, primary: c.primary, enabled: c.enabled, ...(c.color ? { color: c.color } : {}) })) } satisfies Result<"connectors.calendars">;
			} catch (error) {
				throw new EngineError("INVALID", (error as Error).message);
			}
		},
		"connectors.setCalendar": async (params, _call) => {
			const p = params as Params<"connectors.setCalendar">;
			engine.connectors.setCalendar(p.accountId, p.calendarId, p.enabled);
			return {};
		},
	};
}
