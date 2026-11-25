/**
 * The engine's `hooks.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `hooks.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { basename, dirname, join } from "node:path";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { type Params, type Result } from "@piopio/protocol";
import { physical, projectPath } from "@piopio/pi-extensions";
import { EngineError } from "../models.js";
import { moveToTrash } from "../sessions.js";
import { claudeHooks, hookSentence, listHooks, sampleFile, toggleHook, writeHook } from "../user-hooks.js";
import type { HookSpec } from "@piopio/protocol";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function hooksHandlers(engine: Engine): Handlers<"hooks"> {
	return {
		"hooks.list": async (params, _call) => {
			const p = params as Params<"hooks.list">;
			const hooks = [
				...listHooks(hooksDir(engine)).map((h) => ({ ...h, where: "yours" as const })),
				// A project whose .pi/extensions leads outside it has no hooks of its own to show (hooksDir refuses it).
				...(p.project && projectPath(p.project, join(".pi", "extensions")) ? listHooks(hooksDir(engine, p.project)).map((h) => ({ ...h, where: "project" as const })) : []),
			];
			const claude = p.project ? claudeHooks(p.project).map((spec) => ({ spec, sentence: hookSentence(spec) })) : [];
			return { hooks, claude } satisfies Result<"hooks.list">;
		},
		"hooks.save": async (params, _call) => {
			const p = params as Params<"hooks.save">;
			if (p.path) ownHook(engine, p.path);
			const path = writeHook(p.path ? dirname(p.path) : hooksDir(engine, p.project), p.spec, p.path);
			await engine.skillsChanged();
			return { path } satisfies Result<"hooks.save">;
		},
		"hooks.toggle": async (params, _call) => {
			const p = params as Params<"hooks.toggle">;
			ownHook(engine, p.path);
			const path = toggleHook(p.path, p.on);
			await engine.skillsChanged();
			return { path } satisfies Result<"hooks.toggle">;
		},
		"hooks.delete": async (params, _call) => {
			const p = params as Params<"hooks.delete">;
			ownHook(engine, p.path);
			moveToTrash(p.path, engine.options.trashDir ?? join(homedir(), ".Trash"));
			await engine.skillsChanged();
			return {} satisfies Result<"hooks.delete">;
		},
		"hooks.try": async (params, _call) => {
			return (await tryHook(engine, (params as Params<"hooks.try">).spec, (params as Params<"hooks.try">).project)) satisfies Result<"hooks.try">;
		},
		"hooks.importClaude": async (params, _call) => {
			const p = params as Params<"hooks.importClaude">;
			const paths = claudeHooks(p.project).map((spec) => writeHook(hooksDir(engine, p.project), spec));
			await engine.skillsChanged();
			return { paths } satisfies Result<"hooks.importClaude">;
		},
	};
}

/**
 * Where hooks live (PAR6): pi's extension folders, yours or a project's. A project's must really be in the project
 * (paths.ts `projectPath`): through a repository's `.pi/extensions -> ~/.pi/agent/extensions`, a hook written for
 * one project would run in all of them, trusted or not.
 */
function hooksDir(engine: Engine, project?: string): string {
	if (!project) return join(engine.chatResources.agentDir, "extensions");
	const dir = projectPath(project, join(".pi", "extensions"));
	if (!dir) throw new EngineError("INVALID", "This project's .pi/extensions is a link to a folder outside it, so Piopio won't put hooks there.");
	return dir;
}

/** A hook file Piopio may change: a hook-*.ts whose folder really is your extensions folder or a known project's. */
function ownHook(engine: Engine, path: string): void {
	const dir = physical(dirname(path));
	const name = basename(path);
	const project = engine.projectOf(path);
	const allowed = [hooksDir(engine), ...(project ? [hooksDir(engine, project)] : [])].map((d) => physical(d));
	if (!/^hook-.+\.ts(\.off)?$/.test(name) || !allowed.includes(dir) || !existsSync(path)) throw new EngineError("INVALID", "That isn't one of your hooks.");
}

/** Runs a hook's command once (PAR6 "Try it"), on a file it would match when the project has one. */
async function tryHook(engine: Engine, spec: HookSpec, project?: string): Promise<{ code: number; output: string; ms: number; file?: string }> {
	if (!spec.run?.trim()) return { code: 0, output: spec.stop ? `It stops the tool with: ${spec.stop}` : "", ms: 0 };
	const cwd = project ?? homedir();
	const file = spec.files && project ? sampleFile(project, spec.files) : undefined;
	const started = Date.now();
	const { spawn } = await import("node:child_process");
	return await new Promise((done) => {
		const child = spawn("/bin/sh", ["-c", spec.run!], { cwd, env: { ...process.env, ...(file ? { FILE: file } : {}), COMMAND: spec.command?.replace(/\*/g, "") ?? "" } });
		let output = "";
		const take = (b: Buffer) => {
			if (output.length < 8000) output += b.toString();
		};
		child.stdout.on("data", take);
		child.stderr.on("data", take);
		const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
		child.on("close", (code) => {
			clearTimeout(timer);
			done({ code: code ?? 1, output: output.trim(), ms: Date.now() - started, ...(file ? { file } : {}) });
		});
		child.on("error", (e) => {
			clearTimeout(timer);
			done({ code: 1, output: String(e), ms: Date.now() - started });
		});
		child.stdin.end(JSON.stringify({ try: true, ...(file ? { file } : {}) }));
	});
}
