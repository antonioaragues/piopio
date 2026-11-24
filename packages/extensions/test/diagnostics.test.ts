/** The project's check after the agent's edits (docs/spec/05-build "Diagnostics", roadmap PAR5). */
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { BASELINE_MAX_MS, detectCheck, diagnosticsExtension, MAX_CHECK_ROUNDS, problemKeys, problemsIn, runCheck } from "../src/diagnostics.js";

const folder = (files: Record<string, string>) => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-check-"));
	for (const [name, text] of Object.entries(files)) {
		mkdirSync(join(dir, name, ".."), { recursive: true });
		writeFileSync(join(dir, name), text);
	}
	return dir;
};

test("the check is guessed from the project: its script, tsc, cargo, go", () => {
	expect(detectCheck(folder({ "package.json": JSON.stringify({ scripts: { typecheck: "tsc -b" } }), "pnpm-lock.yaml": "" }))).toBe("pnpm run typecheck");
	expect(detectCheck(folder({ "package.json": JSON.stringify({ scripts: { check: "svelte-check" } }) }))).toBe("npm run check");
	expect(detectCheck(folder({ "package.json": "{}", "tsconfig.json": "{}", "node_modules/.bin/tsc": "" }))).toBe("node_modules/.bin/tsc --noEmit -p .");
	expect(detectCheck(folder({ "Cargo.toml": "" }))).toBe("cargo check --quiet --message-format short");
	expect(detectCheck(folder({ "go.mod": "" }))).toBe("go vet ./...");
	expect(detectCheck(folder({ "README.md": "" }))).toBeUndefined();
});

test("only problems in the files it changed, from tsc, Swift, Rust and Go output", () => {
	const cwd = "/p";
	const files = ["/p/src/cart.ts", "/p/src/main.rs", "/p/Sources/App.swift", "/p/main.go"];
	const tsc = ["src/cart.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'.", "src/other.ts(1,1): error TS1005: ';' expected."].join("\n");
	expect(problemsIn(tsc, files, cwd)).toEqual(["src/cart.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'."]);
	expect(problemsIn("src/other.ts(1,1): error TS1005: ';' expected.", files, cwd)).toEqual([]);
	expect(problemsIn("/p/Sources/App.swift:12:5: error: cannot find 'x' in scope", files, cwd)).toEqual(["/p/Sources/App.swift:12:5: error: cannot find 'x' in scope"]);
	expect(problemsIn("error[E0308]: mismatched types\n  --> src/main.rs:4:9\n   |\n", files, cwd)).toEqual(["error[E0308]: mismatched types", "  --> src/main.rs:4:9", "   |"]);
	expect(problemsIn("./main.go:7:2: undefined: foo", files, cwd)).toEqual(["./main.go:7:2: undefined: foo"]);
});

test("a check runs with a time limit", async () => {
	const ok = await runCheck("echo fine", tmpdir(), "/bin/sh");
	expect(ok).toEqual({ code: 0, output: "fine\n", timedOut: false });
	const slow = await runCheck("sleep 5", tmpdir(), "/bin/sh", undefined, 300);
	expect(slow.timedOut).toBe(true);
});

test("twice per message at most, then a note that leaves it to the user; nothing when no file was edited or the check passes", async () => {
	const cwd = folder({ "check.sh": "echo 'src/a.ts(1,1): error TS1: bad'; exit 1\n" });
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	let command: string | undefined = "sh check.sh";
	diagnosticsExtension({ command: () => command, shell: () => "/bin/sh" })({ on: (name: string, h: (e: unknown, c: unknown) => unknown) => handlers.set(name, h) } as never);
	const fire = (name: string, event: unknown = {}) => handlers.get(name)!(event, { cwd });
	await fire("session_start");
	const edit = () => fire("tool_result", { toolName: "edit", input: { path: "src/a.ts" } });
	const settle = async () => (await fire("agent_before_settle", { outcome: "completed", entries: [] })) as { continue?: boolean; entries: { details: { summary: string } }[] } | undefined;

	expect(await settle()).toBeUndefined(); // nothing edited
	const results = [];
	for (let i = 0; i <= MAX_CHECK_ROUNDS; i++) {
		await edit();
		results.push(await settle());
	}
	expect(results.map((r) => [r?.continue ?? false, r?.entries[0]?.details.summary])).toEqual([
		[true, "Checked with sh check.sh: 1 problem in files it changed"],
		[true, "Checked with sh check.sh: 1 problem in files it changed"],
		[false, "Checked with sh check.sh: 1 problem in files it changed (left for you)"],
	]);

	// A new message from the user starts again; a failed edit or a passing check adds nothing.
	expect(await fire("input")).toEqual({ action: "continue" });
	await fire("tool_result", { toolName: "edit", input: { path: "src/a.ts" }, isError: true });
	expect(await settle()).toBeUndefined();
	await edit();
	expect((await settle())?.continue).toBe(true);
	writeFileSync(join(cwd, "check.sh"), "exit 0\n");
	await edit();
	expect(await settle()).toBeUndefined();
	command = undefined;
	await edit();
	expect(await settle()).toBeUndefined();
});

// Found in the real-use pass (2026-11-24, docs/research/par-pass-2026-11-24.md F3): `total()` in cart.ts started
// returning a string, checkout.ts (not edited) broke, and the check said nothing.
test("with a baseline before the first edit, a break in a file it didn't edit counts; one that was already there doesn't", async () => {
	// The check's output is a file the test rewrites between the baseline and the end of the run.
	const cwd = folder({ "out.txt": "src/old.ts(1,1): error TS1005: ';' expected.\n", "check.sh": "cat out.txt; grep -q error out.txt && exit 1; exit 0\n" });
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	diagnosticsExtension({ command: () => "sh check.sh", shell: () => "/bin/sh" })({ on: (name: string, h: (e: unknown, c: unknown) => unknown) => handlers.set(name, h) } as never);
	const fire = (name: string, event: unknown = {}) => handlers.get(name)!(event, { cwd });
	await fire("session_start");
	await fire("input");
	await fire("tool_call", { toolName: "edit", input: { path: "src/cart.ts" } }); // the baseline: old.ts is already broken
	writeFileSync(join(cwd, "out.txt"), ["src/old.ts(1,1): error TS1005: ';' expected.", "src/checkout.ts(5,43): error TS2551: Property 'toFixed' does not exist on type 'string'."].join("\n"));
	await fire("tool_result", { toolName: "edit", input: { path: "src/cart.ts" } });
	const r = (await fire("agent_before_settle", { outcome: "completed", entries: [] })) as { continue?: boolean; entries: { content: string; details: { summary: string } }[] };
	expect(r.continue).toBe(true);
	expect(r.entries[0]!.details.summary).toBe("Checked with sh check.sh: 1 new problem since its first edit");
	expect(r.entries[0]!.content).toContain("src/checkout.ts(5,43): error TS2551");
	expect(r.entries[0]!.content).not.toContain("src/old.ts");

	// The same problem on another line is still the old one.
	expect(problemKeys("src/a.ts(3,7): error TS1: bad", "/p")).toEqual(problemKeys("src/a.ts(40,2): error TS1: bad", "/p"));
	expect(problemsIn("src/a.ts(40,2): error TS1: bad\nsrc/b.ts(1,1): error TS2: worse", [], "/p", problemKeys("src/a.ts(3,7): error TS1: bad", "/p"))).toEqual(["src/b.ts(1,1): error TS2: worse"]);
	expect(problemsIn("error[E0308]: mismatched types\n  --> src/lib.rs:4:9", [], "/p", new Set())).toEqual(["error[E0308]: mismatched types", "  --> src/lib.rs:4:9"]);
});

test("a slow check gets no baseline: only the edited files count", async () => {
	const cwd = folder({ "check.sh": "echo 'src/other.ts(1,1): error TS1: bad'; exit 1\n" });
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	const calls: string[] = [];
	diagnosticsExtension({ command: () => "sh check.sh", shell: () => "/bin/sh", wrap: (c) => (calls.push(c), c) })({ on: (name: string, h: (e: unknown, c: unknown) => unknown) => handlers.set(name, h) } as never);
	const fire = (name: string, event: unknown = {}) => handlers.get(name)!(event, { cwd });
	await fire("session_start");
	const now = Date.now;
	let t = 0;
	Date.now = () => (t += BASELINE_MAX_MS + 1);
	try {
		await fire("tool_call", { toolName: "edit", input: { path: "src/a.ts" } }); // baseline, and it was slow
		await fire("tool_result", { toolName: "edit", input: { path: "src/a.ts" } });
		expect(await fire("agent_before_settle", { outcome: "completed", entries: [] })).toBeUndefined(); // other.ts is new, but no baseline counts it
		await fire("input");
		await fire("tool_call", { toolName: "edit", input: { path: "src/a.ts" } });
	} finally {
		Date.now = now;
	}
	expect(calls).toHaveLength(2); // the first baseline and the settle; the next message skips its baseline
});
