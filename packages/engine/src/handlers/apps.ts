/**
 * The engine's `apps.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `apps.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { dirname, resolve } from "node:path";
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { AppConflict } from "../apps.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function appsHandlers(engine: Engine): Handlers<"apps"> {
	return {
		"apps.open": async (params, { conn }) => {
			const p = params as Params<"apps.open">;
			const app = appCall(engine, () => engine.apps.openApp(p.path));
			engine.appOpens.set(conn, [...(engine.appOpens.get(conn) ?? []), app.path]);
			return { app } satisfies Result<"apps.open">;
		},
		"apps.refresh": async (params, _call) => {
			return { app: await appCallAsync(engine, () => engine.apps.refresh((params as Params<"apps.refresh">).path)) } satisfies Result<"apps.refresh">;
		},
		"apps.allow": async (params, _call) => {
			return { app: await appCallAsync(engine, () => engine.apps.allow((params as Params<"apps.allow">).path)) } satisfies Result<"apps.allow">;
		},
		"apps.revoke": async (params, _call) => {
			return { app: appCall(engine, () => engine.apps.revoke((params as Params<"apps.revoke">).path)) } satisfies Result<"apps.revoke">;
		},
		"apps.conversation": async (params, _call) => {
			const path = resolve((params as Params<"apps.conversation">).path);
			const known = engine.apps.conversationOf(path);
			if (known && engine.sessions.list().some((s) => s.ref.id === known)) return { ref: { kind: "thread", id: known } } satisfies Result<"apps.conversation">;
			const app = await appCallAsync(engine, () => engine.apps.refresh(path));
			// In its project when it's in one (it reads the project's files); otherwise in its own folder.
			const cwd = engine.projects.projectFor(path)?.path ?? dirname(path);
			const ref = await engine.sessions.create({ kind: "thread", app: path, cwd, title: `${app.title} (app)` });
			engine.apps.setConversation(path, ref.id);
			return { ref } satisfies Result<"apps.conversation">;
		},
		"apps.undo": async (params, _call) => {
			const p = params as Params<"apps.undo">;
			try {
				return { app: engine.apps.undo(p.path, p.force ?? false) } satisfies Result<"apps.undo">;
			} catch (error) {
				throw new EngineError(error instanceof AppConflict ? "CONFLICT" : "INVALID", (error as Error).message);
			}
		},
		"apps.close": async (params, { conn }) => {
			const path = (params as Params<"apps.close">).path;
			const opens = engine.appOpens.get(conn) ?? [];
			const i = opens.findIndex((o) => o === path || o === resolve(path));
			if (i >= 0) {
				engine.apps.closeApp(opens[i]!);
				opens.splice(i, 1);
			}
			return {} satisfies Result<"apps.close">;
		},
	};
}

/** An app's errors as the client's to show (a missing file, a broken manifest). */
function appCall<T>(engine: Engine, f: () => T): T {
	try {
		return f();
	} catch (error) {
		throw new EngineError("INVALID", (error as Error).message);
	}
}

/** An automation as the app sees it: the record, and its words. */
async function appCallAsync<T>(engine: Engine, f: () => Promise<T>): Promise<T> {
	try {
		return await f();
	} catch (error) {
		throw new EngineError("INVALID", (error as Error).message);
	}
}
