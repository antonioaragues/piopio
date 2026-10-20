/**
 * Approval policy for Build sessions (docs/spec/05-build §6): which tool calls run on their own and which
 * wait for the user, by mode, "always allow" rules and a deny-list that always asks.
 *
 * | Mode      | read/grep/find/ls | write/edit in project | bash                  | network/other | outside project |
 * |-----------|-------------------|-----------------------|-----------------------|---------------|-----------------|
 * | ask       | auto              | ask                   | ask                   | ask           | ask             |
 * | auto_edit | auto              | auto                  | ask unless a rule     | auto          | ask             |
 * | full_auto | auto              | auto                  | auto                  | auto          | ask             |
 */
import { homedir } from "node:os";
import { isAbsolute, resolve, sep } from "node:path";

export type ApprovalMode = "ask" | "auto_edit" | "full_auto";
export type RuleKind = "command" | "tool" | "path";
export type Rule = { kind: RuleKind; pattern: string };
export type Decision = { action: "allow" } | { action: "ask"; reason?: string; rule?: Rule };

const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
const WRITE_TOOLS = new Set(["edit", "write"]);
/** Talking to the user is never something to approve. */
const USER_TOOLS = new Set(["ask_user", "notify_user"]);
/** Package runners and build tools: their rule keeps the subcommand ("pnpm vitest", "swift build"). */
const RUNNERS = new Set(["npm", "pnpm", "yarn", "npx", "bun", "bunx", "deno", "node", "cargo", "go", "swift", "make", "python", "python3", "uv", "pip", "git", "docker", "xcodebuild", "gradle", "mvn", "dotnet", "bundle", "rake"]);

export function decide(mode: ApprovalMode, tool: string, input: Record<string, unknown>, cwd: string, rules: readonly Rule[], home = homedir()): Decision {
	if (USER_TOOLS.has(tool)) return { action: "allow" };
	const path = typeof input.path === "string" ? resolve(cwd, expandHome(input.path, home)) : undefined;

	if (READ_TOOLS.has(tool)) {
		const secret = path && sensitivePath(path, home);
		return secret ? { action: "ask", reason: secret } : { action: "allow" };
	}

	if (WRITE_TOOLS.has(tool)) {
		const secret = path && sensitivePath(path, home);
		if (secret) return { action: "ask", reason: secret };
		if (path && !inside(path, cwd)) {
			if (rules.some((r) => r.kind === "path" && pathMatches(r.pattern, path))) return { action: "allow" };
			return { action: "ask", reason: "Writes outside the project", rule: { kind: "path", pattern: `${parentOf(path)}/**` } };
		}
		if (mode === "ask") return { action: "ask" };
		return { action: "allow" };
	}

	if (tool === "bash") {
		const command = typeof input.command === "string" ? input.command : "";
		const danger = deniedCommand(command, cwd, home);
		if (danger) return { action: "ask", reason: danger };
		if (mode === "full_auto") return { action: "allow" };
		const segments = commandSegments(command);
		const commandRules = rules.filter((r) => r.kind === "command");
		if (mode === "auto_edit" && segments.length > 0 && segments.every((s) => commandRules.some((r) => s === r.pattern || s.startsWith(`${r.pattern} `)))) {
			return { action: "allow" };
		}
		const rule = suggestCommandRule(command);
		return rule ? { action: "ask", rule } : { action: "ask" };
	}

	// Network tools (web_fetch, web_search), extension and MCP tools.
	if (mode !== "ask" || rules.some((r) => r.kind === "tool" && r.pattern === tool)) return { action: "allow" };
	return { action: "ask", rule: { kind: "tool", pattern: tool } };
}

/** The deny-list (AP3): commands that always ask, even in full auto. Returns why, or undefined. */
export function deniedCommand(command: string, cwd: string, home = homedir()): string | undefined {
	if (/(^|[\s;&|(])sudo\s/.test(command)) return "Uses sudo";
	if (/\bgit\s+push\b[^;&|\n]*\s(--force(-with-lease)?|-f)\b/.test(command)) return "Force-pushes";
	if (/\b(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(ba|z|da)?sh\b/.test(command)) return "Pipes a download into a shell";
	if (/\bsecurity\s+(find|dump|delete|export|add|unlock)-/.test(command)) return "Touches the keychain";
	if (/(~|\$HOME|\$\{HOME\})\/\.(ssh|aws|gnupg)\b/.test(command) || command.includes(`${home}/.ssh`) || command.includes(`${home}/.aws`)) return "Touches credentials (~/.ssh, ~/.aws)";
	for (const segment of commandSegments(command)) {
		const words = segment.split(/\s+/);
		if (words[0] !== "rm") continue;
		const flags = words.filter((w) => w.startsWith("-")).join("");
		if (!(flags.includes("r") || flags.includes("R")) || !flags.includes("f")) continue;
		for (const target of words.slice(1).filter((w) => !w.startsWith("-"))) {
			if (target === "/" || target === "*" || target === "." || target.includes("..") || target.startsWith("~") || target.includes("$")) return "Deletes outside the project (rm -rf)";
			if (isAbsolute(target) && !inside(target, cwd)) return "Deletes outside the project (rm -rf)";
		}
	}
	return undefined;
}

/** The rule "Always allow" adds for a command: its program, plus the subcommand for runners. */
export function suggestCommandRule(command: string): Rule | undefined {
	const segments = commandSegments(command);
	if (segments.length !== 1) return undefined; // compound commands are approved one at a time
	const words = segments[0]!.split(/\s+/).filter((w) => !/^[A-Z_][A-Z0-9_]*=/.test(w)); // skip FOO=bar prefixes
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

function sensitivePath(path: string, home: string): string | undefined {
	for (const dir of [".ssh", ".aws", ".gnupg", "Library/Keychains"]) {
		if (inside(path, `${home}/${dir}`)) return `Touches ~/${dir}`;
	}
	return undefined;
}

function inside(path: string, dir: string): boolean {
	const p = resolve(path);
	const d = resolve(dir);
	return p === d || p.startsWith(d.endsWith(sep) ? d : d + sep);
}

function pathMatches(pattern: string, path: string): boolean {
	if (pattern.endsWith("/**")) return inside(path, pattern.slice(0, -3));
	return resolve(pattern) === resolve(path);
}

function parentOf(path: string): string {
	const i = path.lastIndexOf("/");
	return i > 0 ? path.slice(0, i) : "/";
}

function expandHome(path: string, home: string): string {
	return path === "~" ? home : path.startsWith("~/") ? `${home}${path.slice(1)}` : path;
}
