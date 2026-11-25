import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "vitest";
import { PIOPIO_PROMPTS, withPiopioPrompts } from "../src/runtimes/piopio-commands.js";

test("Piopio's templates join pi's; the user's own of the same name wins, and each needs its tools", () => {
	const mine = { name: "grill-me", description: "Mine", content: "x", filePath: "/p/grill-me.md", sourceInfo: { path: "/p/grill-me.md", source: "local", scope: "user" as const, origin: "top-level" as const } };
	const names = (has: { browser: boolean; automations: boolean }) => withPiopioPrompts([mine], has).map((p) => `${p.name}:${p.description}`);
	expect(names({ browser: false, automations: false })).toEqual(["grill-me:Mine"]);
	const all = withPiopioPrompts([], { browser: true, automations: true });
	expect(all.map((p) => p.name)).toEqual(["automation", "grill-me", "browser"]);
	expect(all.every((p) => p.argumentHint && p.content.includes("$ARGUMENTS"))).toBe(true);
});

// Re-audit 2026-11-25 §3.3: /learn and /init were bundled here but missing from the app's own list, so its menu showed
// them with your templates instead of in the Piopio group.
test("every bundled template is one of the app's Piopio commands", () => {
	const composer = readFileSync(join(import.meta.dirname, "..", "..", "..", "apps", "mac", "App", "Piopio", "Composer.swift"), "utf8");
	const app = [...composer.matchAll(/BuiltInCommand\(name: "([^"]+)"[^\n]*engine: true\)/g)].map((m) => m[1]);
	expect(app.length).toBeGreaterThan(0);
	expect(PIOPIO_PROMPTS.map((p) => p.name).filter((name) => !app.includes(name))).toEqual([]);
});
