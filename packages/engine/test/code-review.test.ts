/** Review by an agent (docs/spec/05-build "Review by an agent", roadmap PAR4), with the scripted model. */
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SessionEvent, SessionSummary, Snapshot } from "@piopio/protocol";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(): Promise<Ctx> {
	const home = mkdtempSync(join(tmpdir(), "piopio-review-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: ["secrets.set"] });
	const ctx = { home, engine, client };
	open.push(ctx);
	return ctx;
}

afterEach(async () => {
	for (const ctx of open.splice(0)) {
		ctx.client.close();
		await ctx.engine.stop();
	}
});

const states = (a: Ctx, sub: string) => a.client.events.filter((n) => n.subscriptionId === sub).flatMap((n) => n.events).filter((e): e is Extract<SessionEvent, { type: "state" }> => e.type === "state");
async function settle(a: Ctx, ref: unknown, sub: string, text: string) {
	const before = states(a, sub).length;
	await a.client.call("sessions.submit", { ref, input: { text } });
	await a.client.waitFor(() => states(a, sub).slice(before).some((e) => e.state.status === "running") && states(a, sub).at(-1)!.state.status === "idle", 20_000);
}
const summaryOf = async (a: Ctx, id: string) => ((await a.client.call("sessions.list", { kind: "build" })).sessions as SessionSummary[]).find((s) => s.ref.id === id)!;
async function until<T>(read: () => Promise<T>, ok: (v: T) => boolean): Promise<T> {
	for (let i = 0; i < 100; i++) {
		const v = await read();
		if (ok(v)) return v;
		await new Promise((r) => setTimeout(r, 100));
	}
	return read();
}

function repo(): string {
	const folder = realpathSync(mkdtempSync(join(tmpdir(), "piopio-review-repo-")));
	const g = (...args: string[]) => execFileSync("git", args, { cwd: folder, stdio: "pipe" });
	g("init", "-q", "-b", "main");
	g("config", "user.email", "t@example.com");
	g("config", "user.name", "T");
	writeFileSync(join(folder, "package.json"), "{}");
	writeFileSync(join(folder, "cart.js"), "export function total(items) {\n  return items.reduce((s, i) => s + i.price, 0);\n}\n");
	g("add", ".");
	g("commit", "-q", "-m", "first");
	return folder;
}

const FINDINGS = {
	summary: "One real bug in the total.",
	findings: [
		{ severity: "bug", file: "cart.js", line: 2, title: "Quantity is ignored", detail: "total() adds each price once, so two of an item cost the same as one.", suggestion: "Multiply by i.qty." },
		{ severity: "nit", file: "cart.js", line: 1, title: "Name", detail: "total is vague." },
	],
};

test("a session's changes: the reviewer gets the diff; its findings land on the session, which fixes or dismisses them", { timeout: 60_000 }, async () => {
	const a = await start();
	const folder = repo();
	// Trusted, as your own projects are: Full access needs it (docs/spec/39).
	const { project: added } = (await a.client.call("projects.add", { path: folder })) as { project: { id: string } };
	await a.client.call("projects.configure", { id: added.id, trust: true });
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	const sub = (await a.client.call("sessions.subscribe", { ref })).subscriptionId as string;
	await a.client.call("sessions.configure", { ref, approvalMode: "full_auto" });
	await settle(a, ref, sub, "edit: cart.js | s + i.price | s + i.price * 1");

	const { ref: reviewer } = await a.client.call("sessions.review", { ref });
	const rsub = (await a.client.call("sessions.subscribe", { ref: reviewer })).subscriptionId as string;
	let summary = await summaryOf(a, ref.id);
	expect(summary.review).toMatchObject({ reviewer, target: "this session's changes", status: "running", findings: [] });
	const reviewerSummary = await summaryOf(a, reviewer.id);
	expect(reviewerSummary.title).toBe(`Review · ${summary.title}`);
	const first = ((await a.client.call("sessions.open", { ref: reviewer })) as Snapshot).items.find((i) => i.kind === "user");
	expect(first?.kind === "user" && first.text).toMatch(/^Review this session's changes\. The diff is attached as changes\.diff/);
	expect(first).toMatchObject({ attachments: [{ name: "changes.diff", kind: "text" }] });
	expect(((await a.client.call("sessions.open", { ref: reviewer })) as Snapshot).state.approvalMode).toBe("read_only");

	// The scripted model only echoes: the review ends without a report, so it failed.
	summary = await until(() => summaryOf(a, ref.id), (s) => s.review?.status !== "running");
	expect(summary.review).toMatchObject({ status: "failed", summary: "The review ended without reporting findings." });

	// Reporting lands on the reviewed session.
	await settle(a, reviewer, rsub, `call: report_findings | ${JSON.stringify(FINDINGS)}`);
	summary = await summaryOf(a, ref.id);
	expect(summary.review).toMatchObject({ status: "done", summary: "One real bug in the total." });
	expect(summary.review!.findings.map((f) => [f.id, f.severity, f.file, f.line, f.state])).toEqual([
		["f1", "bug", "cart.js", 2, "open"],
		["f2", "nit", "cart.js", 1, "open"],
	]);
	await a.client.call("sessions.reviewFinding", { ref, id: "f2", state: "dismissed" });
	expect((await summaryOf(a, ref.id)).review!.findings[1]!.state).toBe("dismissed");

	// Fix, as the app does it: the message, then the finding marked fixing; when that turn finishes, it's fixed.
	await a.client.call("sessions.submit", { ref, input: { text: "Fix this from the review of this session's changes: the total multiplies by 1." } });
	await a.client.call("sessions.reviewFinding", { ref, id: "f1", state: "fixing" });
	summary = await until(() => summaryOf(a, ref.id), (s) => s.review!.findings[0]!.state !== "fixing");
	expect(summary.review!.findings.map((f) => f.state)).toEqual(["fixed", "dismissed"]);
});

test("with no changes in the session, its branch against main; with nothing at all, it says so", { timeout: 40_000 }, async () => {
	const a = await start();
	const folder = repo();
	execFileSync("git", ["checkout", "-q", "-b", "fix-total"], { cwd: folder });
	writeFileSync(join(folder, "cart.js"), "export const total = (items) => items.length;\n");
	execFileSync("git", ["commit", "-qam", "simpler"], { cwd: folder });
	// Trusted, as your own projects are: Full access needs it (docs/spec/39).
	const { project: added } = (await a.client.call("projects.add", { path: folder })) as { project: { id: string } };
	await a.client.call("projects.configure", { id: added.id, trust: true });
	const { ref } = await a.client.call("sessions.create", { kind: "build", cwd: folder });
	await a.client.call("sessions.subscribe", { ref });
	const { ref: reviewer } = await a.client.call("sessions.review", { ref });
	expect((await summaryOf(a, ref.id)).review?.target).toBe("branch fix-total against main");
	const first = ((await a.client.call("sessions.open", { ref: reviewer })) as Snapshot).items.find((i) => i.kind === "user");
	expect(first?.kind === "user" && first.text).toMatch(/^Review branch fix-total against main\./);

	const plain = repo();
	// Trusted, as your own projects are: Full access needs it (docs/spec/39).
	const { project: addedPlain } = (await a.client.call("projects.add", { path: plain })) as { project: { id: string } };
	await a.client.call("projects.configure", { id: addedPlain.id, trust: true });
	const other = await a.client.call("sessions.create", { kind: "build", cwd: plain });
	await expect(a.client.call("sessions.review", { ref: other.ref })).rejects.toThrow(/nothing to review/);
});
