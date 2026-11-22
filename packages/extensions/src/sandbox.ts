/**
 * piopio-sandbox: Build's shell commands run inside macOS's sandbox (Seatbelt, through `sandbox-exec`), so a command
 * the user approved, or one a rule allows, can only write inside the project (docs/research/deepseek-harness.md §1.1).
 *
 * - Reading Piopio's own data folder (the engine's token and socket among it) and AI and cloud sign-in files is refused
 *   too, so a confined command can't talk to the engine or take keys (`sandboxHidden`).
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
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { createBashToolDefinition, getShellConfig, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { startedText, type ProcessManager } from "./background.js";

export const SANDBOX_EXEC = "/usr/bin/sandbox-exec";
export const OUTSIDE_PROJECT = "outside_project";

export interface SandboxBridge {
	/** Confine this call? (the setting is on and the mode isn't Full access); read on every command. */
	enabled(): boolean;
	/** More folders commands may write to. */
	extraRoots?(): string[];
	/**
	 * The project's network is filtered (docs/spec/39): commands reach the internet only through this proxy, which lets
	 * through the hosts allowed and asks about others. Undefined: the network is open. Read on every command.
	 */
	network?(): Promise<FilteredNetwork | undefined>;
}

/**
 * A filtered network: the proxy's port (none when it couldn't start: then nothing outside this Mac is reachable), and
 * the hosts it refused since a moment, to tell the agent what stopped a command.
 */
export type FilteredNetwork = { port?: number; refusedSince(at: number): string[] };

/** The variables tools read their proxy from; Node's fetch reads them only with NODE_USE_ENV_PROXY. */
export function proxyEnv(port: number): Record<string, string> {
	const url = `http://127.0.0.1:${port}`;
	return { HTTP_PROXY: url, HTTPS_PROXY: url, http_proxy: url, https_proxy: url, ALL_PROXY: url, all_proxy: url, NO_PROXY: "localhost,127.0.0.1,::1", no_proxy: "localhost,127.0.0.1,::1", NODE_USE_ENV_PROXY: "1" };
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

/** Piopio's data folder, as the engine has it (`PIOPIO_HOME`, set by the app). */
function piopioHome(home = homedir()): string {
	return process.env.PIOPIO_HOME ?? join(home, "Library", "Application Support", "Piopio");
}

/**
 * Where the wrappers live: in Piopio's data folder, which confined commands can't write to (they come first on PATH, so
 * a folder they could write, like the temporary one, would let one command plant a fake `git` for every later one).
 * The profile lets commands read this one folder.
 */
export function sandboxShimsDir(): string {
	return join(piopioHome(), "sandbox-bin");
}

/** The wrappers' folder (written once per process), or undefined when it can't be written. */
export function sandboxShims(dir = sandboxShimsDir()): string | undefined {
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

/** Files of plain-text credentials that builds and tests don't read: git's and netrc's passwords, registry tokens. */
const CREDENTIAL_FILES = [".netrc", ".git-credentials", ".pypirc", ".gem/credentials"];

/**
 * What sandboxed commands may not read or connect to: Piopio's own data folder (the engine's token and socket, every
 * chat, agent and secret it keeps), the sign-ins of AI tools and cloud CLIs, plain-text credentials and SSH private
 * keys. Without this a confined command could read the token, talk to the engine and change its own permissions, or
 * take the user's keys and send them anywhere (the network is open).
 * Left readable on purpose: the rest of ~/.ssh (config, known_hosts, public keys) and ~/.gnupg, so git over SSH (with
 * the agent's keys) and signed commits work; the keychains, which code signing needs.
 */
export function sandboxHidden(options: { home?: string; piopioHome?: string } = {}): string[] {
	const home = options.home ?? homedir();
	const piopio = options.piopioHome ?? piopioHome(home);
	return [piopio, join(home, ".pi", "agent", "auth.json"), join(home, ".codex", "auth.json"), join(home, ".aws"), ...CREDENTIAL_FILES.map((f) => join(home, f)), ...sshPrivateKeys(home)].map(real);
}

/** The private keys in ~/.ssh, whatever they're named: the files that start like one. */
function sshPrivateKeys(home: string): string[] {
	const dir = join(home, ".ssh");
	let names: string[];
	try {
		names = readdirSync(dir);
	} catch {
		return [];
	}
	const keys: string[] = [];
	for (const name of names) {
		const path = join(dir, name);
		try {
			if (!statSync(path).isFile()) continue;
			const fd = openSync(path, "r");
			const head = Buffer.alloc(64);
			try {
				readSync(fd, head, 0, 64, 0);
			} finally {
				closeSync(fd);
			}
			if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(head.toString("latin1"))) keys.push(path);
		} catch {
			// unreadable: nothing to hide
		}
	}
	return keys;
}

/**
 * The Keychain's command-line tool. gh keeps its GitHub token in the Keychain and reads it with this, so did git (gh is
 * its credential helper), and a sandboxed `gh auth token` printed it. Code signing reads the Keychain through the
 * framework, not this, so builds still sign. Inside the sandbox gh and git over HTTPS act signed out; a push or a call
 * that needs the account runs again outside it, which asks the user.
 */
export const KEYCHAIN_TOOL = "/usr/bin/security";

/**
 * The profile: everything allowed except writing outside `roots` (and devices such as /dev/null), and reading, writing
 * or connecting to sockets in `hidden`, wherever it lies (a dev copy of Piopio's data can sit in a temporary folder).
 * A root inside a hidden folder (a chat's scratch folder, a worktree in Piopio's data) stays readable and writable; the
 * `readable` folders there (the wrappers) stay readable only.
 * Reading in `hidden` is refused for contents (`file-read-data`: files and folder listings), not metadata: tools that
 * resolve their working folder (`realpath`, `git`) stat each folder above it. Later rules win in Seatbelt, but only over
 * a rule for the same operation, so each allow names the operation its deny does.
 */
export function seatbeltProfile(roots: readonly string[], hidden: readonly string[] = sandboxHidden(), readable: readonly string[] = [real(sandboxShimsDir())], filtered = false): string {
	const subpaths = (paths: readonly string[]) => paths.map((p) => `(subpath ${sbpl(p)})`).join(" ");
	const lines = ["(version 1)", "(allow default)", "(deny file-write*)", '(allow file-write* (subpath "/dev"))', `(allow file-write* ${subpaths(roots)})`, `(deny process-exec (literal ${sbpl(KEYCHAIN_TOOL)}))`];
	if (hidden.length) {
		lines.push(`(deny file-read-data file-write* ${subpaths(hidden)})`, `(deny network-outbound ${hidden.map((p) => `(remote unix-socket (subpath ${sbpl(p)}))`).join(" ")})`);
		const within = (paths: readonly string[]) => paths.filter((r) => hidden.some((h) => r.startsWith(`${h}/`)));
		const rootsInside = within(roots);
		const readInside = within([...roots, ...readable]);
		if (readInside.length) lines.push(`(allow file-read-data ${subpaths(readInside)})`);
		if (rootsInside.length) lines.push(`(allow file-write* ${subpaths(rootsInside)})`);
	}
	// A filtered network (docs/spec/39): no address but this Mac's, where dev servers, tests and the filter's proxy are.
	// Unix sockets (DNS, ssh-agent) aren't addresses; the hidden ones stay refused above.
	if (filtered) lines.push('(deny network-outbound (remote ip "*:*"))', '(allow network-outbound (remote ip "localhost:*"))');
	return lines.join("\n");
}

/** A POSIX shell word. */
export function shellQuote(value: string): string {
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

/**
 * The command line that runs `command` with `shell` inside the profile, with the wrappers in `shimDir` first on PATH and
 * `env` set (a filtered network's proxy).
 */
export function confine(command: string, profile: string, shell: string, shimDir?: string, env: Record<string, string> = {}): string {
	const exports = Object.entries(env).map(([k, v]) => `${k}=${shellQuote(v)}; export ${k}\n`).join("");
	const inner = exports + (shimDir ? `PATH=${shellQuote(shimDir)}:"$PATH"; export PATH\n${command}` : command);
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

export const SANDBOX_GUIDELINE = `Commands run in a sandbox: they can read almost anything (not Piopio's own data, sign-ins and credentials: gh and git over HTTPS are signed out there) and use the network (in a project that isn't trusted yet, only package registries, GitHub and the sites the user allows: Piopio asks them about others), but write only inside the project folder, temporary folders and package/build caches. If a command must write elsewhere (a global install, a file in the home folder), run it again with ${OUTSIDE_PROJECT}: true; the user is asked first.`;

const NESTED_HINT = `\n\n[A tool tried to start its own macOS sandbox, which can't run inside Piopio's ("sandbox_apply: Operation not permitted"). Piopio already turns it off for swift and xcodebuild. For another tool, look for its flag that disables its own sandbox and run it again; Piopio's sandbox still keeps writes inside the project.]`;

const DENIED_HINT = `\n\n[Piopio's sandbox stopped a write outside the project, or a read of Piopio's own data or a sign-in file ("Operation not permitted"). If this command really has to do that, run it again with ${OUTSIDE_PROJECT}: true and the user will be asked. Otherwise write inside the project or a temporary folder.]`;

const SIGNED_OUT_HINT = `\n\n[Inside Piopio's sandbox gh and git over HTTPS are signed out: the Keychain, where their GitHub sign-in is, is out of reach. Don't ask the user to sign in. If this needs their account (a push, a pull request, a private repository), run it again with ${OUTSIDE_PROJECT}: true and the user will be asked.]`;

/** What to add to a confined command's failure, so the agent knows what stopped it and what to do. */
export function sandboxHint(output: string): string | undefined {
	if (/sandbox_apply/.test(output)) return NESTED_HINT;
	if (/no oauth token found|gh auth login|could not read Username|Authentication failed|terminal prompts disabled|Bad credentials|HTTP 401/i.test(output)) return SIGNED_OUT_HINT;
	if (/Operation not permitted/.test(output)) return DENIED_HINT;
	return undefined;
}

/** What stopped a command in a filtered project: the hosts the filter didn't let through. */
export function networkHint(hosts: readonly string[]): string {
	return `\n\n[Piopio's network filter kept this command from reaching ${hosts.join(", ")}. This project isn't trusted yet, so its commands reach only package registries, GitHub and the sites the user allowed; the user was asked about these and said no, or the run stopped. Don't look for another way to reach them: tell the user if the work needs them (they can allow the site, or trust the project in Settings › Approvals).]`;
}

type Content = { type: string; text?: string }[];

export function sandboxExtension(bridge: SandboxBridge, options: { shellPath?: () => string | undefined; processes?: () => ProcessManager } = {}): ExtensionFactory {
	return (pi) => {
		let cwd = process.cwd();
		const shell = () => getShellConfig(options.shellPath?.()).shell;
		const plain = createBashToolDefinition(cwd);
		// The network as the next command gets it, read just before it starts (the spawn hook can't wait).
		let network: FilteredNetwork | undefined;
		const line = (command: string, at: string) => {
			const profile = seatbeltProfile(sandboxRoots(at, { extra: bridge.extraRoots?.() ?? [] }), undefined, undefined, network !== undefined);
			return confine(command, profile, shell(), sandboxShims(), network?.port ? proxyEnv(network.port) : {});
		};
		// A proxy that can't start still filters: nothing outside this Mac, rather than everything.
		const readNetwork = async () => (network = bridge.network ? await bridge.network().catch((): FilteredNetwork => ({ refusedSince: () => [] })) : undefined);
		const confined = createBashToolDefinition(cwd, {
			spawnHook: (context) => ({ ...context, command: line(context.command, context.cwd) }),
		});
		const parameters = Type.Object({
			...(plain.parameters as unknown as { properties: Record<string, never> }).properties,
			description: Type.Optional(Type.String({ description: "A short activity label in the user's language, 3–8 words, e.g. 'Checking the project tests'. Describe the task, not the shell syntax." })),
			[OUTSIDE_PROJECT]: Type.Optional(Type.Boolean({ description: "Run without the sandbox, to write outside the project. The user is asked first. Only when a sandboxed run failed for that reason." })),
			...(options.processes
				? { background: Type.Optional(Type.Boolean({ description: "Keep it running and return at once (a dev server, a watcher, a long test run): you get its id and first output; read more with process_output, stop it with process_stop." })) }
				: {}),
		});
		pi.on("session_start", (_event, ctx) => {
			cwd = ctx.cwd;
		});
		pi.registerTool({
			...plain,
			parameters: parameters as never,
			promptGuidelines: [...(plain.promptGuidelines ?? []), SANDBOX_GUIDELINE, "Include a short description of the task in each bash call, in the user's language. Piopio uses it as the activity label."],
			async execute(toolCallId: string, params: unknown, signal: AbortSignal | undefined, onUpdate: never, ctx: never) {
				const { [OUTSIDE_PROJECT]: outside, description, background, ...input } = params as { command: string; timeout?: number; outside_project?: boolean; description?: string; background?: boolean };
				// A command that keeps running (05-build §9 TM4): the same confinement, started and left running.
				if (background && options.processes) {
					const confineIt = !outside && bridge.enabled() && !(process.platform !== "darwin" && sandboxUnavailable());
					if (confineIt && sandboxUnavailable()) return { content: [{ type: "text", text: `Nothing ran: Piopio's sandbox can't start on this Mac (${sandboxUnavailable()}).` }], details: {}, isError: true } as never;
					if (confineIt) await readNetwork();
					const commandLine = confineIt ? line(input.command, cwd) : input.command;
					try {
						const manager = options.processes();
						const started = manager.start(input.command, commandLine, cwd, { shell: shell(), ...(description ? { description } : {}) });
						await manager.settle(started.id, 2500);
						const first = manager.output(started.id);
						return { content: [{ type: "text", text: startedText(first.process, first.text) }], details: { background: first.process } } as never;
					} catch (error) {
						return { content: [{ type: "text", text: (error as Error).message }], details: {}, isError: true } as never;
					}
				}
				if (outside || !bridge.enabled()) return plain.execute(toolCallId, input as never, signal, onUpdate, ctx);
				const unavailable = sandboxUnavailable();
				if (unavailable) {
					// Elsewhere there is no sandbox to fall back from (the app ships on macOS; the suites run on Linux CI), and
					// refusing every command would only make the engine unusable there. On a Mac whose sandbox is broken, keep
					// stopping: running unsandboxed is not what the setting promised.
					if (process.platform !== "darwin") return plain.execute(toolCallId, input as never, signal, onUpdate, ctx);
					return { content: [{ type: "text", text: `Nothing ran: Piopio's sandbox can't start on this Mac (${unavailable}). Tell the user; they can turn the sandbox off in Settings › Approvals, or you can ask to run this with ${OUTSIDE_PROJECT}: true.` }], details: {}, isError: true } as never;
				}
				const net = await readNetwork();
				const startedAt = Date.now();
				const result = await confined.execute(toolCallId, input as never, signal, onUpdate, ctx);
				const content = (result as { content?: Content }).content;
				const text = content?.map((c) => c.text ?? "").join("") ?? "";
				const refused = net?.refusedSince(startedAt) ?? [];
				const hint = refused.length ? networkHint(refused) : (result as { isError?: boolean }).isError ? sandboxHint(text) : undefined;
				if (hint) return { ...result, content: [...(content ?? []), { type: "text", text: hint }] } as never;
				return result;
			},
		} as never);
	};
}
