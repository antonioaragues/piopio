#!/usr/bin/env node
// Routing replay (roadmap 3.4, 04-chat S10): sends the 50 messages of packages/engine/test/replay/routing-50.json
// to a fresh Space's Main, one after another, and scores where the organizer sent each one.
//
//   node scripts/routing-replay.mjs                      # OpenRouter; key from OPENROUTER_API_KEY or the Keychain
//   node scripts/routing-replay.mjs --model <id>         # the organizer's model (default: Piopio's default model)
//   node scripts/routing-replay.mjs --topic-model <id>   # the topics' model (default: the organizer's)
//   node scripts/routing-replay.mjs --faux               # scripted model: checks the plumbing only (it never routes)
//   node scripts/routing-replay.mjs --limit 10 --out report.json
//
// Costs real money with OpenRouter: every message is one organizer turn, and every routed one a topic reply.
// Build first: corepack pnpm -r build
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const flag = (name) => args.includes(`--${name}`);
const option = (name) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1] : undefined);
const faux = flag("faux");
const limit = Number(option("limit") ?? 50);

if (!faux) {
	process.env.PIOPIO_ALLOW_ENV_SECRETS = "1";
	process.env.OPENROUTER_API_KEY ??= (() => {
		try {
			return execFileSync("security", ["find-generic-password", "-s", "Piopio", "-a", "provider.openrouter.apiKey", "-w"], { encoding: "utf8" }).trim();
		} catch {
			console.error("No OpenRouter key: set OPENROUTER_API_KEY, or add the key in Piopio first.");
			process.exit(1);
		}
	})();
}

const { Engine } = await import(join(root, "packages/engine/dist/server.js"));
const { enginePaths } = await import(join(root, "packages/engine/dist/paths.js"));
const set = JSON.parse(readFileSync(join(root, "packages/engine/test/replay/routing-50.json"), "utf8"));

const home = mkdtempSync(join(tmpdir(), "piopio-replay-"));
const engine = new Engine({ paths: enginePaths(home), faux, log: () => {} });
const sessions = engine.sessions;
const organizer = option("model") ? { provider: "openrouter", id: option("model") } : undefined;
const topicModel = option("topic-model") ? { provider: "openrouter", id: option("topic-model") } : organizer;

const ref = await sessions.create({ kind: "space", title: set.space.name, instructions: set.space.instructions, ...(topicModel ? { model: topicModel } : {}) });
if (organizer) await sessions.configureSpace(ref, { organizerModel: organizer });
const space = await sessions.space(ref);
for (const t of set.topics) await space.newTopic(t.title, t.brief);

const aliases = new Map(); // "@Garden" → the topic id the organizer created for it
const titleOf = (id) => space.topics.find((t) => t.id === id)?.title ?? id;
const results = [];
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

for (const [i, m] of set.messages.slice(0, limit).entries()) {
	const before = new Set(space.snapshot().items.map((it) => it.id));
	const started = Date.now();
	await space.submit(m.text, { whenBusy: "followUp" });
	let decidedAt;
	// The organizer's turn: done when Main is idle again and something new is there.
	for (let tries = 0; tries < 1200; tries++) {
		await wait(100);
		const snap = space.snapshot();
		const fresh = snap.items.filter((it) => !before.has(it.id));
		if (!decidedAt && fresh.some((it) => it.kind === "routing" || (it.kind === "assistant" && it.parts.some((p) => p.type === "text" && p.text)))) decidedAt = Date.now();
		if (snap.state.status === "idle" && fresh.some((it) => it.kind === "routing" || (it.kind === "assistant" && it.status !== "streaming"))) break;
	}
	const fresh = space.snapshot().items.filter((it) => !before.has(it.id));
	const routing = fresh.find((it) => it.kind === "routing");
	const got = routing ? { decision: routing.decision, topic: routing.topicId, title: routing.topicTitle } : { decision: "answer" };
	if (m.as && got.decision === "create") aliases.set(`@${m.as}`, got.topic);
	const right = m.accept.some((a) => {
		if (a.decision !== got.decision) return false;
		if (!a.topic) return true;
		const want = a.topic.startsWith("@") ? aliases.get(a.topic) : space.topics.find((t) => t.title.toLowerCase() === a.topic.toLowerCase())?.id;
		return want !== undefined && want === got.topic;
	});
	const ms = (decidedAt ?? Date.now()) - started;
	results.push({ n: i + 1, text: m.text, expected: m.accept.map((a) => (a.topic ? `${a.decision} ${a.topic}` : a.decision)).join(" | "), got: got.topic ? `${got.decision} ${titleOf(got.topic)}` : got.decision, right, ms, ...(routing?.reason ? { reason: routing.reason } : {}) });
	console.log(`${right ? "✓" : "✗"} ${String(i + 1).padStart(2)} ${(ms / 1000).toFixed(1).padStart(5)}s  ${got.topic ? `${got.decision} → ${titleOf(got.topic)}` : got.decision}${right ? "" : `   (expected ${results.at(-1).expected})`}  ${m.text.slice(0, 60)}`);
}

const right = results.filter((r) => r.right).length;
const times = results.map((r) => r.ms).sort((a, b) => a - b);
const pct = (p) => times[Math.min(times.length - 1, Math.floor(p * times.length))] / 1000;
const report = {
	at: new Date().toISOString(),
	organizerModel: organizer ?? sessions.list("space")[0].model,
	topicModel: topicModel ?? sessions.list("space")[0].model,
	accuracy: right / results.length,
	right,
	total: results.length,
	decisionSeconds: { median: pct(0.5), p90: pct(0.9), max: pct(1) },
	costUsd: sessions.list("space")[0].space?.costUsd ?? 0,
	results,
};
console.log(`\n${right}/${results.length} right (${(report.accuracy * 100).toFixed(1)}%, acceptance ≥ 90%). Decision time: median ${report.decisionSeconds.median}s, p90 ${report.decisionSeconds.p90}s (S10 budget ~1.5s). Cost $${report.costUsd.toFixed(4)}.`);
if (option("out")) writeFileSync(option("out"), JSON.stringify(report, null, "\t"));
await sessions.closeAll();
await engine.chatMcp.close();
process.exit(0);
