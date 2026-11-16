import { describe, expect, it } from "vitest";
import { decide } from "@piopio/pi-extensions";
import { MAX_VISUAL_BYTES, showVisual, VISUALS_SECTION } from "../src/tools/visuals.js";

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
});
