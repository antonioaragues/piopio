import { expect, test } from "vitest";
import { withPiopioPrompts } from "../src/runtimes/piopio-commands.js";

test("Piopio's templates join pi's; the user's own of the same name wins, and each needs its tools", () => {
	const mine = { name: "grill-me", description: "Mine", content: "x", filePath: "/p/grill-me.md", sourceInfo: { path: "/p/grill-me.md", source: "local", scope: "user" as const, origin: "top-level" as const } };
	const names = (has: { browser: boolean; automations: boolean }) => withPiopioPrompts([mine], has).map((p) => `${p.name}:${p.description}`);
	expect(names({ browser: false, automations: false })).toEqual(["grill-me:Mine"]);
	const all = withPiopioPrompts([], { browser: true, automations: true });
	expect(all.map((p) => p.name)).toEqual(["automation", "grill-me", "browser"]);
	expect(all.every((p) => p.argumentHint && p.content.includes("$ARGUMENTS"))).toBe(true);
});
