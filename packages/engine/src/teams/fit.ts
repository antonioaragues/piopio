/**
 * The fit check (docs/spec/21 D6, design 5c-2): before a team works in a project, what it needs there. Git (each task
 * works on its own branch), checks (run after each merge), and AGENTS.md (what every member is told). Each missing one
 * has a fix the app offers in one click.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export type FitCheck = { git: boolean; checks?: string; agentsMd: boolean };

export function fitCheck(cwd: string): FitCheck {
	const checks = detectChecks(cwd);
	return { git: existsSync(join(cwd, ".git")), ...(checks ? { checks } : {}), agentsMd: existsSync(join(cwd, "AGENTS.md")) };
}

const read = (path: string): string | undefined => {
	try {
		return readFileSync(path, "utf8");
	} catch {
		return undefined;
	}
};

/** The project's test command, from what's in its folder: `pnpm test`, `swift test`, `cargo test`… */
export function detectChecks(cwd: string): string | undefined {
	const pkg = read(join(cwd, "package.json"));
	if (pkg) {
		try {
			const test = (JSON.parse(pkg) as { scripts?: Record<string, string> }).scripts?.test;
			// npm init's placeholder isn't a check.
			if (test && !test.includes("no test specified")) {
				if (existsSync(join(cwd, "pnpm-lock.yaml"))) return "pnpm test";
				if (existsSync(join(cwd, "yarn.lock"))) return "yarn test";
				if (existsSync(join(cwd, "bun.lockb")) || existsSync(join(cwd, "bun.lock"))) return "bun test";
				return "npm test";
			}
		} catch {
			// Not JSON: look further.
		}
	}
	if (existsSync(join(cwd, "Package.swift"))) return "swift test";
	if (existsSync(join(cwd, "Cargo.toml"))) return "cargo test";
	if (existsSync(join(cwd, "go.mod"))) return "go test ./...";
	if (existsSync(join(cwd, "pytest.ini")) || /\[tool\.pytest/.test(read(join(cwd, "pyproject.toml")) ?? "")) return "pytest";
	if (/^test:/m.test(read(join(cwd, "Makefile")) ?? "")) return "make test";
	return undefined;
}
