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
 */
import { spawnSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
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

/** The command line that runs `command` with `shell` inside the profile. */
export function confine(command: string, profile: string, shell: string): string {
	return `exec ${SANDBOX_EXEC} -p ${shellQuote(profile)} ${shellQuote(shell)} -c ${shellQuote(command)}`;
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
				return { ...context, command: confine(context.command, profile, shell()) };
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
					return { content: [{ type: "text", text: `Nothing ran: Piopio's sandbox can't start on this Mac (${unavailable}). Tell the user; they can turn the sandbox off in Settings › Build, or you can ask to run this with ${OUTSIDE_PROJECT}: true.` }], details: {}, isError: true } as never;
				}
				const result = await confined.execute(toolCallId, input as never, signal, onUpdate, ctx);
				const content = (result as { content?: Content }).content;
				const text = content?.map((c) => c.text ?? "").join("") ?? "";
				if ((result as { isError?: boolean }).isError && /Operation not permitted/.test(text)) {
					return { ...result, content: [...(content ?? []), { type: "text", text: DENIED_HINT }] } as never;
				}
				return result;
			},
		} as never);
	};
}
