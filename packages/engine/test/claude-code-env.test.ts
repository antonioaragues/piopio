import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { claudeCodeEnv, claudeEnvFile } from "../src/runtimes/claude-code-env.js";

// Re-audit 2026-11-25 eval E3: in zsh, `grep -rn x --include=*.ts .` failed with "no matches found" before grep ran.
test.skipIf(!existsSync("/bin/zsh"))("in zsh an unmatched glob stays as written, as in bash; bash is unchanged", () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-glob-"));
	const file = claudeEnvFile();
	const run = (shell: string) => spawnSync(shell, ["-c", `. '${file}'; echo --include=*.nothing-matches`], { cwd: dir, encoding: "utf8" });
	expect(spawnSync("/bin/zsh", ["-c", "echo --include=*.nothing-matches"], { cwd: dir, encoding: "utf8" }).stderr).toContain("no matches found");
	expect(run("/bin/zsh").stdout.trim()).toBe("--include=*.nothing-matches");
	expect(run("/bin/bash")).toMatchObject({ status: 0, stdout: "--include=*.nothing-matches\n", stderr: "" });
});

test("its environment leaves out a Claude Code session Piopio was started from, and keeps the rest", () => {
	const env = claudeCodeEnv({ PATH: "/usr/bin", HOME: "/Users/me", CLAUDECODE: "1", CLAUDE_CODE_SESSION_ID: "s", CLAUDE_CODE_OAUTH_TOKEN: "t" });
	expect(env).toMatchObject({ PATH: "/usr/bin", HOME: "/Users/me" });
	expect(env.CLAUDECODE).toBeUndefined();
	expect(env.CLAUDE_CODE_OAUTH_TOKEN).toBeUndefined();
	expect(env.CLAUDE_ENV_FILE).toBe(claudeEnvFile(""));
	expect(claudeCodeEnv({ CLAUDECODE: "1", CLAUDE_ENV_FILE: "/parent/session.sh" }).CLAUDE_ENV_FILE).toBe(claudeEnvFile(""));
});

test("a CLAUDE_ENV_FILE of your own is still read first", () => {
	const own = join(mkdtempSync(join(tmpdir(), "piopio-own-env-")), "mine.sh");
	writeFileSync(own, "export PIOPIO_TEST_OWN=yes\n");
	const file = claudeEnvFile(own);
	expect(spawnSync("/bin/sh", ["-c", `. '${file}'; echo $PIOPIO_TEST_OWN`], { encoding: "utf8" }).stdout.trim()).toBe("yes");
});
