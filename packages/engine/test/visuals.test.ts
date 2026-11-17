import { describe, expect, it } from "vitest";
import { decide } from "@piopio/pi-extensions";
import { AppServices } from "../src/app-services.js";
import type { TimelineItem } from "@piopio/protocol";
import { MAX_VISUAL_BYTES, replacedVisuals, showVisual, visualChecker, VISUALS_SECTION } from "../src/tools/visuals.js";
import { groupSteps } from "../src/timeline/steps.js";
import { toMarkdown } from "../src/export.js";

describe("show_visual (docs/spec/25)", () => {
	it("answers with a short line, never the HTML", () => {
		const r = showVisual({ title: "Usage card: three options", html: "<div class='a'>A</div><script>piopio.send('x')</script>" });
		expect(r).toEqual({ text: 'Shown to the user as "Usage card: three options".' });
	});

	it("refuses an empty or oversized visual", () => {
		expect(showVisual({ title: "x", html: "  " }).isError).toBe(true);
		const big = showVisual({ title: "x", html: "a".repeat(MAX_VISUAL_BYTES + 1) });
		expect(big.isError).toBe(true);
		expect(big.text).toContain("over the 300 KB limit");
	});

	it("warns when the HTML reaches for the internet", () => {
		expect(showVisual({ title: "c", html: '<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>' }).text).toContain("can't reach");
		expect(showVisual({ title: "c", html: "<script>fetch('https://api.example.com')</script>" }).text).toContain("can't reach");
		expect(showVisual({ title: "c", html: '<script src="piopio-lib://chart.js"></script>' }).text).toBe('Shown to the user as "c".');
	});

	it("tells the model the tokens and the bundled libraries", () => {
		for (const s of ["--fg", "--c1", "piopio-lib://chart.js", "piopio-lib://d3.js", 'from "three"', "piopio.send("]) expect(VISUALS_SECTION).toContain(s);
	});

	it("runs in every mode, Read only too", () => {
		expect(decide("read_only", "show_visual", { title: "t", html: "<b>x</b>" }, "/tmp", [])).toEqual({ action: "allow" });
		expect(decide("ask", "show_visual", { title: "t", html: "<b>x</b>" }, "/tmp", [])).toEqual({ action: "allow" });
	});

	it("is checked by an app that draws visuals, with the call's id, and only by one that says so", async () => {
		const app = new AppServices();
		const ref = { kind: "build" as const, id: "s1" };
		const seen: unknown[] = [];
		app.addToolServer(async () => ({ ok: true, output: "browser-only app" }), { browser: true });
		const check = visualChecker(app, ref);
		expect((await check({ title: "t", html: "<b>x</b>" }, "call-1")).text).toContain("wasn't drawn or checked");

		app.addToolServer(async (call) => {
			seen.push(call);
			return { ok: true, output: "Drawn at 720 × 140 px. No script errors.", images: [{ mimeType: "image/jpeg", data: "AAA" }] };
		}, { visuals: true });
		const r = await check({ title: "t", html: "<b>x</b>", look: true }, "call-2");
		expect(r).toEqual({ text: "Drawn at 720 × 140 px. No script errors.", images: [{ mimeType: "image/jpeg", data: "AAA" }] });
		expect(seen).toEqual([{ name: "show_visual", args: { title: "t", html: "<b>x</b>", look: true, callId: "call-2" }, ref, groups: ["visuals"], shortcuts: [] }]);
	});

	it("is recorded without the app, and says it wasn't checked", async () => {
		const r = await visualChecker(new AppServices(), { kind: "build", id: "s1" })({ title: "t", html: "x" }, "c");
		expect(r.text).toContain("wasn't drawn or checked");
		expect(r.images).toEqual([]);
	});

	describe("a redraw in the same turn replaces the earlier one (§3.4)", () => {
		const at = "2026-11-18T00:00:00.000Z";
		const user = (id: string): TimelineItem => ({ kind: "user", id, at, text: "chart please" }) as TimelineItem;
		const visual = (id: string, title: string, status = "done"): TimelineItem =>
			({ kind: "tool", id, at, callId: `c-${id}`, tool: "show_visual", status, args: { title, html: `<b>${id}</b>` } }) as TimelineItem;
		const text = (id: string): TimelineItem => ({ kind: "assistant", id, at, status: "done", parts: [{ type: "text", text: "Fixed." }] }) as TimelineItem;

		it("by title, within the turn only", () => {
			const items = [user("u1"), visual("v1", "Zaragoza 2025-26"), text("a1"), visual("v2", " zaragoza 2025-26 "), visual("v3", "Another idea"), visual("v4", "Zaragoza 2025-26"), user("u2"), visual("v5", "Zaragoza 2025-26")];
			expect([...replacedVisuals(items)]).toEqual(["v1", "v2"]);
		});

		it("not by a call that failed, which a later good one replaces", () => {
			expect([...replacedVisuals([visual("v1", "T"), visual("v2", "T", "error")])]).toEqual([]);
			expect([...replacedVisuals([visual("v1", "T", "error"), visual("v2", "T")])]).toEqual(["v1"]);
		});

		it("folds the earlier version into the steps line and leaves the last as a card", () => {
			const items = [user("u1"), visual("v1", "T"), visual("v2", "T")];
			const replaced = replacedVisuals(items);
			const out = groupSteps(items, (t) => t.tool === "show_visual" && !replaced.has(t.id));
			expect(out.map((i) => i.kind === "steps" ? `steps:${i.tools.map((t) => t.id)}` : i.id)).toEqual(["u1", "steps:v1", "v2"]);
		});

		it("is left out of an export", () => {
			const md = toMarkdown("Chat", [user("u1"), visual("v1", "T"), visual("v2", "T")]);
			expect(md.match(/\*\*Visual: T\*\*/g)).toHaveLength(1);
			expect(md).not.toContain("<b>v1</b>");
		});

		it("says so in the result, and the prompt tells the model how", () => {
			expect(showVisual({ title: "T", html: "<b>x</b>" }, true).text).toBe('Shown to the user as "T", in place of the earlier one.');
			expect(VISUALS_SECTION).toContain("again with the same title");
			expect(VISUALS_SECTION).toContain("#rrggbb");
		});
	});
});
