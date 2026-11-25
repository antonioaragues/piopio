/**
 * The engine's `packages.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `packages.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function packagesHandlers(engine: Engine): Handlers<"packages"> {
	return {
		"packages.preview": async (params, _call) => {
			return (await engine.packages.preview((params as Params<"packages.preview">).source)) satisfies Result<"packages.preview">;
		},
		"packages.setResource": async (params, _call) => {
			const p = params as Params<"packages.setResource">;
			await engine.packages.setResource(p.source, p.kind, p.path, p.enabled);
			return {};
		},
		"packages.list": async (_params, _call) => {
			return { packages: await engine.packages.list() } satisfies Result<"packages.list">;
		},
		"packages.install": async (params, _call) => {
			const p = params as Params<"packages.install">;
			await engine.packages.install(p.source);
			return {};
		},
		"packages.remove": async (params, _call) => {
			const p = params as Params<"packages.remove">;
			await engine.packages.remove(p.source);
			return {};
		},
		"packages.update": async (params, _call) => {
			const p = params as Params<"packages.update">;
			await engine.packages.update(p.source);
			return {};
		},
		"packages.setEnabled": async (params, _call) => {
			const p = params as Params<"packages.setEnabled">;
			await engine.packages.setEnabled(p.source, p.enabled, p.kinds);
			return {};
		},
	};
}
