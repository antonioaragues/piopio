import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Snapshot } from "@piopio/protocol";
import ts from "typescript";
import { afterEach, describe, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { claudeHooks, globMatch, hookName, hookSentence, hookSource, listHooks, readHook, toggleHook, writeHook, type HookSpec } from "../src/user-hooks.js";
import { TestClient } from "./client.js";

describe("your hooks as pi extensions (PAR6)", () => {
	const swift: HookSpec = { when: "after", tools: ["edit", "write"], files: "*.swift", run: 'swiftformat "$FILE"' };
	const push: HookSpec = { when: "before", tools: ["bash"], command: "git push --force*", stop: "Ask me before force-pushing." };

	test("a hook reads as a sentence, and its file reads back as the same hook until it's changed by hand", () => {
		expect(hookSentence(swift)).toBe('After Piopio edits or writes a *.swift file, run swiftformat "$FILE"');
		expect(hookSentence(push)).toBe('Before Piopio runs a command matching git push --force*, stop it: "Ask me before force-pushing."');
		expect(hookSentence({ when: "end", files: "packages/**", run: "pnpm test:unit" })).toBe("When Piopio finishes an answer that changed packages/** files, run pnpm test:unit; if it fails, Piopio keeps going (3 times at most)");
		const source = hookSource(swift);
		expect(source.split("\n")[0]).toBe('// Piopio hook · After Piopio edits or writes a *.swift file, run swiftformat "$FILE"');
		expect(readHook(source)).toEqual(swift);
		expect(readHook(source.replace("60_000", "5_000"))).toBeUndefined();
		// Named after what it runs, else what it matches.
		expect(hookName(push)).toBe("hook-git-push-force-before");
	});

	test("files, on and off, a hand-changed file, and globs as the files match them", () => {
		const dir = mkdtempSync(join(tmpdir(), "piopio-hooks-"));
		const path = writeHook(dir, swift);
		expect(path).toBe(join(dir, "hook-swiftformat-file-after.ts"));
		expect(writeHook(dir, swift)).toBe(join(dir, "hook-swiftformat-file-after-2.ts"));
		const off = toggleHook(path, false);
		expect(off.endsWith(".ts.off")).toBe(true);
		writeFileSync(join(dir, "hook-by-hand.ts"), "export default function () {}\n");
		writeFileSync(join(dir, "other.ts"), "export default function () {}\n");
		expect(listHooks(dir).map((h) => [h.name, h.on, Boolean(h.spec)])).toEqual([
			["hook-by-hand.ts", true, false],
			["hook-swiftformat-file-after-2.ts", true, true],
			["hook-swiftformat-file-after.ts", false, true],
		]);
		expect(() => writeHook(dir, swift, join(dir, "hook-by-hand.ts"))).toThrow(/changed by hand/);
		expect(globMatch("*.swift", "apps/mac/Thread.swift")).toBe(true);
		expect(globMatch("packages/**", "packages/engine/src/a.ts")).toBe(true);
		expect(globMatch("packages/**", "apps/a.ts")).toBe(false);
		expect(globMatch("git push --force*", "git push --force origin main", true)).toBe(true);
	});

	test("Claude Code's hooks map onto these: PreToolUse, PostToolUse and Stop with command hooks", () => {
		const project = mkdtempSync(join(tmpdir(), "piopio-claude-"));
		mkdirSync(join(project, ".claude"));
		writeFileSync(join(project, ".claude", "settings.json"), JSON.stringify({
			hooks: {
				PostToolUse: [{ matcher: "Edit|Write", hooks: [{ type: "command", command: "prettier --write" }] }],
				PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "./scripts/guard.sh" }] }],
				Stop: [{ hooks: [{ type: "command", command: "npm test" }] }],
				Notification: [{ hooks: [{ type: "command", command: "say hi" }] }],
			},
		}));
		expect(claudeHooks(project)).toEqual([
			{ when: "after", tools: ["edit", "write"], run: "prettier --write" },
			{ when: "before", tools: ["bash"], run: "./scripts/guard.sh" },
			{ when: "end", run: "npm test" },
		]);
	});
});

// Re-audit 2026-11-25 (V3): a line break in a hook's command (one imported from a repository's .claude/settings.json)
// ended the generated file's comment and put the rest on a line of its own, as code.
test("a hook's command can't add code to its file, whatever line break it holds", () => {
	for (const nl of ["\n", "\r", "\u2028", "\u2029", "\r\n"]) {
		const spec: HookSpec = { when: "before", tools: ["bash"], command: `x${nl}pwnedCommand()`, run: `echo hi${nl}pwnedRun()`, stop: `no${nl}pwnedStop()` };
		const source = hookSource(spec);
		const names: string[] = [];
		const visit = (node: ts.Node) => {
			if (ts.isIdentifier(node)) names.push(node.text);
			ts.forEachChild(node, visit);
		};
		visit(ts.createSourceFile("hook.ts", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS));
		expect(names.filter((n) => n.startsWith("pwned")), JSON.stringify(nl)).toEqual([]);
		expect(readHook(source)).toEqual(spec);
	}
});

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];
afterEach(async () => {
	for (const ctx of open.splice(0)) {
		ctx.client.close();
		await ctx.engine.stop();
	}
});

async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-uh-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
	const ctx = { home, engine, client };
	open.push(ctx);
	return ctx;
}

test("in a real Build session: a hook stops a command, another runs after a write, and a failing check sends Piopio back three times at most", { timeout: 90_000 }, async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-uh-project-")));
	writeFileSync(join(folder, "package.json"), "{}");
	const { project } = await a.client.call("projects.add", { path: folder });
	await a.client.call("projects.configure", { id: (project as { id: string }).id, trust: true });
	// Two of yours (every project) and one of the project's.
	await a.client.call("hooks.save", { spec: { when: "before", tools: ["bash"], command: "git push --force*", stop: "Ask me before force-pushing." } });
	await a.client.call("hooks.save", { spec: { when: "after", tools: ["write"], files: "*.txt", run: 'echo "formatted $FILE" >> hook.log' } });
	await a.client.call("hooks.save", { project: folder, spec: { when: "end", files: "*.txt", run: "echo 2 failing; exit 1" } });
	const listed = await a.client.call("hooks.list", { project: folder });
	expect(listed.hooks.map((h: { where: string; on: boolean }) => [h.where, h.on])).toEqual([["yours", true], ["yours", true], ["project", true]]);
	expect(existsSync(join(a.home, "pi-agent", "extensions"))).toBe(true);

	const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai");
	a.engine.hub.faux!.setResponses([
		fauxAssistantMessage([fauxToolCall("bash", { command: "git push --force origin main" })], { stopReason: "toolUse" }),
		fauxAssistantMessage([fauxToolCall("write", { path: "notes.txt", content: "hi" })], { stopReason: "toolUse" }),
		fauxAssistantMessage([fauxText("Done.")]),
		fauxAssistantMessage([fauxText("Fixing it.")]),
		fauxAssistantMessage([fauxText("Fixing it again.")]),
		fauxAssistantMessage([fauxText("Still failing.")]),
		fauxAssistantMessage([fauxText("Should not be asked.")]),
	]);
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	await a.client.call("sessions.subscribe", { ref });
	await a.client.call("sessions.configure", { ref, approvalMode: "full_auto" });
	await a.client.call("sessions.submit", { ref, input: { text: "Push it, then note it down." } });
	const snapshot = async () => (await a.client.call("sessions.open", { ref })) as Snapshot;
	for (let i = 0; i < 300; i++) {
		const s = await snapshot();
		if (s.state.status === "idle" && s.items.filter((x) => x.kind === "assistant").length >= 5) break;
		await new Promise((r) => setTimeout(r, 100));
	}
	const items = (await snapshot()).items;
	const bash = items.find((i) => i.kind === "tool" && i.tool === "bash");
	expect(JSON.stringify(bash)).toContain("Stopped by your hook: Ask me before force-pushing.");
	expect(readFileSync(join(folder, "hook.log"), "utf8")).toBe("formatted notes.txt\n");
	const notes = items.flatMap((i) => (i.kind === "system" ? [i.text] : []));
	expect(notes.filter((n) => n.includes("failed after this answer"))).toHaveLength(3);
	expect(JSON.stringify(items)).not.toContain("Should not be asked.");
});

test("a project whose .pi/extensions links outside it gets no hooks, and its Claude hooks aren't imported there", async () => {
	const a = await start();
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-uh-link-")));
	const yours = join(a.home, "pi-agent", "extensions");
	mkdirSync(yours, { recursive: true });
	mkdirSync(join(folder, ".pi"));
	symlinkSync(yours, join(folder, ".pi", "extensions"));
	mkdirSync(join(folder, ".claude"));
	writeFileSync(join(folder, ".claude", "settings.json"), JSON.stringify({ hooks: { Stop: [{ hooks: [{ type: "command", command: "echo hi" }] }] } }));
	await a.client.call("projects.add", { path: folder });
	await expect(a.client.call("hooks.save", { project: folder, spec: { when: "end", run: "echo x" } })).rejects.toThrow(/link to a folder outside/);
	await expect(a.client.call("hooks.importClaude", { project: folder })).rejects.toThrow(/link to a folder outside/);
	expect(readdirSync(yours)).toEqual([]);
	expect((await a.client.call("hooks.list", { project: folder })).hooks).toEqual([]);
});
