/**
 * Where things really are, for every check that decides on a path: approvals (policy.ts), the sandbox (sandbox.ts),
 * apps' data files, the file viewer, hooks and skills (engine). One list of credentials and one containment check, so
 * a location added here is protected everywhere at once.
 *
 * Rules for code that decides on a path (keep them, they are why this file exists):
 * - Decide on the physical location: `within(path, dir)`, never `resolve(path).startsWith(dir)`. A repository can ship
 *   a symlink (`notes.md -> ~/.zshrc`, `.pi/extensions -> ~/.pi/agent/extensions`), and a lexical check follows it.
 * - Ask about credentials with `credentialAt` (the path is one) and `credentialBelow` (the path holds one: a recursive
 *   read of it reaches them). Don't keep a list of your own: add the location to `CREDENTIALS`.
 * - Files in a project that make code run in a later session are `PROJECT_CONTROL`: the agent's writes to them ask, and
 *   sandboxed commands can't write them.
 */
import { lstatSync, readlinkSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative, resolve, sep } from "node:path";

/**
 * The physical location of `path`: symlinks resolved, including a dangling last link (writing through it creates
 * its target) and paths that don't exist yet (resolved from their closest existing folder).
 */
export function physical(path: string): string {
	let dir = resolve(path);
	const rest: string[] = [];
	for (let hops = 0; hops < 64; hops++) {
		try {
			return join(realpathSync(dir), ...[...rest].reverse());
		} catch {
			try {
				if (lstatSync(dir).isSymbolicLink()) {
					dir = resolve(dirname(dir), readlinkSync(dir));
					continue;
				}
			} catch {
				// doesn't exist: try its folder
			}
		}
		const parent = dirname(dir);
		if (parent === dir) break;
		rest.push(basename(dir));
		dir = parent;
	}
	return resolve(path);
}

/**
 * `path` is `dir` or inside it, comparing the strings only. Both must already be physical (`physical()`), or this is
 * the lexical check the rules above warn about: use `within` unless you resolved them yourself.
 */
export function under(path: string, dir: string): boolean {
	const p = resolve(path);
	const d = resolve(dir);
	return p === d || p.startsWith(d.endsWith(sep) ? d : d + sep);
}

/** Where `path` really is lies in `dir` (or is it): symlinks in either resolved. */
export function within(path: string, dir: string): boolean {
	return under(physical(path), physical(dir));
}

/** Piopio's data folder, as the engine has it (`PIOPIO_HOME`, set by the app). */
export function piopioHome(home = homedir()): string {
	return process.env.PIOPIO_HOME ?? join(home, "Library", "Application Support", "Piopio");
}

/**
 * A place that holds keys or sign-ins. `commands` says what sandboxed commands may do with it:
 * - "hidden": they can't read it (nothing a build or test needs is there).
 * - "readable": they can, because tools need it to work (git over SSH, signed commits and code signing, private package
 *   registries); the agent's own reads of it, and commands that name it, still ask.
 * Either way the agent's reading tools ask before reading it, and a read-only command that names it isn't automatic.
 */
export type Credential = { path: string; label: string; commands: "hidden" | "readable" };

/** Relative to the home folder; `piopio` is Piopio's own data folder (the engine's token, hooks.key, every chat). */
const CREDENTIALS: readonly { at: string; commands: Credential["commands"] }[] = [
	{ at: "piopio", commands: "hidden" },
	// AI tools' and cloud CLIs' sign-ins.
	{ at: ".pi/agent/auth.json", commands: "hidden" },
	{ at: ".codex/auth.json", commands: "hidden" },
	{ at: ".claude/.credentials.json", commands: "hidden" },
	{ at: ".aws", commands: "hidden" },
	{ at: ".config/gcloud", commands: "hidden" },
	{ at: ".azure", commands: "hidden" },
	// gh keeps its token here when it isn't in the Keychain; inside the sandbox gh is signed out either way (sandbox.ts).
	{ at: ".config/gh/hosts.yml", commands: "hidden" },
	// Plain-text passwords and registry tokens that builds and tests don't read (publishing does, outside the sandbox).
	{ at: ".netrc", commands: "hidden" },
	{ at: ".git-credentials", commands: "hidden" },
	{ at: ".pypirc", commands: "hidden" },
	{ at: ".gem/credentials", commands: "hidden" },
	{ at: ".cargo/credentials", commands: "hidden" },
	{ at: ".cargo/credentials.toml", commands: "hidden" },
	{ at: ".terraform.d/credentials.tfrc.json", commands: "hidden" },
	{ at: ".vault-token", commands: "hidden" },
	{ at: ".password-store", commands: "hidden" },
	// Needed by tools at work: SSH config and agent, signing, code signing, private registries, clusters, images.
	// SSH private keys inside ~/.ssh are hidden from commands one by one (sandbox.ts `sshPrivateKeys`).
	{ at: ".ssh", commands: "readable" },
	{ at: ".gnupg", commands: "readable" },
	{ at: "Library/Keychains", commands: "readable" },
	{ at: ".npmrc", commands: "readable" },
	{ at: ".yarnrc.yml", commands: "readable" },
	{ at: ".docker/config.json", commands: "readable" },
	{ at: ".kube", commands: "readable" },
];

/** Every credential location for this home folder (physical paths). */
export function credentials(options: { home?: string; piopioHome?: string } = {}): Credential[] {
	const home = options.home ?? homedir();
	const piopio = options.piopioHome ?? piopioHome(home);
	return CREDENTIALS.map(({ at, commands }) => {
		const path = at === "piopio" ? piopio : join(home, at);
		const label = at === "piopio" ? "Piopio's own data" : `~/${at}`;
		return { path: physical(path), label, commands };
	});
}

export type PathContext = { home?: string; piopioHome?: string; cwd?: string };

/**
 * The credential `path` is or lies in (logically or through a symlink), or undefined. A session whose folder is inside
 * a credential location (a chat's scratch folder or a worktree in Piopio's data) reads its own folder freely.
 */
export function credentialAt(path: string, context: PathContext = {}): Credential | undefined {
	const logical = resolve(path);
	const real = physical(path);
	const cwd = context.cwd && physical(context.cwd);
	return credentials(context).find((c) => {
		if (cwd && under(cwd, c.path) && under(real, cwd)) return false;
		return under(real, c.path) || under(logical, c.path) || under(logical, unphysical(c.path, context.home));
	});
}

/** A credential location inside `path` (a recursive read of `path` reaches it), or undefined. */
export function credentialBelow(path: string, context: PathContext = {}): Credential | undefined {
	const real = physical(path);
	return credentials(context).find((c) => c.path !== real && under(c.path, real));
}

/** A credential's path as written under a home folder reached through a symlink (the logical spelling). */
function unphysical(path: string, home = homedir()): string {
	const realHome = physical(home);
	return under(path, realHome) ? join(home, relative(realHome, path)) : path;
}

/**
 * `rel` in `project`, when where it really is lies in the project; undefined when a symlink takes it elsewhere (a
 * repository can ship `.pi/extensions -> ~/.pi/agent/extensions`, and a hook written "in the project" would then run
 * in every project). Use it for any folder of a project Piopio writes into: hooks, skills.
 */
export function projectPath(project: string, rel: string): string | undefined {
	const path = join(project, rel);
	return within(path, project) ? path : undefined;
}

/**
 * Files in a project that make code run, or change what the agent is told, in a later session: pi's project setup
 * (the resources pi asks trust for, `hasTrustRequiringProjectResources`), Claude Code's hooks, settings and MCP servers
 * (project-trust.ts `CLAUDE_CODE_SETUP`), and git's hooks, which Piopio's own git calls run outside the sandbox.
 * Relative to the project folder; a folder covers everything in it.
 * Not here: `.git/config` (it can run code too, `core.fsmonitor`, but installs write it: husky sets core.hooksPath).
 */
export const PROJECT_CONTROL = [
	".pi/settings.json",
	".pi/mcp.json",
	".pi/extensions",
	".pi/SYSTEM.md",
	".pi/APPEND_SYSTEM.md",
	".claude/settings.json",
	".claude/settings.local.json",
	".claude/hooks",
	".mcp.json",
	".git/hooks",
] as const;

/** The setup folders whose entries are in `PROJECT_CONTROL`: replacing one whole (a rename, a symlink) replaces them. */
export const PROJECT_CONTROL_DIRS = [".pi", ".claude"] as const;

/** The project control file `path` is or lies in, relative to the project (".pi/extensions"), or undefined. */
export function projectControlAt(path: string, project: string): string | undefined {
	const root = physical(project);
	const real = physical(path);
	const logical = resolve(path);
	const rootLogical = resolve(project);
	return PROJECT_CONTROL.find((entry) => under(real, join(root, entry)) || under(logical, join(rootLogical, entry)));
}
