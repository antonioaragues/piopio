/**
 * Approval policy for Build sessions (docs/spec/05-build §6): which tool calls run on their own and which
 * wait for the user, by mode, "always allow" rules and a deny-list that always asks.
 *
 * Read only (docs/spec/18 §4): reads, search and the web run; tools that may change something ask (the session
 * also drops bash, edit and write, so those ask only if an extension brings them back). `readOnlyTool` names the
 * other tools known to only read: connectors' read capabilities, todos, plans, subagents (which inherit the mode).
 *
 * | Mode      | read/grep/find/ls | write/edit in project | bash                  | network/other | outside project |
 * |-----------|-------------------|-----------------------|-----------------------|---------------|-----------------|
 * | ask       | auto              | ask                   | ask                   | ask           | ask             |
 * | auto_edit | auto              | auto                  | ask unless a rule     | auto          | ask             |
 * | full_auto | auto              | auto                  | auto                  | auto          | ask             |
 */
import { readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import { credentialAt, credentialBelow, credentials, physical, projectControlAt, under, type PathContext } from "./paths.js";

export type ApprovalMode = "read_only" | "ask" | "auto_edit" | "full_auto";
export type RuleKind = "command" | "tool" | "path";
export type Rule = { kind: RuleKind; pattern: string };
export type Decision = { action: "allow" } | { action: "ask"; reason?: string; rule?: Rule };

/** Reading the user's other conversations (engine tools/history.ts) is a read too. */
const READ_TOOLS = new Set(["read", "grep", "find", "ls", "search_conversations", "read_conversation"]);
const WRITE_TOOLS = new Set(["edit", "write"]);
/** Talking to the user is never something to approve. */
const USER_TOOLS = new Set(["report_findings", "process_output", "process_stop", "process_list", "ask_user", "notify_user", "present_files", "show_visual", "update_goal", "create_task", "list_tasks", "message_task", "verdict", "schedule", "watch", "list_routines", "cancel_routine"]);
/** Package runners and build tools: their rule keeps the subcommand ("pnpm vitest", "swift build"). */
const RUNNERS = new Set(["npm", "pnpm", "yarn", "npx", "bun", "bunx", "deno", "node", "cargo", "go", "swift", "make", "python", "python3", "uv", "pip", "git", "docker", "xcodebuild", "gradle", "mvn", "dotnet", "bundle", "rake"]);

/** Tools that only read, whatever the session: allowed in Read only. */
// The browser's reading tools (docs/spec/22 W1) are network reads like web_fetch.
/** The browser's acting tools (docs/spec/22 W2): each site asks first on its own, so Build's modes only keep them out of Read only. */
const BROWSER_ACT_TOOLS = new Set(["browser_click", "browser_type", "browser_select", "browser_key"]);
const READ_ONLY_TOOLS = new Set(["browser_console", "browser_requests", "web_search", "web_fetch", "todo", "propose_plan", "read_skill", "task", "browser_open", "browser_read", "browser_map", "browser_find", "browser_screenshot", "browser_scroll", "browser_back", "browser_tabs", "browser_wait"]);

export function decide(mode: ApprovalMode, tool: string, input: Record<string, unknown>, cwd: string, rules: readonly Rule[], home = homedir(), readOnlyTool: (tool: string) => boolean = () => false): Decision {
	if (USER_TOOLS.has(tool)) return { action: "allow" };
	const logical = typeof input.path === "string" ? resolve(cwd, expandHome(input.path, home)) : undefined;
	// Where the file really is: symlinks inside the project can point anywhere (a cloned repo can ship them).
	const path = logical && physical(logical);
	const viaLink = Boolean(logical && path !== logical);
	const context: PathContext = { home, cwd };
	const credential = logical ? credentialAt(logical, context) : undefined;
	const secret = credential && `Touches ${credential.label}`;

	if (READ_TOOLS.has(tool)) {
		if (secret) return { action: "ask", reason: viaLink ? `${secret} (through a symlink)` : secret };
		// grep, find and ls go through a folder: one that holds credentials (~, ~/.config) reaches them.
		const below = logical && tool !== "read" ? credentialBelow(logical, context) : undefined;
		return below ? { action: "ask", reason: `Searches a folder that holds ${below.label}` } : { action: "allow" };
	}

	// Another agent (Claude Code, Codex) changes files on its own, so Ask asks first; the other modes map onto its own.
	if (tool === "task" && typeof input.agent === "string" && input.agent !== "piopio" && mode === "ask") {
		return { action: "ask", reason: "Hands the task to another agent, which changes files without asking" };
	}

	// Running a script in the project preview (docs/spec/22 §6): it can change the app's state, so it asks unless Full auto.
	if (tool === "browser_eval") return mode === "full_auto" ? { action: "allow" } : { action: "ask", ...(mode === "read_only" ? { reason: "Read only: a script may change the page" } : {}), rule: { kind: "tool", pattern: tool } };

	if (BROWSER_ACT_TOOLS.has(tool)) {
		return mode === "read_only" ? { action: "ask", reason: "Read only: clicking and typing on a page may change something" } : { action: "allow" };
	}

	if (mode === "read_only") {
		if (WRITE_TOOLS.has(tool) || tool === "bash") return { action: "ask", reason: "Read only: choose Ask or Auto-edit to change files or run commands" };
		if (READ_ONLY_TOOLS.has(tool) || readOnlyTool(tool) || rules.some((r) => r.kind === "tool" && r.pattern === tool)) return { action: "allow" };
		return { action: "ask", reason: "Read only: this tool may change something", rule: { kind: "tool", pattern: tool } };
	}

	if (WRITE_TOOLS.has(tool)) {
		if (secret) return { action: "ask", reason: viaLink ? `${secret} (through a symlink)` : secret };
		// The project's agent setup runs code in later sessions, outside the sandbox: never changed without the user.
		const control = logical && projectControlAt(logical, cwd);
		if (control) return { action: "ask", reason: `Changes ${control}, which runs in later sessions` };
		if (path && !under(path, physical(resolve(cwd)))) {
			if (rules.some((r) => r.kind === "path" && pathMatches(r.pattern, path))) return { action: "allow" };
			return { action: "ask", reason: viaLink ? "Writes outside the project (through a symlink)" : "Writes outside the project", rule: { kind: "path", pattern: `${parentOf(path)}/**` } };
		}
		if (mode === "ask") return { action: "ask" };
		return { action: "allow" };
	}

	if (tool === "bash") {
		const command = typeof input.command === "string" ? input.command : "";
		const danger = deniedCommand(command, cwd, home);
		if (danger) return { action: "ask", reason: danger };
		if (mode === "full_auto") return { action: "allow" };
		// piopio-sandbox: leaving the sandbox always asks, rules or not.
		if (input.outside_project === true) return { action: "ask", reason: "Runs outside the sandbox, so it can write anywhere" };
		// Reading runs, as `read` and `grep` do: `ls`, `cat package.json`, `git status` don't ask (05-build §6).
		if ((mode === "ask" || mode === "auto_edit") && readsOnly(command, cwd, home)) return { action: "allow" };
		const parsed = parseCommands(command);
		const segments = parsed ?? [];
		const commandRules = rules.filter((r) => r.kind === "command");
		if (mode === "auto_edit" && segments.length > 0 && segments.every((words) => commandRules.some((r) => {
			const prefix = parseCommands(r.pattern);
			return prefix?.length === 1 && prefix[0]!.every((word, i) => words[i] === word);
		}))) {
			return { action: "allow" };
		}
		const rule = suggestCommandRule(command);
		return rule ? { action: "ask", rule } : { action: "ask" };
	}

	// Network tools (web_fetch, web_search), extension and MCP tools.
	if (mode !== "ask" || rules.some((r) => r.kind === "tool" && r.pattern === tool)) return { action: "allow" };
	return { action: "ask", rule: { kind: "tool", pattern: tool } };
}

/**
 * The deny-list (AP3): commands that always ask, even in full auto. Returns why, or undefined.
 * It reads the command's text, so it stops mistakes, not someone set on getting past it (a script can do any of this):
 * keeping commands from places is the sandbox's job, and Full access has none.
 */
export function deniedCommand(command: string, cwd: string, home = homedir()): string | undefined {
	if (/(^|[\s;&|(])sudo\s/.test(command)) return "Uses sudo";
	if (/\bgit\s+push\b[^;&|\n]*\s(--force(-with-lease)?|-f)\b/.test(command)) return "Force-pushes";
	if (/\b(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(ba|z|da)?sh\b/.test(command)) return "Pipes a download into a shell";
	const homes = ["~", "$HOME", "${HOME}", home];
	if (/\bsecurity\s+(find|dump|delete|export|add|unlock)-/.test(command) || homes.some((h) => command.includes(`${h}/Library/Keychains`))) return "Touches the keychain";
	const named = namedCredential(command, cwd, home);
	if (named) return `Touches credentials (${named})`;
	for (const segment of commandSegments(command)) {
		const words = program(segment.split(/\s+/));
		if (words[0] !== "rm") continue;
		const flags = words.filter((w) => w.startsWith("-")).join("");
		if (!(flags.includes("r") || flags.includes("R")) || !flags.includes("f")) continue;
		for (const target of words.slice(1).filter((w) => !w.startsWith("-"))) {
			if (target === "/" || target === "*" || target === "." || target.includes("..") || target.startsWith("~") || target.includes("$")) return "Deletes outside the project (rm -rf)";
			if (isAbsolute(target) && !under(target, cwd)) return "Deletes outside the project (rm -rf)";
		}
	}
	return undefined;
}

/** A command's words from its program on: "/bin/rm", "\\rm", "'rm'", "command rm" and "env X=1 rm" are all rm. */
function program(words: string[]): string[] {
	let i = 0;
	while (i < words.length && (["command", "builtin", "exec", "nohup", "time", "env"].includes(words[i]!) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i]!))) i++;
	const rest = words.slice(i);
	if (rest[0]) rest[0] = rest[0].replace(/^\\/, "").replace(/^(["'])(.*)\1$/, "$2").split("/").pop()!;
	return rest;
}

function escapeRegExp(s: string): string {
	return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** The rule "Always allow" adds for a command: its program, plus the subcommand for runners. */
export function suggestCommandRule(command: string): Rule | undefined {
	const segments = parseCommands(command);
	if (segments?.length !== 1) return undefined; // compound/complex commands are approved one at a time
	const words = segments[0]!.filter((w) => !/^[A-Z_][A-Z0-9_]*=/.test(w)); // skip FOO=bar prefixes
	const [program, sub] = words;
	if (!program) return undefined;
	const pattern = RUNNERS.has(program) && sub && !sub.startsWith("-") ? `${program} ${sub}` : program;
	return { kind: "command", pattern };
}

/** Splits a shell command on &&, ||, ;, | and new lines (quotes are not parsed: rules stay conservative). */
export function commandSegments(command: string): string[] {
	return command
		.split(/&&|\|\||[;|\n]/)
		.map((s) => s.trim().replace(/^\(+|\)+$/g, "").trim())
		.filter(Boolean);
}

/**
 * The credential a command names by its path (`~/.npmrc`, `$HOME/.aws/config`, the absolute path), or undefined. It
 * reads the text, like the rest of the deny-list: the sandbox and `readsOnly` are what keep commands from them.
 * A session whose folder is inside a credential location (a chat's folder in Piopio's data) may name its own folder.
 */
function namedCredential(command: string, cwd: string, home: string): string | undefined {
	const realHome = physical(home);
	const realCwd = physical(cwd);
	for (const c of credentials({ home })) {
		if (under(realCwd, c.path)) continue;
		const spellings = under(c.path, realHome) ? ["~", "$HOME", "${HOME}", home, realHome].map((h) => `${h}/${relative(realHome, c.path)}`) : [c.path];
		if (spellings.some((s) => new RegExp(`${escapeRegExp(s)}(?![\\w.-])`).test(command))) return c.label;
	}
	return undefined;
}

function pathMatches(pattern: string, path: string): boolean {
	if (pattern.endsWith("/**")) return under(path, pattern.slice(0, -3));
	return resolve(pattern) === resolve(path);
}

function parentOf(path: string): string {
	const i = path.lastIndexOf("/");
	return i > 0 ? path.slice(0, i) : "/";
}

function expandHome(path: string, home: string): string {
	return path === "~" ? home : path.startsWith("~/") ? `${home}${path.slice(1)}` : path;
}

/** Parse a deliberately small shell subset. Anything requiring shell evaluation asks again.
 * Quoted literals and pipelines/boolean lists are supported; expansions, redirections, escapes,
 * background jobs and compound shell syntax are not eligible for automatic approval.
 */
function parseCommands(command: string): string[][] | undefined {
	if (/[$`<>\\(){}]/.test(command)) return undefined;
	const commands: string[][] = [];
	let words: string[] = [], word = "", started = false, quote = "";
	const flush = () => { if (started) words.push(word); word = ""; started = false; };
	for (let i = 0; i < command.length; i++) {
		const ch = command[i]!;
		if (quote) { if (ch === quote) quote = ""; else word += ch; continue; }
		if (ch === "'" || ch === '"') { quote = ch; started = true; continue; }
		if (ch === "#") return undefined;
		if (ch === "&" || ch === "|" || ch === ";" || ch === "\n") {
			if (ch === "&" && command[i + 1] !== "&") return undefined;
			if ((ch === "&" || ch === "|") && command[i + 1] === ch) i++;
			flush();
			if (!words.length) return undefined;
			commands.push(words); words = [];
		} else if (/\s/.test(ch)) flush();
		else { word += ch; started = true; }
	}
	if (quote) return undefined;
	flush();
	if (!words.length) return undefined;
	commands.push(words);
	return commands;
}

const READ_ONLY = new Set(["ls", "cat", "head", "tail", "grep", "rg", "find", "fd", "wc", "pwd", "echo", "which", "tree", "du", "stat", "cut", "jq", "diff", "basename", "dirname", "realpath"]);
const READ_ONLY_SUB: Record<string, Set<string>> = {
	git: new Set(["status", "log", "diff", "show", "blame", "ls-files", "rev-parse", "describe", "shortlog", "grep"]),
	npm: new Set(["ls", "view", "outdated", "--version"]),
	pnpm: new Set(["ls", "list", "why", "outdated", "--version"]),
	swift: new Set(["--version"]), node: new Set(["--version"]),
};

/**
 * Options that turn a reading program into one that runs another program, writes a file, or follows symlinks out of
 * the project (a repository can ship `vendor -> ~`, and a recursive read that follows it reads the home folder).
 * - `long` match their abbreviations too: git and GNU tools take any unambiguous prefix (`--open` is
 *   `--open-files-in-pager`, `--compress-prog` is `--compress-program`). Matching every prefix also refuses a few
 *   harmless options (`git diff --text`): those ask, which is the safe side.
 * - `short` letters match anywhere in a cluster (`-nO`, `-Ovim`, `-rR`).
 * - `exact` are whole words (find's `-exec`).
 * Add the option here when a reading program gains one; don't special-case it below.
 */
const UNSAFE_OPTIONS: Record<string, { long?: string[]; short?: string; exact?: string[] }> = {
	// `git grep -O<cmd>` opens the matches in <cmd>, through the shell.
	git: { long: ["output", "ext-diff", "textconv", "exec-path", "open-files-in-pager"], short: "O" },
	sort: { long: ["output", "compress-program", "files0-from"], short: "o" },
	tree: { long: ["output"], short: "oRl" },
	diff: { long: ["recursive"], short: "r" },
	grep: { long: ["dereference-recursive"], short: "R" },
	rg: { long: ["pre", "hostname-bin", "follow"], short: "L" },
	fd: { long: ["exec", "exec-batch", "follow"], short: "xXL" },
	find: { exact: ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls", "-L", "-follow"] },
	du: { long: ["dereference"], short: "L" },
	file: { long: ["compile"], short: "C" },
};

function unsafeOption(program: string, arg: string): boolean {
	const unsafe = UNSAFE_OPTIONS[program];
	if (!unsafe) return false;
	if (unsafe.exact?.includes(arg)) return true;
	const long = /^--([^=]{2,})/.exec(arg);
	if (long) return Boolean(unsafe.long?.some((name) => name.startsWith(long[1]!)));
	return Boolean(unsafe.short && /^-[^-]/.test(arg) && [...arg.slice(1)].some((c) => unsafe.short!.includes(c)));
}

/** A conservative argument-aware policy. Unknown forms are refused in Plan mode. */
export function readOnlyCommand(command: string): boolean {
	const segments = parseCommands(command);
	return Boolean(segments?.every(readOnlySegment));
}

/**
 * A command that only reads, which Ask and Auto-edit run without asking (docs/spec/05-build §6, 2026-11-24): the same
 * reads `read` and `grep` make, which never ask. Every part is a read-only program (`readOnlyCommand`'s list), `cd`
 * into the project or below, or `true`; output thrown away (`2>/dev/null`, `2>&1`) is fine.
 * Every argument that could be a path is checked as one (`readableArgument`): naming a credential, a folder that holds
 * one, or a glob that can reach one makes it ask, as `read` does.
 */
export function readsOnly(command: string, cwd: string, home: string): boolean {
	const stripped = command.replace(/\s+(?:[12]?>\s*\/dev\/null|2>&1)(?=\s|$|[;&|])/g, "");
	const segments = parseCommands(stripped);
	if (!segments) return false;
	const project = physical(resolve(cwd));
	const context: PathContext = { home, cwd };
	let here = resolve(cwd);
	for (const [program, ...args] of segments) {
		if (program === "true" || program === ":") {
			if (args.length) return false;
			continue;
		}
		if (program === "cd") {
			// A glob would cd wherever it matches (a linked folder), and later parts would be checked from the wrong place.
			if (args.length !== 1 || args[0]!.startsWith("-") || GLOB.test(args[0]!) || /^~[^/]/.test(args[0]!)) return false;
			const to = resolve(here, expandHome(args[0]!, home));
			if (!under(physical(to), project)) return false;
			here = to;
			continue;
		}
		if (!readOnlySegment([program!, ...args])) return false;
		for (const arg of args) for (const value of pathCandidates(arg)) if (!readableArgument(value, here, home, context)) return false;
	}
	return true;
}

/**
 * What in an argument may name a path: the argument, an option's value (`--file=x`), or a short option's attached value
 * (`-f~/.npmrc`, `-C/etc`). Patterns and other words are checked too; a word that isn't a path is harmless to check.
 */
function pathCandidates(arg: string): string[] {
	if (!arg.startsWith("-")) return [arg];
	const out: string[] = [];
	if (arg.includes("=")) out.push(arg.slice(arg.indexOf("=") + 1));
	const attached = /^-[A-Za-z]+([~./].*)$/.exec(arg);
	if (attached) out.push(attached[1]!);
	return out.filter(Boolean);
}

const GLOB = /[*?[]/;
/** How many folder entries a glob may visit before the command asks instead (a glob into node_modules, or `/`). */
const MAX_GLOB_ENTRIES = 5000;

/** May a read-only command name `value` without asking: not a credential, not a folder holding one, nor a glob reaching one. */
function readableArgument(value: string, here: string, home: string, context: PathContext): boolean {
	// `~user`, `~+`, `~-`: someone else's home folder or the shell's folder stack, not something to resolve here.
	if (/^~[^/]/.test(value)) return false;
	const word = expandHome(value, home);
	const paths = GLOB.test(word) ? globMatches(word, here) : [resolve(here, word)];
	if (!paths) return false;
	return paths.every((path) => !credentialAt(path, context) && !credentialBelow(path, context));
}

/**
 * Every path a shell could expand `pattern` to, from `from`; undefined past MAX_GLOB_ENTRIES. It matches more than a
 * shell would, on purpose: dot files too, `[…]` as any one character, symlinked folders followed (zsh's `*` and `**`
 * differ there). Matching more only makes a command ask; matching less would let one read what it shouldn't.
 */
export function globMatches(pattern: string, from: string): string[] | undefined {
	let current = [pattern.startsWith("/") ? "/" : from];
	let budget = MAX_GLOB_ENTRIES;
	const entries = (dir: string): string[] => {
		try {
			return readdirSync(dir);
		} catch {
			return [];
		}
	};
	const isDir = (path: string) => {
		try {
			return statSync(path).isDirectory();
		} catch {
			return false;
		}
	};
	for (const part of pattern.split("/").filter(Boolean)) {
		if (!GLOB.test(part)) {
			current = current.map((dir) => join(dir, part));
			continue;
		}
		const next: string[] = [];
		if (part === "**") {
			// Zero or more folders: every folder and file below (a file as the last part, a folder before more parts).
			const stack = [...current];
			while (stack.length) {
				const dir = stack.pop()!;
				next.push(dir);
				for (const name of entries(dir)) {
					if (--budget < 0) return undefined;
					const path = join(dir, name);
					if (isDir(path)) stack.push(path);
					else next.push(path);
				}
			}
		} else {
			const re = globRegExp(part);
			for (const dir of current) {
				for (const name of entries(dir)) {
					if (--budget < 0) return undefined;
					if (re.test(name)) next.push(join(dir, name));
				}
			}
		}
		current = next;
	}
	return current;
}

/** One path part of a glob as a pattern: `*` any run, `?` and any `[…]` one character, the rest literal. */
function globRegExp(part: string): RegExp {
	let body = "";
	for (let i = 0; i < part.length; i++) {
		const c = part[i]!;
		if (c === "*") body += ".*";
		else if (c === "?") body += ".";
		else if (c === "[") {
			const close = part.indexOf("]", i + 2);
			body += ".";
			if (close !== -1) i = close;
		} else body += c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	}
	return new RegExp(`^${body}$`, "s");
}

function readOnlySegment([program, ...args]: string[]): boolean {
	if (!program) return false;
	if (args.some((a) => unsafeOption(program, a))) return false;
	if (program === "git") {
		if (args[0] === "branch") return args.slice(1).every(a => ["-a", "-r", "-v", "-vv", "--all", "--remotes", "--list", "--show-current"].includes(a));
		if (args[0] === "remote") return args.slice(1).every(a => a === "-v" || a === "--verbose");
	}
	if (READ_ONLY_SUB[program]) return Boolean(args[0] && READ_ONLY_SUB[program]!.has(args[0]));
	if (program === "sed") return args[0] === "-n" && Boolean(args[1] && /^(?:\d+|\$)(?:,(?:\d+|\$))?p$/.test(args[1])) && args.slice(2).every(a => !a.startsWith("-") || a === "-");
	if (program === "sort" || program === "file") return true;
	if (program === "date") return args.every(a => a === "-u" || a === "--utc" || a.startsWith("+"));
	if (!READ_ONLY.has(program)) return false;
	// jq's `env` and `$ENV` print every variable the engine runs with ($ is refused before this, by parseCommands).
	if (program === "jq" && args.some((a) => /\benv\b|\$ENV/.test(a))) return false;
	return true;
}
