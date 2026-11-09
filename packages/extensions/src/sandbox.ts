/**
 * piopio-sandbox: Build's shell commands run inside macOS's sandbox (Seatbelt, through `sandbox-exec`), so a command
 * the user approved, or one a rule allows, can only write inside the project (docs/research/deepseek-harness.md §1.1).
 *
 * - Everything else works as before: reading, the network, running tools. Writes are allowed in the project folder
 *   (the worktree for a worktree session, plus the repository's git folder), temporary folders and the usual package
 *   and build caches, so installs and builds keep working.
 * - A command that has to write somewhere else (a global install, a config file in the home folder) is run again with
 *   `outside_project: true`. That call always asks the user first, whatever the mode (Full access aside).
 * - When the sandbox can't start, nothing runs: the command fails with that reason, never silently unconfined.
 * - Full access, and the setting turned off, run commands as before.
 * - Tools that start their own macOS sandbox can't inside this one (macOS refuses a sandbox within a sandbox), so
 *   confined commands find `swift` and `xcodebuild` through small wrappers that turn theirs off (`SHIMS`). Their
 *   writes stay inside the project all the same.
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { createBashToolDefinition, getShellConfig, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export const SANDBOX_EXEC = "/usr/bin/sandbox-exec";
export const OUTSIDE_PROJECT = "outside_project";

export interface SandboxBridge {
	/** Confine this call? (the setting is on and the mode isn't Full access); read on every command. */
	enabled(): boolean;
	/** More folders commands may write to. */
	extraRoots?(): string[];
}

/** Caches and build folders under the home folder that installs and builds write to. */
const HOME_CACHES = [
	"Library/Caches",
	"Library/Developer/Xcode/DerivedData",
	"Library/org.swift.swiftpm",
	"Library/pnpm",
	".cache",
	".npm",
	".pnpm-store",
	".local/share/pnpm",
	".yarn",
	".bun",
	".deno",
	".cargo/registry",
	".cargo/git",
	"go/pkg",
	".gradle",
	".m2",
	".swiftpm",
	".nuget/packages",
	".pub-cache",
	".cocoapods",
];

function real(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return resolve(path);
	}
}

const gitDirs = new Map<string, string | undefined>();

/** The repository's shared git folder when it lies outside `cwd` (a worktree's commits are written there). */
function gitCommonDir(cwd: string): string | undefined {
	if (!gitDirs.has(cwd)) {
		const r = spawnSync("git", ["rev-parse", "--git-common-dir"], { cwd, encoding: "utf8", timeout: 5_000 });
		const out = r.status === 0 ? r.stdout.trim() : "";
		gitDirs.set(cwd, out ? real(isAbsolute(out) ? out : join(cwd, out)) : undefined);
	}
	return gitDirs.get(cwd);
}

/** Where a sandboxed command in `cwd` may write. */
export function sandboxRoots(cwd: string, options: { home?: string; tmp?: string; extra?: readonly string[] } = {}): string[] {
	const home = real(options.home ?? homedir());
	const roots = [real(cwd), gitCommonDir(cwd), real(options.tmp ?? tmpdir()), "/private/tmp", "/private/var/folders", ...HOME_CACHES.map((p) => join(home, p)), ...(options.extra ?? []).map(real)];
	const unique: string[] = [];
	for (const r of roots) if (r && !unique.includes(r)) unique.push(r);
	return unique;
}

/**
 * Wrappers for tools that start their own sandbox (found on real installs and builds, 2026-11-08):
 * - `swift build/test/run/package` sandbox the manifest and plugins: `--disable-sandbox`.
 * - `xcodebuild` resolving packages does the same, and Run Script phases with user script sandboxing are run sandboxed:
 *   two Xcode settings and `XBS_DISABLE_SANDBOXED_BUILDS`.
 * Each one runs the real tool, the next one on PATH after the wrappers' folder.
 */
export const SHIMS: Record<string, string> = {
	swift: 'case "$1" in build|test|run|package) sub="$1"; shift; set -- "$sub" --disable-sandbox "$@";; esac',
	xcodebuild: 'XBS_DISABLE_SANDBOXED_BUILDS=1; export XBS_DISABLE_SANDBOXED_BUILDS\nset -- -IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES "$@"',
};

function shimScript(tool: string, args: string): string {
	return `#!/bin/sh
# Piopio's sandbox: ${tool} can't start its own sandbox inside it, so it's turned off here. Piopio's still applies.
${args}
dir=$(cd "$(dirname "$0")" && pwd -P)
PATH=$(printf '%s' "$PATH" | tr ':' '\\n' | grep -vxF "$dir" | paste -sd: -)
export PATH
exec ${tool} "$@"
`;
}

let shims: string | undefined | null = null;

/** The wrappers' folder (written once per process), or undefined when it can't be written. */
export function sandboxShims(dir = join(tmpdir(), "piopio-sandbox-bin")): string | undefined {
	if (shims !== null) return shims;
	try {
		mkdirSync(dir, { recursive: true });
		for (const [tool, args] of Object.entries(SHIMS)) {
			const path = join(dir, tool);
			const script = shimScript(tool, args);
			let current = "";
			try {
				current = readFileSync(path, "utf8");
			} catch {
				/* not there yet */
			}
			if (current !== script) writeFileSync(path, script, { mode: 0o755 });
		}
		shims = real(dir);
	} catch {
		shims = undefined;
	}
	return shims;
}

/** A Seatbelt string literal. */
function sbpl(value: string): string {
	return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** The profile: everything allowed except writing outside `roots` (and devices such as /dev/null). */
export function seatbeltProfile(roots: readonly string[]): string {
	return ["(version 1)", "(allow default)", "(deny file-write*)", '(allow file-write* (subpath "/dev"))', `(allow file-write* ${roots.map((r) => `(subpath ${sbpl(r)})`).join(" ")})`].join("\n");
}

/** A POSIX shell word. */
export function shellQuote(value: string): string {
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

/** The command line that runs `command` with `shell` inside the profile, with the wrappers in `shimDir` first on PATH. */
export function confine(command: string, profile: string, shell: string, shimDir?: string): string {
	const inner = shimDir ? `PATH=${shellQuote(shimDir)}:"$PATH"; export PATH\n${command}` : command;
	return `exec ${SANDBOX_EXEC} -p ${shellQuote(profile)} ${shellQuote(shell)} -c ${shellQuote(inner)}`;
}

let probed: string | undefined | null = null;

/** Why the sandbox can't run here, or undefined when it can. Checked once per process. */
export function sandboxUnavailable(): string | undefined {
	if (probed !== null) return probed;
	if (process.platform !== "darwin" || !existsSync(SANDBOX_EXEC)) probed = "macOS's sandbox-exec isn't available";
	else {
		const r = spawnSync(SANDBOX_EXEC, ["-p", "(version 1)(allow default)", "/usr/bin/true"], { timeout: 5_000 });
		probed = r.status === 0 ? undefined : `sandbox-exec failed (${r.error?.message ?? (r.stderr?.toString().trim() || `exit ${r.status}`)})`;
	}
	return probed;
}

export const SANDBOX_GUIDELINE = `Commands run in a sandbox: they can read anything and use the network, but write only inside the project folder, temporary folders and package/build caches. If a command must write elsewhere (a global install, a file in the home folder), run it again with ${OUTSIDE_PROJECT}: true; the user is asked first.`;

const NESTED_HINT = `\n\n[A tool tried to start its own macOS sandbox, which can't run inside Piopio's ("sandbox_apply: Operation not permitted"). Piopio already turns it off for swift and xcodebuild. For another tool, look for its flag that disables its own sandbox and run it again; Piopio's sandbox still keeps writes inside the project.]`;

const DENIED_HINT = `\n\n[Piopio's sandbox stopped a write outside the project ("Operation not permitted"). If this command really has to write there, run it again with ${OUTSIDE_PROJECT}: true and the user will be asked. Otherwise write inside the project or a temporary folder.]`;

type Content = { type: string; text?: string }[];

export function sandboxExtension(bridge: SandboxBridge, options: { shellPath?: () => string | undefined } = {}): ExtensionFactory {
	return (pi) => {
		let cwd = process.cwd();
		const shell = () => getShellConfig(options.shellPath?.()).shell;
		const plain = createBashToolDefinition(cwd);
		const confined = createBashToolDefinition(cwd, {
			spawnHook: (context) => {
				const profile = seatbeltProfile(sandboxRoots(context.cwd, { extra: bridge.extraRoots?.() ?? [] }));
				return { ...context, command: confine(context.command, profile, shell(), sandboxShims()) };
			},
		});
		const parameters = Type.Object({
			...(plain.parameters as unknown as { properties: Record<string, never> }).properties,
			[OUTSIDE_PROJECT]: Type.Optional(Type.Boolean({ description: "Run without the sandbox, to write outside the project. The user is asked first. Only when a sandboxed run failed for that reason." })),
		});
		pi.on("session_start", (_event, ctx) => {
			cwd = ctx.cwd;
		});
		pi.registerTool({
			...plain,
			parameters: parameters as never,
			promptGuidelines: [...(plain.promptGuidelines ?? []), SANDBOX_GUIDELINE],
			async execute(toolCallId: string, params: unknown, signal: AbortSignal | undefined, onUpdate: never, ctx: never) {
				const { [OUTSIDE_PROJECT]: outside, ...input } = params as { command: string; timeout?: number; outside_project?: boolean };
				if (outside || !bridge.enabled()) return plain.execute(toolCallId, input as never, signal, onUpdate, ctx);
				const unavailable = sandboxUnavailable();
				if (unavailable) {
					// Elsewhere there is no sandbox to fall back from (the app ships on macOS; the suites run on Linux CI), and
					// refusing every command would only make the engine unusable there. On a Mac whose sandbox is broken, keep
					// stopping: running unsandboxed is not what the setting promised.
					if (process.platform !== "darwin") return plain.execute(toolCallId, input as never, signal, onUpdate, ctx);
					return { content: [{ type: "text", text: `Nothing ran: Piopio's sandbox can't start on this Mac (${unavailable}). Tell the user; they can turn the sandbox off in Settings › Approvals, or you can ask to run this with ${OUTSIDE_PROJECT}: true.` }], details: {}, isError: true } as never;
				}
				const result = await confined.execute(toolCallId, input as never, signal, onUpdate, ctx);
				const content = (result as { content?: Content }).content;
				const text = content?.map((c) => c.text ?? "").join("") ?? "";
				if ((result as { isError?: boolean }).isError && /Operation not permitted/.test(text)) {
					return { ...result, content: [...(content ?? []), { type: "text", text: /sandbox_apply/.test(text) ? NESTED_HINT : DENIED_HINT }] } as never;
				}
				return result;
			},
		} as never);
	};
}
