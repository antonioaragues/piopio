/**
 * Claude Code and Codex as subagents (docs/research/deepseek-harness.md §2.4): the `task` tool can hand a
 * self-contained task to the user's own `claude` or `codex` CLI, signed in with their own plan. The run is unattended
 * in the session's folder; only its final answer (and cost, when it reports one) comes back.
 *
 * Their permissions follow the session's approval mode:
 *
 * | Piopio    | Claude Code (`--permission-mode`) | Codex (`--sandbox`)  |
 * |-----------|-----------------------------------|----------------------|
 * | Read only | plan                              | read-only            |
 * | Ask       | acceptEdits (the task itself asks)| workspace-write      |
 * | Auto-edit | acceptEdits                       | workspace-write      |
 * | Full      | bypassPermissions                 | danger-full-access   |
 *
 * Found on PATH or in the usual install folders (an app-launched engine has a short PATH). Nothing is bundled.
 */
import { spawn } from "node:child_process";
import { accessSync, constants, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import type { ApprovalMode } from "@piopio/protocol";
import type { TaskResult } from "@piopio/pi-extensions";

export type ExternalAgent = "claude" | "codex";
export const EXTERNAL_AGENTS: readonly ExternalAgent[] = ["claude", "codex"];
export const AGENT_NAMES: Record<ExternalAgent, string> = { claude: "Claude Code", codex: "Codex" };

function executable(path: string): boolean {
	try {
		accessSync(path, constants.X_OK);
		return true;
	} catch {
		return false;
	}
}

/** Where a CLI is, or undefined. */
export function findAgent(name: ExternalAgent, env: NodeJS.ProcessEnv = process.env, home = homedir()): string | undefined {
	const dirs = [...(env.PATH ?? "").split(delimiter), join(home, ".local/bin"), join(home, ".claude/local"), "/opt/homebrew/bin", "/usr/local/bin", join(home, ".npm-global/bin"), join(home, ".bun/bin"), join(home, ".volta/bin")];
	for (const dir of dirs) if (dir && executable(join(dir, name))) return join(dir, name);
	return undefined;
}

/** The CLIs installed on this Mac. */
export function installedAgents(find: (name: ExternalAgent) => string | undefined = (n) => findAgent(n)): ExternalAgent[] {
	return EXTERNAL_AGENTS.filter((n) => find(n));
}

export function claudeArgs(prompt: string, mode: ApprovalMode): string[] {
	const permission = mode === "read_only" ? "plan" : mode === "full_auto" ? "bypassPermissions" : "acceptEdits";
	return ["-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", permission];
}

export function codexArgs(prompt: string, mode: ApprovalMode, cwd: string, lastMessageFile: string): string[] {
	const sandbox = mode === "read_only" ? "read-only" : mode === "full_auto" ? "danger-full-access" : "workspace-write";
	return ["exec", "--sandbox", sandbox, "--skip-git-repo-check", "-C", cwd, "--output-last-message", lastMessageFile, prompt];
}

/** A progress line from one line of Claude Code's stream-json, or undefined. */
export function claudeProgress(event: unknown): string | undefined {
	const e = event as { type?: string; message?: { content?: { type?: string; name?: string; input?: Record<string, unknown>; text?: string }[] } };
	if (e.type !== "assistant") return undefined;
	for (const c of e.message?.content ?? []) {
		if (c.type === "tool_use" && c.name) {
			const detail = [c.input?.command, c.input?.file_path, c.input?.pattern, c.input?.url, c.input?.description].find((v) => typeof v === "string") as string | undefined;
			return `${c.name}${detail ? ` ${detail.split("\n")[0]!.slice(0, 120)}` : ""}`;
		}
	}
	return undefined;
}

export type ExternalRun = { cwd: string; prompt: string; mode: ApprovalMode; signal?: AbortSignal; onProgress: (line: string) => void; path: string };

/** Runs the CLI to the end. Never rejects: failures come back as an "error" result the model reads. */
export function runExternalAgent(agent: ExternalAgent, run: ExternalRun): Promise<TaskResult> {
	const name = AGENT_NAMES[agent];
	const scratch = agent === "codex" ? mkdtempSync(join(tmpdir(), "piopio-codex-")) : undefined;
	const lastMessage = scratch ? join(scratch, "last-message.txt") : "";
	const args = agent === "claude" ? claudeArgs(run.prompt, run.mode) : codexArgs(run.prompt, run.mode, run.cwd, lastMessage);
	return new Promise((resolve) => {
		let settled = false;
		const finish = (result: TaskResult) => {
			if (settled) return;
			settled = true;
			if (scratch) rmSync(scratch, { recursive: true, force: true });
			resolve(result);
		};
		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(run.path, args, { cwd: run.cwd, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
		} catch (error) {
			finish({ text: `${name} couldn't start: ${error instanceof Error ? error.message : String(error)}`, sessionId: "", costUsd: 0, status: "error" });
			return;
		}
		run.onProgress(`${name} is working…`);
		let buffer = "";
		let stderr = "";
		let result: { text: string; cost: number; error: boolean } | undefined;
		let lastText = "";
		child.stdout!.setEncoding("utf8");
		child.stdout!.on("data", (chunk: string) => {
			buffer += chunk;
			let nl: number;
			while ((nl = buffer.indexOf("\n")) >= 0) {
				const line = buffer.slice(0, nl).trim();
				buffer = buffer.slice(nl + 1);
				if (!line) continue;
				if (agent === "codex") {
					run.onProgress(line.slice(0, 160));
					lastText = line;
					continue;
				}
				try {
					const event = JSON.parse(line) as { type?: string; result?: string; total_cost_usd?: number; is_error?: boolean };
					if (event.type === "result") result = { text: event.result ?? "", cost: event.total_cost_usd ?? 0, error: event.is_error === true };
					const progress = claudeProgress(event);
					if (progress) run.onProgress(progress);
				} catch {
					/* not JSON: ignore */
				}
			}
		});
		child.stderr!.setEncoding("utf8");
		child.stderr!.on("data", (chunk: string) => {
			stderr = (stderr + chunk).slice(-4000);
		});
		const stop = () => child.kill("SIGTERM");
		run.signal?.addEventListener("abort", stop, { once: true });
		child.on("error", (error) => finish({ text: `${name} couldn't start: ${error.message}`, sessionId: "", costUsd: 0, status: "error" }));
		child.on("close", (code) => {
			run.signal?.removeEventListener("abort", stop);
			if (run.signal?.aborted) return finish({ text: "", sessionId: "", costUsd: 0, status: "stopped" });
			if (agent === "claude" && result) return finish({ text: result.text, sessionId: "", costUsd: result.cost, status: result.error ? "error" : "done" });
			if (agent === "codex" && code === 0) {
				let text = lastText;
				try {
					text = readFileSync(lastMessage, "utf8").trim() || lastText;
				} catch {
					/* no file: the last line printed */
				}
				return finish({ text, sessionId: "", costUsd: 0, status: "done" });
			}
			finish({ text: `${name} exited with code ${code}${stderr.trim() ? `: ${stderr.trim().split("\n").slice(-5).join("\n")}` : ""}`, sessionId: "", costUsd: 0, status: "error" });
		});
	});
}
