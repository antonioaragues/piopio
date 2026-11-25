/**
 * The engine's `library.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `library.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { Library } from "../library.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function libraryHandlers(engine: Engine): Handlers<"library"> {
	return {
		"library.list": async (_params, _call) => {
			return library(engine).list() satisfies Result<"library.list">;
		},
		"library.pin": async (params, _call) => {
			const p = params as Params<"library.pin">;
			libraryCall(engine, () => library(engine).pin(p.id, p.pinned));
			return {} satisfies Result<"library.pin">;
		},
		"library.reorder": async (params, _call) => {
			library(engine).reorder((params as Params<"library.reorder">).ids);
			return {} satisfies Result<"library.reorder">;
		},
		"library.remove": async (params, _call) => {
			libraryCall(engine, () => library(engine).remove((params as Params<"library.remove">).id));
			return {} satisfies Result<"library.remove">;
		},
		"library.add": async (params, _call) => {
			const p = params as Params<"library.add">;
			return { item: libraryCall(engine, () => library(engine).add(p.path)) } satisfies Result<"library.add">;
		},
		"library.visual": async (params, _call) => {
			const p = params as Params<"library.visual">;
			return libraryCall(engine, () => library(engine).visual(p.id)) satisfies Result<"library.visual">;
		},
		"library.restore": async (params, _call) => {
			libraryCall(engine, () => library(engine).restore((params as Params<"library.restore">).id));
			return {} satisfies Result<"library.restore">;
		},
		"library.saved": async (params, _call) => {
			const p = params as Params<"library.saved">;
			const item = library(engine).saved(p.callId, p.path);
			return (item ? { item } : {}) satisfies Result<"library.saved">;
		},
		"library.relocate": async (params, _call) => {
			const p = params as Params<"library.relocate">;
			return { item: libraryCall(engine, () => library(engine).relocate(p.id, p.path)) } satisfies Result<"library.relocate">;
		},
	};
}

function library(engine: Engine): Library {
	return engine.sessions.library!;
}

/** A Library change that can fail for a reason you should read (no file there). */
function libraryCall<T>(engine: Engine, f: () => T): T {
	try {
		return f();
	} catch (error) {
		throw new EngineError("INVALID", (error as Error).message);
	}
}
