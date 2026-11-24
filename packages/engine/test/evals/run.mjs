#!/usr/bin/env node
// Piopio's eval runner (docs/launch-plan.md §5), first slice: real models and the real coding agents doing real jobs
// in a fixture project, checked on the result. Opt-in: run by hand or nightly, never on every push. Costs real money.
//
//   node packages/engine/test/evals/run.mjs                      # the default runners, every scenario
//   node packages/engine/test/evals/run.mjs --runners openrouter:anthropic/claude-haiku-5.5,claude-code:haiku
//   node packages/engine/test/evals/run.mjs --scenarios preview-fix,review-fix --budget 1 --label nightly
//   node packages/engine/test/evals/run.mjs --list               # the scenarios and runners, nothing run
//
// Runners are `<provider>:<model id>`: openrouter:… (Piopio's own agent, OPENROUTER_API_KEY from the environment),
// claude-code:…, codex-cli:…, antigravity-cli:… (the CLIs on this Mac, signed in). Build first: corepack pnpm -r build.
// See README.md here.
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ChromeStandIn } from "./browser.mjs";
import { startEngine } from "./engine.mjs";
import { SCENARIOS, ownTool } from "./scenarios.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "../../../..");
const args = process.argv.slice(2);
const option = (name) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1] : undefined);
const verbose = args.includes("--verbose");

const CODING_AGENTS = { "claude-code": "claude", "codex-cli": "codex-acp", "antigravity-cli": "agy" };
const DEFAULT_RUNNERS = ["openrouter:anthropic/claude-haiku-5.5", "claude-code:haiku"];

const onPath = (cmd) => {
	try {
		execFileSync("/usr/bin/which", [cmd], { stdio: "ignore" });
		return true;
	} catch {
		return false;
	}
};

const runners = (option("runners")?.split(",") ?? DEFAULT_RUNNERS).map((spec) => {
	const i = spec.indexOf(":");
	if (i < 0) throw new Error(`A runner is <provider>:<model id>, not ${spec}`);
	const provider = spec.slice(0, i);
	return { spec, model: { provider, id: spec.slice(i + 1) }, kind: CODING_AGENTS[provider] ? "agent" : "piopio" };
});
const scenarios = option("scenarios") ? option("scenarios").split(",").map((id) => SCENARIOS.find((s) => s.id === id) ?? (() => { throw new Error(`No scenario ${id}`); })()) : SCENARIOS;
const budget = Number(option("budget") ?? 2);
const repeat = Number(option("repeat") ?? 1);

if (args.includes("--list")) {
	for (const s of SCENARIOS) console.log(`${s.id.padEnd(22)} ${s.runners === "all" ? "every runner " : "Piopio's agent"}  ${s.title}`);
	console.log(`\nDefault runners: ${DEFAULT_RUNNERS.join(", ")}`);
	process.exit(0);
}

// ── Before spending anything ──────────────────────────────────────────────────────────────────────────────────

/** Runners asked for that can't run here, and why: kept in the results so a missing runner isn't read as a pass. */
const notRun = [];
const usable = runners.filter((r) => {
	const why =
		r.kind === "piopio" && r.model.provider === "openrouter" && !process.env.OPENROUTER_API_KEY ? "OPENROUTER_API_KEY isn't set"
		: r.kind === "agent" && !onPath(CODING_AGENTS[r.model.provider]) ? `${CODING_AGENTS[r.model.provider]} isn't on PATH`
		: undefined;
	if (!why) return true;
	console.error(`Skipping ${r.spec}: ${why}.`);
	notRun.push({ runner: r.spec, why });
	return false;
});
if (!usable.length) process.exit(1);

const dist = join(root, "packages/engine/dist/main.js");
if (!existsSync(dist)) {
	console.error("Build first: corepack pnpm -r build");
	process.exit(1);
}
/** The newest .ts under the engine's sources and the packages it bundles, against the build. */
const newest = (dir) => {
	let t = 0;
	for (const e of readdirSync(dir, { withFileTypes: true })) {
		const p = join(dir, e.name);
		t = Math.max(t, e.isDirectory() ? newest(p) : e.name.endsWith(".ts") ? statSync(p).mtimeMs : 0);
	}
	return t;
};
const stale = ["engine", "extensions", "runtime", "protocol"].filter((p) => existsSync(join(root, "packages", p, "src")) && newest(join(root, "packages", p, "src")) > statSync(dist).mtimeMs);
if (stale.length) console.error(`Warning: packages/${stale.join(", ")} changed after the engine's last build; run corepack pnpm -r build to test them.`);

const version = (cmd, flag = "--version") => {
	try {
		return execFileSync(cmd, [flag], { encoding: "utf8", timeout: 10_000 }).trim().split("\n")[0];
	} catch {
		return undefined;
	}
};
const piVersion = JSON.parse(readFileSync(join(root, "packages/engine/package.json"), "utf8")).dependencies["@earendil-works/pi-coding-agent"];
const commit = execFileSync("git", ["-C", root, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
const dirty = execFileSync("git", ["-C", root, "status", "--porcelain", "--untracked-files=no"], { encoding: "utf8" }).trim() !== "";

// ── One scenario on one runner ────────────────────────────────────────────────────────────────────────────────

const typescript = (() => {
	try {
		return execFileSync("/bin/sh", ["-c", `cd "${join(root, "node_modules/typescript")}" && pwd -P`], { encoding: "utf8" }).trim();
	} catch {
		throw new Error("No typescript in the repo's node_modules: corepack pnpm install");
	}
})();

const freePort = () =>
	new Promise((resolve) => {
		const s = createServer().listen(0, "127.0.0.1", () => {
			const { port } = s.address();
			s.close(() => resolve(port));
		});
	});

/** The fixture in a temp folder: its own port, TypeScript linked in, a git repository at its first commit. */
async function project(work) {
	const dir = join(work, "par-shop");
	cpSync(join(here, "fixtures/par-shop"), dir, { recursive: true });
	const port = await freePort();
	const server = join(dir, "server.mjs");
	writeFileSync(server, readFileSync(server, "utf8").replace("|| 5173", `|| ${port}`));
	mkdirSync(join(dir, "node_modules/.bin"), { recursive: true });
	symlinkSync(typescript, join(dir, "node_modules/typescript"));
	symlinkSync("../typescript/bin/tsc", join(dir, "node_modules/.bin/tsc"));
	const git = (...a) => execFileSync("git", ["-C", dir, "-c", "user.name=Piopio evals", "-c", "user.email=evals@piopio.invalid", "-c", "commit.gpgsign=false", ...a], { encoding: "utf8" });
	git("init", "-q", "-b", "main");
	git("add", "-A");
	git("commit", "-q", "-m", "par-shop");
	return { dir, port, git };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The approval policy: allow what the agent asks (each counted), answer questions with "use your judgment". */
const POLICY = (prompt) => {
	if (prompt.kind === "approval") return { decision: "allow" };
	if (prompt.kind === "confirm") return { confirmed: true };
	if (prompt.kind === "plan") return { decision: "allow" };
	if (prompt.options?.length) return { choice: prompt.options[0] };
	return { text: "Go ahead, use your judgment." };
};

async function runOne(scenario, runner, browser, spent) {
	const work = mkdtempSync(join(tmpdir(), "piopio-eval-work-"));
	const p = await project(work);
	const engine = await startEngine(root, { log: verbose ? (d) => process.stderr.write(`  [engine] ${d}`) : undefined });
	const { client } = engine;
	browser.calls = [];
	client.appTool = (params) => (params.groups?.includes("browser") && params.name.startsWith("browser_") ? browser.tool(params) : { ok: false, output: "Not available in the eval runner." });
	const sessions = [];
	const approvals = [];
	const answered = new Set();
	const started = Date.now();
	const deadline = started + scenario.timeoutMs;
	const usage = async () => {
		const sum = { costUsd: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0 };
		for (const ref of sessions) {
			const u = (await client.call("sessions.open", { ref }).catch(() => undefined))?.state.usage;
			for (const k of Object.keys(sum)) sum[k] += u?.[k] ?? 0;
		}
		return sum;
	};
	const cost = async () => (await usage()).costUsd;
	/** Answers whatever the sessions wait on, by the policy. */
	const answer = async (refs) => {
		for (const ref of refs) {
			const snap = await client.call("sessions.open", { ref });
			for (const prompt of snap.state.prompts ?? []) {
				if (answered.has(prompt.id)) continue;
				answered.add(prompt.id);
				const response = POLICY(prompt);
				approvals.push({ kind: prompt.kind, tool: prompt.tool, title: prompt.title, detail: prompt.detail?.slice(0, 300), reason: prompt.reason, answer: response.decision ?? response.choice ?? response.text ?? response.confirmed, own: ownTool(prompt) });
				if (verbose) console.error(`  asked: ${prompt.title}${prompt.detail ? ` · ${prompt.detail.slice(0, 120)}` : ""}`);
				await client.call("sessions.respond", { ref, promptId: prompt.id, response });
			}
		}
	};
	const overBudget = async () => spent + (await cost()) > budget;
	const ctx = {
		client,
		browser,
		port: p.port,
		approvals,
		git: p.git,
		read: (file) => readFileSync(join(p.dir, file), "utf8"),
		write: (file, text) => writeFileSync(join(p.dir, file), text),
		track: (ref) => sessions.push(ref),
		async session() {
			ctx.projectId ??= (await client.call("projects.add", { path: p.dir })).project.id;
			const { ref } = await client.call("sessions.create", { kind: "build", cwd: p.dir, model: runner.model, approvalMode: "auto_edit" });
			sessions.push(ref);
			return ref;
		},
		snapshot: (ref) => client.call("sessions.open", { ref }),
		summary: async (ref) => (await client.call("sessions.list", { kind: "build" })).sessions.find((s) => s.ref.id === ref.id),
		tools: (items) => items.flatMap((i) => (i.kind === "tool" ? [i] : i.kind === "steps" ? i.tools : [])),
		/** Sends a message and waits for the turn to end, answering prompts on the way. */
		async turn(ref, text, { afterSubmit } = {}) {
			const r = await client.call("sessions.submit", { ref, input: { text } });
			if (!r.accepted) throw new Error("The message wasn't accepted.");
			await afterSubmit?.();
			const sent = Date.now();
			let ran = false;
			for (;;) {
				await answer(sessions);
				const { state } = await client.call("sessions.open", { ref });
				if (state.status !== "idle") ran = true;
				if (state.status === "idle" && (ran || Date.now() - sent > 5000)) return;
				if (state.status === "error") throw new Error("The session ended in an error.");
				if (Date.now() > deadline) {
					await client.call("sessions.abort", { ref }).catch(() => {});
					throw new Error(`Timed out after ${Math.round(scenario.timeoutMs / 1000)} s.`);
				}
				if (await overBudget()) {
					await client.call("sessions.abort", { ref }).catch(() => {});
					throw new Error(`Over the run's budget ($${budget}).`);
				}
				await sleep(500);
			}
		},
		/** Polls `read` until `ready`, answering prompts of `prompts` sessions meanwhile. */
		async until(read, ready, { prompts = [], timeoutMs } = {}) {
			const end = timeoutMs ? Date.now() + timeoutMs : deadline;
			for (;;) {
				await answer(prompts);
				const value = await read();
				if (ready(value)) return value;
				if (Date.now() > end) throw new Error("Timed out waiting.");
				if (await overBudget()) throw new Error(`Over the run's budget ($${budget}).`);
				await sleep(700);
			}
		},
		async typecheck() {
			try {
				execFileSync("npm", ["run", "--silent", "typecheck"], { cwd: p.dir, stdio: "ignore", timeout: 60_000 });
				return true;
			} catch {
				return false;
			}
		},
	};
	let checks = {};
	let error;
	try {
		await scenario.setup?.(ctx);
		checks = await scenario.run(ctx);
	} catch (e) {
		error = e.message;
	}
	const used = await usage();
	const usd = used.costUsd;
	const toolCalls = {};
	for (const ref of sessions) for (const t of ctx.tools((await client.call("sessions.open", { ref }).catch(() => ({ items: [] }))).items)) toolCalls[t.tool] = (toolCalls[t.tool] ?? 0) + 1;
	const failedLog = error || Object.values(checks).some((c) => !c.pass) ? engine.stderr.join("") || "(the engine logged nothing)\n" : "";
	// A failed scenario keeps its conversations (the data folder goes with the engine), beside the project.
	if (failedLog) {
		const snapshots = [];
		for (const ref of sessions) snapshots.push(await client.call("sessions.open", { ref }).catch((e) => ({ ref, error: e.message })));
		writeFileSync(join(work, "sessions.json"), `${JSON.stringify(snapshots, null, "\t")}\n`);
	}
	await engine.stop();
	let log;
	if (failedLog) {
		log = join(tmpdir(), "piopio-evals", `${scenario.id}-${runner.spec.replace(/[^a-z0-9.-]+/gi, "_")}-${Date.now()}.log`);
		mkdirSync(dirname(log), { recursive: true });
		writeFileSync(log, failedLog);
	}
	if (!error && !failedLog) rmSync(work, { recursive: true, force: true });
	return {
		scenario: scenario.id,
		runner: runner.spec,
		pass: !error && Object.keys(checks).length > 0 && Object.values(checks).every((c) => c.pass),
		...(error ? { error } : {}),
		checks,
		costUsd: Math.round(usd * 10000) / 10000,
		// Claude Code, Codex and Antigravity on a plan cost nothing by key (docs/spec/31 CA6): the tokens say how much ran.
		tokens: { input: used.inputTokens, output: used.outputTokens, cacheRead: used.cacheReadTokens },
		seconds: Math.round((Date.now() - started) / 1000),
		approvals,
		toolCalls,
		browserCalls: browser.calls.map((c) => `${c.name}${c.ok ? "" : " (failed)"}`),
		...(log ? { engineLog: log, project: work } : {}),
	};
}

// ── The run ───────────────────────────────────────────────────────────────────────────────────────────────────

const browser = await ChromeStandIn.start(root);
const results = [];
let spent = 0;
const runStarted = new Date();
try {
	for (let i = 0; i < repeat; i++)
		for (const runner of usable)
			for (const scenario of scenarios) {
				if (scenario.runners === "piopio" && runner.kind !== "piopio") continue;
				if (spent >= budget) {
					results.push({ scenario: scenario.id, runner: runner.spec, pass: false, skipped: `the run's budget ($${budget}) was spent` });
					continue;
				}
				process.stderr.write(`${scenario.id} · ${runner.spec} … `);
				const r = await runOne(scenario, runner, browser, spent);
				spent += r.costUsd;
				results.push(r);
				console.error(`${r.pass ? "pass" : "FAIL"} (${r.seconds} s, $${r.costUsd.toFixed(4)}, ${r.approvals.length} asked)${r.error ? ` · ${r.error}` : ""}`);
				for (const [name, c] of Object.entries(r.checks)) if (!c.pass) console.error(`    ✗ ${name}${c.detail ? `: ${c.detail}` : ""}`);
				if (r.engineLog) console.error(`    engine log: ${r.engineLog}; project and sessions.json kept in ${r.project}`);
			}
} finally {
	await browser.stop();
}

const date = `${runStarted.getFullYear()}-${String(runStarted.getMonth() + 1).padStart(2, "0")}-${String(runStarted.getDate()).padStart(2, "0")}`;
const label = option("label") ?? (usable.length === 1 ? usable[0].model.id.split("/").pop() : "run");
const dir = join(here, "results");
mkdirSync(dir, { recursive: true });
let file = join(dir, `${date}-${label}.json`);
for (let n = 2; existsSync(file); n++) file = join(dir, `${date}-${label}-${n}.json`);
const report = {
	at: runStarted.toISOString(),
	commit: `${commit}${dirty ? " (with uncommitted changes)" : ""}`,
	engineBuiltAt: statSync(dist).mtime.toISOString(),
	pi: piVersion,
	agents: { claude: version("claude"), codex: version("codex"), antigravity: version("agy") },
	browser: "headless Google Chrome stand-in (browser.mjs)",
	budgetUsd: budget,
	spentUsd: Math.round(spent * 10000) / 10000,
	passed: `${results.filter((r) => r.pass).length}/${results.length}`,
	...(notRun.length ? { notRun } : {}),
	results,
};
writeFileSync(file, `${JSON.stringify(report, null, "\t")}\n`);

// A table for the README.
console.log(`\n| Scenario | Runner | Result | Time | Cost | Asked |\n|---|---|---|---|---|---|`);
for (const r of results) console.log(`| ${r.scenario} | ${r.runner} | ${r.skipped ? "skipped" : r.pass ? "pass" : "**fail**"} | ${r.seconds ?? "—"} s | $${(r.costUsd ?? 0).toFixed(4)} | ${r.approvals?.length ?? "—"} |`);
for (const n of notRun) console.log(`| (all) | ${n.runner} | not run: ${n.why} | | | |`);
console.log(`\n${report.passed} passed, $${report.spentUsd} spent. Results: ${file.slice(root.length + 1)}`);
process.exit(results.every((r) => r.pass) ? 0 : 1);
