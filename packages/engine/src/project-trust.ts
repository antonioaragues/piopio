/**
 * Whether a coding agent may load a project's own setup (docs/spec/31 CA2). Claude Code's project settings can run code
 * as soon as a session starts: hooks and permissions in .claude/settings*.json, MCP servers in .mcp.json. A repository
 * you just cloned shouldn't get that without your say, as pi's own .pi setup doesn't (ProjectTrustStore).
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { ProjectTrustStore, SettingsManager } from "@earendil-works/pi-coding-agent";

/** Claude Code's project files that run code or start servers. CLAUDE.md alone is only instructions. */
export const CLAUDE_CODE_SETUP = [".claude/settings.json", ".claude/settings.local.json", ".mcp.json"];

export function hasClaudeCodeSetup(dir: string): boolean {
	return CLAUDE_CODE_SETUP.some((file) => existsSync(join(dir, file)));
}

/** Claude Code's own "trust this folder" answer, for `dir` or a folder above it (its config, ~/.claude.json). */
export function claudeCodeTrusted(dir: string, configFile = join(process.env.CLAUDE_CONFIG_DIR ?? homedir(), ".claude.json")): boolean {
	let projects: Record<string, { hasTrustDialogAccepted?: boolean }>;
	try {
		projects = (JSON.parse(readFileSync(configFile, "utf8")) as { projects?: typeof projects }).projects ?? {};
	} catch {
		return false;
	}
	for (let d = dir; ; d = dirname(d)) {
		if (projects[d]?.hasTrustDialogAccepted) return true;
		if (d === dirname(d)) return false;
	}
}

/** pi's decision for `dir` or the closest folder above it with one, else its default ("always" trusts). */
export function piTrust(dir: string, agentDir: string): boolean | null {
	const store = new ProjectTrustStore(agentDir);
	for (let d = dir; ; d = dirname(d)) {
		const decision = store.get(d);
		if (decision !== null) return decision;
		if (d === dirname(d)) break;
	}
	return SettingsManager.create(dir, agentDir).getDefaultProjectTrust() === "always" ? true : null;
}

/**
 * May Claude Code load the project's settings in `cwd` (the project's folder or its worktree, `project` the folder trust
 * is decided for)? Yes when you trusted the project in Piopio or in Claude Code, or when it has nothing that runs code;
 * no when you chose not to trust it, or haven't decided and it has hooks or MCP servers of its own.
 */
export function claudeCodeProjectAllowed(cwd: string, project: string, agentDir: string, configFile?: string): boolean {
	const pi = piTrust(project, agentDir);
	if (pi !== null) return pi;
	if (claudeCodeTrusted(project, configFile)) return true;
	return !hasClaudeCodeSetup(cwd);
}
