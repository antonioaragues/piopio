import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ProjectTrustStore } from "@earendil-works/pi-coding-agent";
import { expect, test } from "vitest";
import { claudeCodeProjectAllowed, claudeCodeTrusted, hasClaudeCodeSetup } from "../src/project-trust.js";

// Claude Code loads a project's own settings (hooks, MCP servers) only when the project is trusted (docs/spec/31 CA2).
test("a project's Claude Code setup loads when it's trusted in pi or Claude Code, or has nothing that runs code", () => {
	const base = realpathSync(mkdtempSync(join(tmpdir(), "piopio-trust-")));
	const agentDir = join(base, "agent");
	mkdirSync(agentDir);
	const config = join(base, "claude.json");
	const plain = join(base, "plain");
	const hooked = join(base, "hooked");
	mkdirSync(plain);
	mkdirSync(join(hooked, ".claude"), { recursive: true });
	writeFileSync(join(plain, "CLAUDE.md"), "Be nice.");
	writeFileSync(join(hooked, ".claude", "settings.json"), JSON.stringify({ hooks: { SessionStart: [{ hooks: [{ type: "command", command: "touch pwned" }] }] } }));
	writeFileSync(config, JSON.stringify({ projects: {} }));

	expect(hasClaudeCodeSetup(plain)).toBe(false);
	expect(hasClaudeCodeSetup(hooked)).toBe(true);
	// Nothing that runs code: CLAUDE.md still applies.
	expect(claudeCodeProjectAllowed(plain, plain, agentDir, config)).toBe(true);
	// Hooks and no decision anywhere: only the user's own setup.
	expect(claudeCodeProjectAllowed(hooked, hooked, agentDir, config)).toBe(false);

	// Trusted in Claude Code itself, for the folder or one above it.
	writeFileSync(config, JSON.stringify({ projects: { [base]: { hasTrustDialogAccepted: true } } }));
	expect(claudeCodeTrusted(hooked, config)).toBe(true);
	expect(claudeCodeProjectAllowed(hooked, hooked, agentDir, config)).toBe(true);

	// pi's decision wins either way, and a worktree is judged by its project's decision.
	new ProjectTrustStore(agentDir).set(hooked, false);
	expect(claudeCodeProjectAllowed(hooked, hooked, agentDir, config)).toBe(false);
	writeFileSync(config, JSON.stringify({ projects: {} }));
	new ProjectTrustStore(agentDir).set(hooked, true);
	const worktree = join(base, "worktree");
	mkdirSync(join(worktree, ".claude"), { recursive: true });
	writeFileSync(join(worktree, ".claude", "settings.json"), "{}");
	expect(claudeCodeProjectAllowed(worktree, hooked, agentDir, config)).toBe(true);
	expect(claudeCodeTrusted(hooked, join(base, "missing.json"))).toBe(false);
});
