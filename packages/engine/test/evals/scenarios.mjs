// The scenarios: each a start state (the par-shop fixture at its first commit, sometimes with a branch on top), one or
// more prompts, and checks on the result (files, the typecheck, the tools that ran, the approvals asked), never on the
// words. From the PAR2–PAR5/PAR8 real-use pass, docs/research/par-pass-2026-11-24.md.
import { createConnection } from "node:net";

const PRODUCTS = ["Blue mug", "Steel kettle", "Oak tray"];

/** An approval for one of Piopio's own tools (the browser's, the background commands'), however the runner names it. */
export const ownTool = (p) => /\b(browser|process)_[a-z]+|mcp[._]piopio/i.test(`${p.tool ?? ""} ${p.title ?? ""} ${p.detail ?? ""}`);

const check = (pass, detail) => ({ pass: Boolean(pass), ...(detail ? { detail } : {}) });

const listening = (port) =>
	new Promise((resolve) => {
		const s = createConnection({ host: "127.0.0.1", port }, () => {
			s.end();
			resolve(true);
		});
		s.once("error", () => resolve(false));
	});

export const SCENARIOS = [
	{
		id: "preview-fix",
		title: "Start the dev server, open the preview, find why the list doesn't load, fix it, check (PAR2, PAR3, PAR8)",
		runners: "all",
		timeoutMs: 6 * 60_000,
		async run(ctx) {
			const ref = await ctx.session();
			await ctx.turn(ref, "Start the dev server in the background, open the preview, find why the list of products doesn't load, fix it, and check it in the preview.");
			const app = ctx.read("public/app.js");
			const browser = ctx.browser.calls;
			const last = ctx.browser.lastRead();
			return {
				"app.js asks for /api/products": check(app.includes("/api/products") && !app.includes("/api/items")),
				"the project typechecks": check(await ctx.typecheck()),
				"the last browser read lists the three products": check(PRODUCTS.every((p) => last.includes(p)), last ? undefined : "no browser read"),
				"no browser_eval": check(!browser.some((c) => c.name === "browser_eval"), `${browser.filter((c) => c.name === "browser_eval").length} calls`),
				"no approval for Piopio's own tools": check(!ctx.approvals.some(ownTool), ctx.approvals.filter(ownTool).map((a) => a.title).join("; ") || undefined),
			};
		},
	},
	{
		id: "diagnostics-baseline",
		title: "A change that breaks a file the agent didn't edit: the check reports it against the baseline (PAR5, F3)",
		runners: "piopio",
		timeoutMs: 4 * 60_000,
		async run(ctx) {
			const ref = await ctx.session();
			await ctx.turn(ref, "Change total() in src/cart.ts to return a string with two decimals, like \"12.50\". Don't run any commands.");
			const text = JSON.stringify((await ctx.snapshot(ref)).items);
			const entry = text.match(/Checked with [^:"]+: \d+ new problems? since its first edit/);
			return {
				"a “new problem since its first edit” entry": check(entry, entry?.[0]),
				"total() returns a string": check(/total\([^)]*\)\s*:\s*string/.test(ctx.read("src/cart.ts"))),
				"the project typechecks": check(await ctx.typecheck()),
			};
		},
	},
	{
		id: "review-fix",
		title: "Review finds a planted bug (price + qty) on a branch, then Fix from the finding (PAR4)",
		runners: "all",
		timeoutMs: 6 * 60_000,
		async setup(ctx) {
			// The planted bug, on a branch of its own: the review compares it with main.
			ctx.git("checkout", "-q", "-b", "simplify-total");
			ctx.write("src/cart.ts", ctx.read("src/cart.ts").replace("item.price * item.qty", "item.price + item.qty"));
			ctx.git("commit", "-q", "-am", "Simplify total()");
		},
		async run(ctx) {
			const ref = await ctx.session();
			const { ref: reviewer } = await ctx.client.call("sessions.review", { ref });
			ctx.track(reviewer);
			const review = await ctx.until(async () => (await ctx.summary(ref))?.review, (r) => r && r.status !== "running", { prompts: [reviewer] });
			const line = ctx.read("src/cart.ts").split("\n").findIndex((l) => l.includes("item.price + item.qty")) + 1;
			const finding = review.findings.find((f) => f.file.endsWith("src/cart.ts") && f.severity === "bug" && (f.line === undefined || Math.abs(f.line - line) <= 2));
			const checks = {
				"the review finished": check(review.status === "done", review.status === "done" ? undefined : review.summary),
				"a bug at src/cart.ts near the line": check(finding, review.findings.map((f) => `${f.severity} ${f.file}:${f.line ?? "?"} ${f.title}`).join("; ") || "no findings"),
			};
			if (!finding) return checks;
			// Fix, as the app's ThreadModel.fix sends it: the finding as a message, then marked fixing.
			let text = `- **${finding.title}** (\`${finding.file}${finding.line ? `:${finding.line}` : ""}\`, ${finding.severity}): ${finding.detail}`;
			if (finding.suggestion) text += ` Suggested fix: ${finding.suggestion}`;
			await ctx.turn(ref, `Fix this from the review of ${review.target}:\n\n${text}`, {
				afterSubmit: () => ctx.client.call("sessions.reviewFinding", { ref, id: finding.id, state: "fixing" }),
			});
			const after = await ctx.until(async () => (await ctx.summary(ref))?.review, (r) => r?.findings.find((f) => f.id === finding.id)?.state !== "fixing", { timeoutMs: 20_000 }).catch(() => undefined);
			const state = after?.findings.find((f) => f.id === finding.id)?.state;
			const cart = ctx.read("src/cart.ts");
			return {
				...checks,
				"the finding is fixed": check(state === "fixed", state),
				"the multiplication is back": check(/item\.price\s*\*\s*item\.qty|item\.qty\s*\*\s*item\.price/.test(cart) && !cart.includes("item.price + item.qty")),
				"the project typechecks": check(await ctx.typecheck()),
			};
		},
	},
	{
		id: "background-stop",
		title: "Start the dev server in the background, then ask the agent to stop it (PAR2, TM4)",
		runners: "piopio",
		timeoutMs: 4 * 60_000,
		async run(ctx) {
			const ref = await ctx.session();
			await ctx.turn(ref, "Start the dev server in the background and tell me its address.");
			const started = (await ctx.snapshot(ref)).state.processes ?? [];
			const wasListening = await listening(ctx.port);
			await ctx.turn(ref, "Stop the dev server.");
			const snap = await ctx.snapshot(ref);
			const stop = ctx.tools(snap.items).filter((t) => t.tool === "process_stop");
			return {
				"the server started in the background": check(started.some((p) => p.status === "running") && wasListening, `${started.length} processes, port ${ctx.port} ${wasListening ? "open" : "closed"}`),
				"process_stop ran": check(stop.some((t) => t.status === "done"), `${stop.length} calls`),
				"nothing listens on the port": check(!(await listening(ctx.port)), `port ${ctx.port}`),
				"no command left running": check(!(snap.state.processes ?? []).some((p) => p.status === "running")),
			};
		},
	},
];
