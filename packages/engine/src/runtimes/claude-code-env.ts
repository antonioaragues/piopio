/**
 * The environment Claude Code runs in when Piopio drives it (runtimes/claude-code.ts).
 *
 * - Without the variables of a Claude Code session Piopio itself may have been started from (`agentEnv`): with them,
 *   `claude` takes itself for that session's child and uses its sign-in, which fails.
 * - With `CLAUDE_ENV_FILE`, which Claude Code applies before each of its Bash commands. In zsh (most Macs' shell, and
 *   Claude Code's Bash uses yours) an unquoted glob that matches nothing fails the whole command ("no matches found:
 *   --include=*.ts"); agents write bash, where it stays as written (re-audit 2026-11-25 eval E3). The file turns that
 *   off for zsh only, and does nothing in bash. A CLAUDE_ENV_FILE of your own still applies: it's read first.
 */
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { agentEnv } from "../external-agents.js";
import { shellQuote } from "@piopio/pi-extensions";

const files = new Map<string, string>();

/** The script, written once per engine (and per file of your own) in a private temporary folder. */
export function claudeEnvFile(own = process.env.CLAUDE_ENV_FILE): string {
	const known = files.get(own ?? "");
	if (known) return known;
	const lines = [
		"# Piopio: applied before each of Claude Code's Bash commands (runtimes/claude-code-env.ts).",
		...(own ? [`. ${shellQuote(own)}`] : []),
		'if [ -n "${ZSH_VERSION:-}" ]; then unsetopt nomatch; fi',
		"",
	];
	const file = join(mkdtempSync(join(tmpdir(), "piopio-claude-")), "env.sh");
	writeFileSync(file, lines.join("\n"), { mode: 0o600 });
	files.set(own ?? "", file);
	return file;
}

/** Claude Code's whole environment (the SDK's `env` replaces it, it doesn't add to it). */
export function claudeCodeEnv(env: NodeJS.ProcessEnv = process.env): Record<string, string> {
	const out: Record<string, string> = {};
	for (const [k, v] of Object.entries(agentEnv(env))) if (v !== undefined) out[k] = v;
	// Inside a Claude Code session, its CLAUDE_ENV_FILE is that session's (as `agentEnv` drops its other variables).
	const parent = Boolean(env.CLAUDECODE || env.CLAUDE_CODE_SESSION_ID);
	out.CLAUDE_ENV_FILE = claudeEnvFile(parent ? "" : env.CLAUDE_ENV_FILE);
	return out;
}

/**
 * Claude Code's own tools whose results Piopio can't show, so the model must use Piopio's instead: its
 * `ReportFindings` (a reviewer called it rather than Piopio's report_findings, and the findings never arrived; eval E1).
 */
export const CLAUDE_CODE_TOOLS_OFF = ["ReportFindings"];
