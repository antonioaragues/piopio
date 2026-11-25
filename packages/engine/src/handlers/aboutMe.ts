/**
 * The engine's `aboutMe.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `aboutMe.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function aboutMeHandlers(engine: Engine): Handlers<"aboutMe"> {
	return {
		"aboutMe.get": async (_params, _call) => {
			return (await engine.aboutMe.info()) satisfies Result<"aboutMe.get">;
		},
		"aboutMe.set": async (params, _call) => {
			const p = params as Params<"aboutMe.set">;
			await engine.aboutMe.set(p.text);
			return {};
		},
		"aboutMe.undo": async (params, _call) => {
			const p = params as Params<"aboutMe.undo">;
			await engine.aboutMe.undo(p.revisionId);
			return {};
		},
	};
}
