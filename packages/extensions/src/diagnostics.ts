/**
 * piopio-diagnostics: the project's own check after the agent's edits (docs/spec/05-build "Diagnostics", roadmap PAR5).
 * When a run that edited files is about to end, Piopio runs the project's check command (its type checker or compiler:
 * a `typecheck` script, `tsc`, `cargo check`, `go vet`), and if it reports problems in the files the agent changed, the
 * run goes on with them, so the agent fixes them before it answers. At most twice per message from the user. Before the
 * message's first edit the check runs once more, as a baseline: problems in files it didn't touch count only when they
 * weren't there then (a check slower than 20 s skips the baseline, and those files are left alone).
 */
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

export const DIAGNOSTICS_ENTRY = "piopio.diagnostics";
export const MAX_CHECK_ROUNDS = 2;
/** A check slower than this (its last run) gets no baseline before the first edit: only the edited files count. */
export const BASELINE_MAX_MS = 20_000;
const TIMEOUT_MS = 120_000;
const MAX_LINES = 60;

/** The project's check, guessed from its files; undefined when there's no obvious one. */
export function detectCheck(cwd: string): string | undefined {
	const has = (file: string) => existsSync(join(cwd, file));
	if (has("package.json")) {
		let scripts: Record<string, string> = {};
		try {
			scripts = (JSON.parse(readFileSync(join(cwd, "package.json"), "utf8")) as { scripts?: Record<string, string> }).scripts ?? {};
		} catch {
			/* not JSON */
		}
		const pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun" : "npm";
		for (const name of ["typecheck", "type-check", "check:types", "check"]) if (scripts[name]) return `${pm} run ${name}`;
		if (has("tsconfig.json") && has("node_modules/.bin/tsc")) return "node_modules/.bin/tsc --noEmit -p .";
	}
	if (has("Cargo.toml")) return "cargo check --quiet --message-format short";
	if (has("go.mod")) return "go vet ./...";
	if (has("pyrightconfig.json")) return "pyright";
	if (has("mypy.ini")) return "mypy .";
	return undefined;
}

const LOCATION = /((?:\/?[\w@.~-]+\/)*[\w@.~-]+\.[A-Za-z0-9]+)(?:\(\d+,\d+\)|:\d+(?::\d+)?)/;
const lineSplit = (output: string) => output.replace(/\x1b\[[0-9;]*m/g, "").split("\n");
const relPath = (path: string, cwd: string) => (isAbsolute(path) ? relative(cwd, path) : path.replace(/^\.\//, "")).replace(/\\/g, "/");

/**
 * What a problem is, wherever its line moves: the file and the message without its line and column (Rust's message is
 * on the line before its `-->`).
 */
function problemKey(lines: readonly string[], i: number, cwd: string): string | undefined {
	const m = LOCATION.exec(lines[i]!);
	if (!m) return undefined;
	let message = lines[i]!.replace(m[0], "").replace(/^[\s:>-]+/, "").trim();
	if (!message && i > 0) message = lines[i - 1]!.trim();
	return `${relPath(m[1]!, cwd)}|${message.replace(/\s+/g, " ")}`;
}

/** The problems a check's output names, as `problemKey`s: the baseline that later output is compared with. */
export function problemKeys(output: string, cwd: string): Set<string> {
	const lines = lineSplit(output);
	return new Set(lines.flatMap((_, i) => problemKey(lines, i, cwd) ?? []));
}

/**
 * The lines of a check's output about these files: each line that names one (`src/a.ts(10,5): error…`,
 * `src/a.ts:10:5: error…`, `--> src/main.rs:10:5`), with the line before (Rust puts the message there) and the two
 * after. With a `baseline` (the check's problems before the agent's first edit), also each problem elsewhere that
 * wasn't there then: a change can break a file it didn't touch. Capped.
 */
export function problemsIn(output: string, files: readonly string[], cwd: string, baseline?: ReadonlySet<string>): string[] {
	const names = files.map((f) => relative(cwd, f)).filter((f) => f && !f.startsWith("..")).map((n) => n.replace(/\\/g, "/"));
	if (!names.length && !baseline) return [];
	const lines = lineSplit(output);
	const keep = new Set<number>();
	const pathOf = (line: string) => LOCATION.exec(line)?.[1];
	const ours = (path: string) => {
		const rel = relPath(path, cwd);
		return names.some((n) => rel === n || rel.endsWith(`/${n}`) || n.endsWith(`/${rel}`));
	};
	lines.forEach((line, i) => {
		const path = pathOf(line);
		if (!path) return;
		if (!ours(path) && !(baseline && !baseline.has(problemKey(lines, i, cwd)!))) return;
		keep.add(i);
		// Context: the line before (Rust's message) and two after, unless they name another place.
		for (const j of [i - 1, i + 1, i + 2]) {
			const other = lines[j];
			if (other === undefined || !other.trim()) continue;
			if (pathOf(other)) break;
			keep.add(j);
		}
	});
	return [...keep].sort((a, b) => a - b).map((i) => lines[i]!).slice(0, MAX_LINES);
}

export type CheckRun = { code: number | null; output: string; timedOut: boolean };

/** Runs a command with a shell in `cwd`, output and errors together, with a time limit. */
export function runCheck(commandLine: string, cwd: string, shell: string, signal?: AbortSignal, timeoutMs = TIMEOUT_MS): Promise<CheckRun> {
	return new Promise((done) => {
		const child = spawn(shell, ["-c", commandLine], { cwd, env: { ...process.env, FORCE_COLOR: "0", NO_COLOR: "1", CI: "1" }, detached: true, stdio: ["ignore", "pipe", "pipe"] });
		let output = "";
		let timedOut = false;
		const take = (d: Buffer) => {
			if (output.length < 400_000) output += d.toString("utf8");
		};
		child.stdout.on("data", take);
		child.stderr.on("data", take);
		const kill = () => {
			try {
				if (child.pid) process.kill(-child.pid, "SIGKILL");
			} catch {
				child.kill("SIGKILL");
			}
		};
		const timer = setTimeout(() => {
			timedOut = true;
			kill();
		}, timeoutMs);
		signal?.addEventListener("abort", kill, { once: true });
		child.on("error", (e) => (output += e.message));
		child.on("close", (code) => {
			clearTimeout(timer);
			done({ code, output, timedOut });
		});
	});
}

export interface DiagnosticsBridge {
	/** The command to run for this folder now (the project's setting or what was detected), or undefined: off. */
	command(cwd: string): string | undefined;
	/** The command line to run, confined when the sandbox is on. */
	wrap?(command: string, cwd: string): string;
	shell?(): string;
}

const EDIT_TOOLS = new Set(["edit", "write"]);

export function diagnosticsExtension(bridge: DiagnosticsBridge): ExtensionFactory {
	return (pi) => {
		let cwd = process.cwd();
		const edited = new Set<string>();
		let rounds = 0;
		// The check's problems before this message's first edit (null: none taken, the check was slow or timed out).
		let baseline: Set<string> | null | undefined;
		let lastMs = 0;
		const check = async (command: string, signal?: AbortSignal) => {
			const started = Date.now();
			const run = await runCheck(bridge.wrap ? bridge.wrap(command, cwd) : command, cwd, bridge.shell?.() ?? process.env.SHELL ?? "/bin/sh", signal);
			lastMs = Date.now() - started;
			return run;
		};
		pi.on("session_start", (_e, ctx) => {
			cwd = ctx.cwd;
		});
		pi.on("tool_call", async (event, ctx) => {
			const e = event as unknown as { toolName: string };
			if (!EDIT_TOOLS.has(e.toolName) || baseline !== undefined) return undefined;
			const command = bridge.command(cwd);
			if (!command || lastMs > BASELINE_MAX_MS) {
				baseline = null;
				return undefined;
			}
			const run = await check(command, (ctx as { signal?: AbortSignal }).signal);
			baseline = run.timedOut ? null : problemKeys(run.output, cwd);
			return undefined;
		});
		pi.on("tool_result", (event) => {
			const e = event as unknown as { toolName: string; input?: { path?: unknown }; isError?: boolean };
			if (!EDIT_TOOLS.has(e.toolName) || e.isError || typeof e.input?.path !== "string") return undefined;
			edited.add(resolve(cwd, e.input.path));
			return undefined;
		});
		pi.on("input", () => {
			rounds = 0;
			baseline = undefined;
			return { action: "continue" } as never;
		});
		pi.on("agent_before_settle", async (event, ctx) => {
			const e = event as unknown as { outcome?: string; entries?: unknown[] };
			if (e.outcome && e.outcome !== "completed") return undefined;
			if (!edited.size) return undefined;
			const command = bridge.command(cwd);
			const files = [...edited];
			edited.clear();
			if (!command) return undefined;
			const run = await check(command, (ctx as { signal?: AbortSignal }).signal);
			if (run.timedOut || run.code === 0) return undefined;
			const problems = problemsIn(run.output, files, cwd, baseline ?? undefined);
			if (!problems.length) return undefined;
			const count = problems.filter((l) => /\berror\b/i.test(l)).length || problems.length;
			const plural = count === 1 ? "" : "s";
			const summary = `Checked with ${command}: ${baseline ? `${count} new problem${plural} since its first edit` : `${count} problem${plural} in files it changed`}`;
			if (rounds >= MAX_CHECK_ROUNDS) {
				return { entries: [...(e.entries ?? []), { type: "custom_message", customType: DIAGNOSTICS_ENTRY, content: `${summary}. Piopio stopped asking after ${MAX_CHECK_ROUNDS} rounds.`, display: true, details: { summary: `${summary} (left for you)` } }] } as never;
			}
			rounds++;
			const intro = baseline
				? `The project's check (\`${command}\`) reports problems that weren't there before your first edit (in files you changed, or files your changes broke):`
				: `The project's check (\`${command}\`) reports problems in files you changed:`;
			const content = [intro, "```", ...problems, "```", "Fix them, then finish. If one is wrong or can't be fixed here, say so instead."].join("\n");
			return { entries: [...(e.entries ?? []), { type: "custom_message", customType: DIAGNOSTICS_ENTRY, content, display: true, details: { summary } }], continue: true } as never;
		});
	};
}
